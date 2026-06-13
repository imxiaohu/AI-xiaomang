"""Bug #1 回归测试：/status 返回的 URL 必须带 scheme（绝对地址）。

iOS model_viewer_plus 不接受相对路径，会把 /tripo/... 当 Flutter 资源加载。
"""
import sys
import os

# 让 tests 目录能 import 上层模块
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# marketplace_db 需要 SQLAlchemyError
import sqlmodel
if not hasattr(sqlmodel, 'SQLAlchemyError'):
    import sqlalchemy.exc
    sqlmodel.SQLAlchemyError = sqlalchemy.exc.SQLAlchemyError

import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock

from fastapi import FastAPI
from fastapi.testclient import TestClient

import routers.tripo_3d as tripo
from services import marketplace_db

# 隔离：用临时 DB + 清空内存 registry
_tmpdir = tempfile.mkdtemp(prefix="tripo_test_")
os.environ['MARKETPLACE_DB_OVERRIDE'] = os.path.join(_tmpdir, 'marketplace.db')
# 直接改 marketplace_db 的 DB_PATH
marketplace_db.DB_PATH = Path(os.environ['MARKETPLACE_DB_OVERRIDE'])
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


def _make_test_app():
    app = FastAPI(title="tripo url absolute test")
    app.include_router(tripo.router)
    return app


def _seed_succeeded_task(task_id: str, owner_id: str, glb_path: str, preview_path: str):
    """往 _task_registry 和 DB 中塞一条 SUCCEEDED 任务。"""
    # 内存
    tripo._task_registry[task_id] = {
        "status": "SUCCEEDED",
        "pbr_model_url": "https://remote.example.com/model.glb",
        "rendered_image_url": "https://remote.example.com/preview.webp",
        "local_glb": str(glb_path),
        "local_preview": str(preview_path),
    }
    # DB
    marketplace_db.create_pending(
        task_id=task_id,
        owner_id=owner_id,
        task_type="text-to-3d",
        model_name="Tripo/Tripo-P1.0",
        texture_quality="standard",
        prompt="test prompt",
    )
    marketplace_db.mark_running(task_id)
    marketplace_db.mark_succeeded(
        task_id=task_id,
        task_type="text-to-3d",
        glb_path=str(glb_path),
        base_path=None,
        preview_path=str(preview_path),
    )


def test_status_returns_absolute_urls():
    """修 bug #1：/status 返回 pbr_model_url / rendered_image_url 必须是 http://... 绝对地址。"""
    with tempfile.TemporaryDirectory() as tmpdir:
        # 用临时目录避免污染真实 models_cache
        glb_path = os.path.join(tmpdir, "fake_model.glb")
        preview_path = os.path.join(tmpdir, "fake_preview.webp")
        Path(glb_path).write_bytes(b"glb")
        Path(preview_path).write_bytes(b"webp")

        task_id = "absolute-url-test-1"
        with patch.object(tripo, "MODELS_DIR", Path(tmpdir)):
            _seed_succeeded_task(task_id, "alice", glb_path, preview_path)

            app = _make_test_app()
            client = TestClient(app)

            r = client.get(
                f"/tripo/status/{task_id}",
                headers={"X-User-Token": "alice"},
            )
            assert r.status_code == 200, r.text
            data = r.json()
            print(f"[test] pbr_model_url       = {data['pbr_model_url']}")
            print(f"[test] rendered_image_url  = {data['rendered_image_url']}")
            print(f"[test] can_cancel          = {data['can_cancel']}")

            # 修 bug #1：必须是绝对 URL（含 scheme）
            assert data["pbr_model_url"].startswith("http://"), \
                f"pbr_model_url must be absolute, got: {data['pbr_model_url']}"
            assert data["rendered_image_url"].startswith("http://"), \
                f"rendered_image_url must be absolute, got: {data['rendered_image_url']}"
            assert "/tripo/model/" in data["pbr_model_url"]
            assert "/tripo/model/" in data["rendered_image_url"]

            # 终态不可取消
            assert data["can_cancel"] is False

            print("✓ /status returns absolute URLs")


def test_status_can_cancel_true_for_running_task():
    """/status 在 PENDING/RUNNING 时返回 can_cancel=true。"""
    task_id = "absolute-url-test-2"
    tripo._task_registry[task_id] = {"status": "RUNNING"}
    marketplace_db.create_pending(
        task_id=task_id,
        owner_id="bob",
        task_type="text-to-3d",
        model_name="Tripo/Tripo-P1.0",
        texture_quality="standard",
        prompt="running test",
    )

    app = _make_test_app()
    client = TestClient(app)

    r = client.get(
        f"/tripo/status/{task_id}",
        headers={"X-User-Token": "bob"},
    )
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["task_status"] == "RUNNING"
    assert data["can_cancel"] is True, "owner of running task should be able to cancel"
    print("✓ can_cancel=true for owner of RUNNING task")


def test_status_can_cancel_false_for_non_owner():
    """非 owner 即便任务 RUNNING 也不能取消。"""
    task_id = "absolute-url-test-3"
    tripo._task_registry[task_id] = {"status": "RUNNING"}
    marketplace_db.create_pending(
        task_id=task_id,
        owner_id="bob",
        task_type="text-to-3d",
        model_name="Tripo/Tripo-P1.0",
        texture_quality="standard",
        prompt="privacy test",
    )

    app = _make_test_app()
    client = TestClient(app)

    r = client.get(
        f"/tripo/status/{task_id}",
        headers={"X-User-Token": "eve"},  # 非 owner
    )
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["can_cancel"] is False, "non-owner should NOT be able to cancel"
    print("✓ can_cancel=false for non-owner")


if __name__ == "__main__":
    test_status_returns_absolute_urls()
    test_status_can_cancel_true_for_running_task()
    test_status_can_cancel_false_for_non_owner()
    print("\n=== ALL TESTS PASSED ===")
