"""3D 形象市场数据库模块

- 用 SQLite + SQLModel 持久化所有 AI 生成的 3D 模型
- 默认 visibility = public（公开），保证「所有 AI 生成的模型可以被任意用户下载选用」
- 提供基于 task_id / model_id / owner_id 的增删改查
"""
from __future__ import annotations

import os
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

from sqlmodel import Field, SQLModel, Session, create_engine, select
from sqlalchemy.exc import SQLAlchemyError

from config import DEFAULT_MODEL_VISIBILITY

# ==============================
# 数据库文件路径
# ==============================

BACKEND_ROOT = Path(__file__).parent.parent
DATA_DIR = BACKEND_ROOT / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = DATA_DIR / "marketplace.db"
DATABASE_URL = f"sqlite:///{DB_PATH}"

# check_same_thread=False 让 FastAPI 的线程池也能安全使用
engine = create_engine(
    DATABASE_URL,
    echo=False,
    connect_args={"check_same_thread": False},
)


# ==============================
# 模型表
# ==============================

VALID_TASK_TYPES = ("text-to-3d", "image-to-3d", "multi-image-to-3d")
VALID_VISIBILITIES = ("public", "unlisted", "private")
VALID_STATUSES = ("PENDING", "RUNNING", "SUCCEEDED", "FAILED", "CANCELED", "UNKNOWN")


class MarketplaceModel(SQLModel, table=True):
    """3D 形象市场行"""
    __tablename__ = "marketplace_models"

    id: str = Field(default_factory=lambda: uuid.uuid4().hex, primary_key=True)
    task_id: str = Field(index=True, unique=True)
    owner_id: str = Field(index=True, default="anonymous")

    task_type: str = Field(default="text-to-3d")
    prompt: Optional[str] = Field(default=None)
    model_name: str = Field(default="Tripo/Tripo-P1.0")
    texture_quality: str = Field(default="standard")

    status: str = Field(default="PENDING", index=True)
    error_message: Optional[str] = Field(default=None)

    title: Optional[str] = Field(default=None)
    tags: str = Field(default="")

    visibility: str = Field(default="public", index=True)

    downloads: int = Field(default=0)
    views: int = Field(default=0)

    glb_path: Optional[str] = Field(default=None)
    base_path: Optional[str] = Field(default=None)
    preview_path: Optional[str] = Field(default=None)

    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


# ==============================
# 响应模型
# ==============================

class MarketplaceItemPublic(SQLModel):
    """对外暴露的市场条目（不含服务端文件路径）"""
    id: str
    task_id: str
    owner_id: str
    task_type: str
    prompt: Optional[str] = None
    model_name: str
    texture_quality: str
    status: str
    title: Optional[str] = None
    tags: str
    visibility: str
    downloads: int
    views: int
    glb_url: Optional[str] = None
    base_url: Optional[str] = None
    preview_url: Optional[str] = None
    created_at: datetime
    updated_at: datetime


class MarketplaceListResponse(SQLModel):
    items: list[MarketplaceItemPublic]
    total: int
    page: int
    page_size: int


class MarketplaceDownloadResponse(SQLModel):
    glb_url: str
    base_url: Optional[str] = None
    preview_url: Optional[str] = None


# ==============================
# 工具函数
# ==============================

def _normalize_visibility(v: Optional[str]) -> str:
    if not v:
        return DEFAULT_MODEL_VISIBILITY
    v = v.lower().strip()
    if v not in VALID_VISIBILITIES:
        return DEFAULT_MODEL_VISIBILITY
    return v


def _normalize_status(s: Optional[str]) -> str:
    if not s:
        return "UNKNOWN"
    s = s.upper().strip()
    if s not in VALID_STATUSES:
        return "UNKNOWN"
    return s


def _derive_title(prompt: Optional[str], task_type: str) -> Optional[str]:
    if prompt:
        s = prompt.strip().replace("\n", " ")
        return s[:40] + ("…" if len(s) > 40 else "")
    if task_type == "image-to-3d":
        return "Image-to-3D model"
    if task_type == "multi-image-to-3d":
        return "Multi-image-to-3D model"
    return None


def _to_public(row: MarketplaceModel) -> MarketplaceItemPublic:
    """将 DB 行转换为对外暴露的响应对象，并补全 URL。"""
    glb_url = f"/tripo/model/{row.task_id}/glb" if row.glb_path else None
    base_url = f"/tripo/model/{row.task_id}/glb_base" if row.base_path else None
    preview_url = f"/tripo/model/{row.task_id}/preview" if row.preview_path else None
    return MarketplaceItemPublic(
        id=row.id,
        task_id=row.task_id,
        owner_id=row.owner_id,
        task_type=row.task_type,
        prompt=row.prompt,
        model_name=row.model_name,
        texture_quality=row.texture_quality,
        status=row.status,
        title=row.title,
        tags=row.tags,
        visibility=row.visibility,
        downloads=row.downloads,
        views=row.views,
        glb_url=glb_url,
        base_url=base_url,
        preview_url=preview_url,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


# ==============================
# 初始化
# ==============================

def init_db() -> None:
    """创建表。lifespan 中调用。"""
    try:
        SQLModel.metadata.create_all(engine)
    except SQLAlchemyError as e:
        print(f"[marketplace_db] failed to create tables: {e}")


# ==============================
# 写入
# ==============================

def create_pending(
    *,
    task_id: str,
    owner_id: str,
    task_type: str,
    model_name: str,
    texture_quality: str,
    prompt: Optional[str] = None,
    visibility: Optional[str] = None,
) -> MarketplaceModel:
    """提交任务时调用：插入 PENDING 行。"""
    vis = _normalize_visibility(visibility or DEFAULT_MODEL_VISIBILITY)
    title = _derive_title(prompt, task_type)
    row = MarketplaceModel(
        task_id=task_id,
        owner_id=owner_id or "anonymous",
        task_type=task_type if task_type in VALID_TASK_TYPES else "text-to-3d",
        prompt=prompt,
        model_name=model_name or "Tripo/Tripo-P1.0",
        texture_quality=texture_quality or "standard",
        status="PENDING",
        title=title,
        tags="",
        visibility=vis,
    )
    with Session(engine) as session:
        session.add(row)
        session.commit()
        session.refresh(row)
    return row


def mark_running(task_id: str) -> None:
    with Session(engine) as session:
        row = session.exec(
            select(MarketplaceModel).where(MarketplaceModel.task_id == task_id)
        ).first()
        if row is None:
            return
        row.status = "RUNNING"
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()


def mark_succeeded(
    *,
    task_id: str,
    task_type: Optional[str],
    glb_path: Optional[str],
    base_path: Optional[str],
    preview_path: Optional[str],
    submit_time: Optional[str] = None,
    end_time: Optional[str] = None,
) -> None:
    with Session(engine) as session:
        row = session.exec(
            select(MarketplaceModel).where(MarketplaceModel.task_id == task_id)
        ).first()
        if row is None:
            return
        row.status = "SUCCEEDED"
        if task_type and task_type in VALID_TASK_TYPES:
            row.task_type = task_type
        if glb_path:
            row.glb_path = glb_path
        if base_path:
            row.base_path = base_path
        if preview_path:
            row.preview_path = preview_path
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()


def mark_failed(task_id: str, error: Optional[str] = None) -> None:
    with Session(engine) as session:
        row = session.exec(
            select(MarketplaceModel).where(MarketplaceModel.task_id == task_id)
        ).first()
        if row is None:
            return
        row.status = "FAILED"
        row.error_message = error
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()


def mark_canceled(task_id: str, error: Optional[str] = None) -> None:
    with Session(engine) as session:
        row = session.exec(
            select(MarketplaceModel).where(MarketplaceModel.task_id == task_id)
        ).first()
        if row is None:
            return
        row.status = "CANCELED"
        row.error_message = error or "任务已取消"
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()


# ==============================
# 查询
# ==============================

def get_by_id(model_id: str) -> Optional[MarketplaceModel]:
    with Session(engine) as session:
        return session.get(MarketplaceModel, model_id)


def get_by_task_id(task_id: str) -> Optional[MarketplaceModel]:
    with Session(engine) as session:
        return session.exec(
            select(MarketplaceModel).where(MarketplaceModel.task_id == task_id)
        ).first()


def get_full_urls(row: MarketplaceModel) -> dict:
    """供 /download 端点使用，返回绝对 URL（相对路径，前端自行拼 baseUrl）。"""
    return {
        "glb_url": f"/tripo/model/{row.task_id}/glb" if row.glb_path else None,
        "base_url": f"/tripo/model/{row.task_id}/glb_base" if row.base_path else None,
        "preview_url": f"/tripo/model/{row.task_id}/preview" if row.preview_path else None,
    }


def list_public(
    *,
    q: Optional[str] = None,
    task_type: Optional[str] = None,
    sort: str = "recent",
    page: int = 1,
    page_size: int = 24,
) -> tuple[list[MarketplaceModel], int]:
    page = max(1, page)
    page_size = max(1, min(100, page_size))
    with Session(engine) as session:
        stmt = select(MarketplaceModel).where(MarketplaceModel.visibility == "public")
        if task_type and task_type in VALID_TASK_TYPES:
            stmt = stmt.where(MarketplaceModel.task_type == task_type)
        if q:
            like = f"%{q.strip()}%"
            stmt = stmt.where(
                (MarketplaceModel.title.like(like))
                | (MarketplaceModel.prompt.like(like))
                | (MarketplaceModel.tags.like(like))
            )

        # 统计总数
        from sqlalchemy import func
        count_stmt = select(func.count()).select_from(stmt.subquery())
        total = session.exec(count_stmt).one()

        # 排序
        if sort == "popular":
            stmt = stmt.order_by(MarketplaceModel.downloads.desc(), MarketplaceModel.created_at.desc())
        else:
            stmt = stmt.order_by(MarketplaceModel.created_at.desc())

        stmt = stmt.offset((page - 1) * page_size).limit(page_size)
        rows = session.exec(stmt).all()
        return list(rows), int(total or 0)


def list_mine(owner_id: str) -> list[MarketplaceModel]:
    with Session(engine) as session:
        rows = session.exec(
            select(MarketplaceModel)
            .where(MarketplaceModel.owner_id == owner_id)
            .order_by(MarketplaceModel.created_at.desc())
        ).all()
        return list(rows)


# ==============================
# 更新 / 删除
# ==============================

def set_visibility(owner_id: str, model_id: str, visibility: str) -> Optional[MarketplaceModel]:
    vis = _normalize_visibility(visibility)
    with Session(engine) as session:
        row = session.get(MarketplaceModel, model_id)
        if row is None or row.owner_id != owner_id:
            return None
        row.visibility = vis
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()
        session.refresh(row)
        return row


def update_meta(
    owner_id: str,
    model_id: str,
    *,
    title: Optional[str] = None,
    tags: Optional[str] = None,
) -> Optional[MarketplaceModel]:
    with Session(engine) as session:
        row = session.get(MarketplaceModel, model_id)
        if row is None or row.owner_id != owner_id:
            return None
        if title is not None:
            t = title.strip()[:80]
            row.title = t or None
        if tags is not None:
            row.tags = tags.strip()[:200]
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()
        session.refresh(row)
        return row


def delete_owned(owner_id: str, model_id: str) -> Optional[MarketplaceModel]:
    """返回被删除的 row（含文件路径）以便调用方清理磁盘。"""
    with Session(engine) as session:
        row = session.get(MarketplaceModel, model_id)
        if row is None or row.owner_id != owner_id:
            return None
        session.delete(row)
        session.commit()
        return row


def increment_downloads(model_id: str) -> Optional[MarketplaceModel]:
    with Session(engine) as session:
        row = session.get(MarketplaceModel, model_id)
        if row is None:
            return None
        row.downloads = (row.downloads or 0) + 1
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()
        session.refresh(row)
        return row


def increment_views(model_id: str) -> None:
    with Session(engine) as session:
        row = session.get(MarketplaceModel, model_id)
        if row is None:
            return
        row.views = (row.views or 0) + 1
        row.updated_at = datetime.utcnow()
        session.add(row)
        session.commit()


# ==============================
# 缓存统计 / 清理
# ==============================

def cache_stats() -> dict:
    """统计 models_cache 目录的文件占用。"""
    models_dir = BACKEND_ROOT / "models_cache"
    if not models_dir.exists():
        return {"total_bytes": 0, "model_count": 0, "base_bytes": 0, "preview_bytes": 0}

    total = 0
    model_bytes = 0
    base_bytes = 0
    preview_bytes = 0
    count = 0
    for f in models_dir.glob("*"):
        if not f.is_file():
            continue
        try:
            size = f.stat().st_size
        except OSError:
            continue
        total += size
        name = f.name
        if name.endswith("_model.glb"):
            model_bytes += size
            count += 1
        elif name.endswith("_model_base.glb"):
            base_bytes += size
        elif name.endswith("_preview.webp"):
            preview_bytes += size
    return {
        "total_bytes": total,
        "model_count": count,
        "base_bytes": base_bytes,
        "preview_bytes": preview_bytes,
    }


def clear_cache_older_than(days: int) -> int:
    """删除 models_cache 目录中 mtime 早于 days 天的文件，返回删除数量。"""
    models_dir = BACKEND_ROOT / "models_cache"
    if not models_dir.exists():
        return 0
    threshold = time.time() - max(0, days) * 86400
    removed = 0
    for f in models_dir.glob("*"):
        if not f.is_file():
            continue
        try:
            if f.stat().st_mtime < threshold:
                f.unlink(missing_ok=True)
                removed += 1
        except OSError:
            continue
    return removed


# ==============================
# 工具导出（供 router 使用）
# ==============================

def to_public_dict(row: MarketplaceModel) -> dict:
    """FastAPI 响应助手：转 dict 以便 router 直接返回。"""
    item = _to_public(row)
    return item.model_dump()


def public_list_response(
    rows: list[MarketplaceModel],
    total: int,
    page: int,
    page_size: int,
) -> dict:
    return {
        "items": [to_public_dict(r) for r in rows],
        "total": total,
        "page": page,
        "page_size": page_size,
    }
