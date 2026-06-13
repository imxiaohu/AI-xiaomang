"""回归测试：/cancel/{task_id} 软删除接口。

plan §后端 4
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import sqlmodel
if not hasattr(sqlmodel, 'SQLAlchemyError'):
    import sqlalchemy.exc
    sqlmodel.SQLAlchemyError = sqlalchemy.exc.SQLAlchemyError

from fastapi import FastAPI
from fastapi.testclient import TestClient

import routers.tripo_3d as tripo
from services import marketplace_db
import tempfile
from pathlib import Path

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


def _make_app():
    app = FastAPI()
    app.include_router(tripo.router)
    return app


def _seed_running_task(task_id: str, owner_id: str):
    tripo._task_registry[task_id] = {"status": "RUNNING"}
    marketplace_db.create_pending(
        task_id=task_id,
        owner_id=owner_id,
        task_type="text-to-3d",
        model_name="Tripo/Tripo-P1.0",
        texture_quality="standard",
        prompt="cancel test",
    )
    marketplace_db.mark_running(task_id)


def test_cancel_running_task_marks_cancel_requested():
    """取消 RUNNING 任务后 _task_registry 标记 cancel_requested=True。"""
    task_id = "cancel-test-1"
    _seed_running_task(task_id, "alice")
    client = TestClient(_make_app())

    r = client.post(
        f"/tripo/cancel/{task_id}",
        headers={"X-User-Token": "alice"},
    )
    print(f"[test] cancel response: {r.status_code} {r.json()}")
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["code"] == 0
    assert data["task_status"] == "CANCELED"

    # registry 必须有 cancel_requested=True
    assert tripo._task_registry[task_id].get("cancel_requested") is True
    print("✓ cancel marks cancel_requested in registry")


def test_cancel_by_non_owner_returns_403():
    """非 owner 取消 → 403。"""
    task_id = "cancel-test-2"
    _seed_running_task(task_id, "alice")
    client = TestClient(_make_app())

    r = client.post(
        f"/tripo/cancel/{task_id}",
        headers={"X-User-Token": "mallory"},  # 非 owner
    )
    print(f"[test] non-owner cancel: {r.status_code} {r.json()}")
    assert r.status_code == 403
    assert tripo._task_registry[task_id].get("cancel_requested") is None
    print("✓ non-owner cannot cancel")


def test_cancel_nonexistent_task_returns_404():
    """不存在的任务 → 404。"""
    client = TestClient(_make_app())
    r = client.post(
        "/tripo/cancel/nonexistent-task-id",
        headers={"X-User-Token": "alice"},
    )
    print(f"[test] nonexistent: {r.status_code} {r.json()}")
    assert r.status_code == 404
    print("✓ cancel of nonexistent task returns 404")


def test_cancel_succeeded_task_returns_409():
    """已 SUCCEEDED 的任务不可再取消（终态）。"""
    task_id = "cancel-test-3"
    _seed_running_task(task_id, "alice")
    # 模拟已完成
    tripo._task_registry[task_id]["status"] = "SUCCEEDED"
    marketplace_db.mark_succeeded(
        task_id=task_id,
        task_type="text-to-3d",
        glb_path=None,
        base_path=None,
        preview_path=None,
    )

    client = TestClient(_make_app())
    r = client.post(
        f"/tripo/cancel/{task_id}",
        headers={"X-User-Token": "alice"},
    )
    print(f"[test] cancel of SUCCEEDED: {r.status_code} {r.json()}")
    assert r.status_code == 409
    assert "SUCCEEDED" in r.json()["detail"]
    print("✓ cancel of terminal-state task returns 409")


if __name__ == "__main__":
    test_cancel_running_task_marks_cancel_requested()
    test_cancel_by_non_owner_returns_403()
    test_cancel_nonexistent_task_returns_404()
    test_cancel_succeeded_task_returns_409()
    print("\n=== ALL TESTS PASSED ===")
