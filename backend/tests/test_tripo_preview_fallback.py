"""回归测试：/preview 必须支持远程 URL 代理（修 bug #3：本地未就绪时不返回 404）。

补：preview 远程代理（plan §后端2）。
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import sqlmodel
if not hasattr(sqlmodel, 'SQLAlchemyError'):
    import sqlalchemy.exc
    sqlmodel.SQLAlchemyError = sqlalchemy.exc.SQLAlchemyError

import tempfile
import threading
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

import routers.tripo_3d as tripo
from services import marketplace_db

# 隔离：临时 DB
_tmpdir = tempfile.mkdtemp(prefix="tripo_test_")
marketplace_db.DB_PATH = Path(_tmpdir) / 'marketplace.db'
marketplace_db.DATA_DIR = Path(_tmpdir)
marketplace_db.engine.dispose()
from sqlalchemy import create_engine
marketplace_db.engine = create_engine(
    f"sqlite:///{marketplace_db.DB_PATH}",
    echo=False,
    connect_args={"check_same_thread": False},
)
marketplace_db.init_db()
tripo._task_registry.clear()


# ── 临时 HTTP 服务器用于 mock 远程 preview URL ──
class _FakeRemoteHandler(BaseHTTPRequestHandler):
    """根据路径返回不同的 image bytes"""
    payload_webp = b"GIF89a-fake-webp-content"  # 任何字节都行

    def do_GET(self):
        if self.path == "/preview-good.webp":
            self.send_response(200)
            self.send_header("Content-Type", "image/webp")
            self.send_header("Content-Length", str(len(self.payload_webp)))
            self.end_headers()
            self.wfile.write(self.payload_webp)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args, **kwargs):
        pass  # 静音


def _start_fake_server() -> tuple[str, HTTPServer]:
    server = HTTPServer(("127.0.0.1", 0), _FakeRemoteHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return f"http://127.0.0.1:{port}", server


def test_preview_falls_back_to_remote_when_local_missing():
    """本地无 preview 文件 + 任务 SUCCEEDED + 远程 URL → 200 + image bytes（不 404）。"""
    remote_base, server = _start_fake_server()
    remote_url = f"{remote_base}/preview-good.webp"
    task_id = "preview-fallback-1"

    with tempfile.TemporaryDirectory() as tmpdir:
        # 内存状态：SUCCEEDED + 远程 URL，无 local_preview
        tripo._task_registry[task_id] = {
            "status": "SUCCEEDED",
            "rendered_image_url": remote_url,
        }

        # DB 中也建一条 SUCCEEDED
        marketplace_db.create_pending(
            task_id=task_id,
            owner_id="alice",
            task_type="text-to-3d",
            model_name="Tripo/Tripo-P1.0",
            texture_quality="standard",
            prompt="preview fallback test",
        )
        marketplace_db.mark_running(task_id)
        marketplace_db.mark_succeeded(
            task_id=task_id,
            task_type="text-to-3d",
            glb_path=None,
            base_path=None,
            preview_path=None,  # 关键：本地无
        )

        app = FastAPI()
        app.include_router(tripo.router)
        client = TestClient(app)

        r = client.get(
            f"/tripo/model/{task_id}/preview",
            headers={"X-User-Token": "alice"},
        )
        print(f"[test] status={r.status_code} body={r.content[:40]!r}...")
        assert r.status_code == 200, f"expected 200 from remote proxy, got {r.status_code}: {r.text}"
        assert r.content == _FakeRemoteHandler.payload_webp
        assert r.headers.get("content-type") == "image/webp"
        print("✓ /preview proxies remote URL when local missing")

    server.shutdown()


def test_preview_404_when_no_local_no_remote():
    """本地无 + 远程无 → 404。"""
    task_id = "preview-fallback-2"
    tripo._task_registry[task_id] = {
        "status": "SUCCEEDED",
        "rendered_image_url": None,  # 无远程
    }
    marketplace_db.create_pending(
        task_id=task_id,
        owner_id="alice",
        task_type="text-to-3d",
        model_name="Tripo/Tripo-P1.0",
        texture_quality="standard",
        prompt="no preview test",
    )
    marketplace_db.mark_running(task_id)
    marketplace_db.mark_succeeded(
        task_id=task_id,
        task_type="text-to-3d",
        glb_path=None,
        base_path=None,
        preview_path=None,
    )

    app = FastAPI()
    app.include_router(tripo.router)
    client = TestClient(app)

    r = client.get(
        f"/tripo/model/{task_id}/preview",
        headers={"X-User-Token": "alice"},
    )
    print(f"[test] status={r.status_code} detail={r.json().get('detail')}")
    assert r.status_code == 404
    print("✓ /preview returns 404 when no local and no remote")


def test_preview_serves_local_when_present():
    """本地存在时直接 FileResponse（不走远程）。"""
    with tempfile.TemporaryDirectory() as tmpdir:
        preview_path = Path(tmpdir) / "test-preview.webp"
        preview_path.write_bytes(b"LOCAL-WEBP-BYTES")
        task_id = "preview-fallback-3"

        tripo._task_registry[task_id] = {
            "status": "SUCCEEDED",
            "rendered_image_url": "http://should-not-be-called.example.com/preview.webp",
            "local_preview": str(preview_path),
        }

        app = FastAPI()
        app.include_router(tripo.router)
        client = TestClient(app)

        r = client.get(
            f"/tripo/model/{task_id}/preview",
            headers={"X-User-Token": "alice"},
        )
        print(f"[test] local status={r.status_code} bytes={r.content!r}")
        assert r.status_code == 200
        assert r.content == b"LOCAL-WEBP-BYTES"
        print("✓ /preview serves local file when present")


if __name__ == "__main__":
    test_preview_falls_back_to_remote_when_local_missing()
    test_preview_404_when_no_local_no_remote()
    test_preview_serves_local_when_present()
    print("\n=== ALL TESTS PASSED ===")
