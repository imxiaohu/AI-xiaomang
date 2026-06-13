"""Tripo 3D模型生成路由 + 3D 形象市场"""
import httpx
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Header, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from config import DASHSCOPE_API_KEY
from services import marketplace_db

router = APIRouter(prefix="/tripo", tags=["tripo"])

# 模型文件存储目录（相对于 backend/）
MODELS_DIR = Path(__file__).parent.parent / "models_cache"
MODELS_DIR.mkdir(exist_ok=True)


# ============ Request/Response Models ============

class TextTo3DRequest(BaseModel):
    prompt: str = Field(..., max_length=1024)
    model: str = "Tripo/Tripo-P1.0"
    texture_quality: str = "standard"


class ImageTo3DRequest(BaseModel):
    image_url: str
    model: str = "Tripo/Tripo-P1.0"
    texture_quality: str = "standard"


class ImageItem(BaseModel):
    """多图输入：type为jpeg或png，file_token为公网URL，空视角传空对象{}"""
    type: str = Field(default="png", pattern="^(jpeg|jpg|png)$")
    file_token: str | None = None  # 不需要此视角时传 null


class MultiImageTo3DRequest(BaseModel):
    """多图生3D：固定4个位置 [前, 左, 后, 右]，不需要的传空对象{}"""
    images: list[ImageItem | dict] = Field(..., min_length=2, max_length=4)
    model: str = "Tripo/Tripo-P1.0"
    texture_quality: str = "standard"


class GenerationResponse(BaseModel):
    code: int
    message: str
    task_id: str | None = None
    model_id: str | None = None  # 新增：市场行 ID
    visibility: str | None = None  # 新增：默认可见性


class StatusResponse(BaseModel):
    code: int
    task_id: str
    task_status: str  # PENDING / RUNNING / SUCCEEDED / FAILED / CANCELED / UNKNOWN
    task_type: str | None = None
    pbr_model_url: str | None = None
    base_model_url: str | None = None
    rendered_image_url: str | None = None
    submit_time: str | None = None
    end_time: str | None = None
    model_id: str | None = None  # 新增
    visibility: str | None = None  # 新增


class VisibilityPatch(BaseModel):
    visibility: str = Field(..., pattern="^(public|unlisted|private)$")


class MarketUpdate(BaseModel):
    title: Optional[str] = Field(default=None, max_length=80)
    tags: Optional[str] = Field(default=None, max_length=200)


# ============ 身份 ============

def _require_user(
    x_user_token: Optional[str] = Header(default=None, alias="X-User-Token"),
) -> str:
    """从 X-User-Token 头中提取用户 ID。空值时回退为 'anonymous'（dev 模式）。"""
    if x_user_token is None:
        return "anonymous"
    token = x_user_token.strip()
    return token or "anonymous"


# ============ In-memory task registry ============
# {task_id: {"status": str, "pbr_model_url": str, "base_model_url": str, "rendered_image_url": str, "local_glb": str}}
# 保留作为 PENDING/RUNNING 期间的快速索引（DB 仍是主存）
_task_registry: dict[str, dict] = {}


# ============ Helpers ============

async def _fetch_url_to_bytes(url: str) -> bytes:
    async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.content


async def _download_and_cache(url: str, task_id: str, filename: str) -> Path:
    """下载 GLB/图片 文件到本地缓存"""
    local_path = MODELS_DIR / f"{task_id}_{filename}"
    if local_path.exists():
        return local_path

    content = await _fetch_url_to_bytes(url)
    local_path.write_bytes(content)
    return local_path


def _delete_model_files(task_id: str) -> None:
    """删除该 task_id 对应的所有本地文件。"""
    for f in MODELS_DIR.glob(f"{task_id}_*"):
        try:
            f.unlink(missing_ok=True)
        except OSError:
            pass


async def _poll_and_cache(task_id: str):
    """后台任务：轮询任务状态，SUCCEEDED后下载GLB + 写回 DB"""
    from services.aliyun_tripo import AliyunTripo

    tripo = AliyunTripo()
    if not tripo.is_configured:
        _task_registry[task_id] = {
            "status": "FAILED",
            "error": "DASHSCOPE_API_KEY not configured",
        }
        marketplace_db.mark_failed(task_id, "DASHSCOPE_API_KEY not configured")
        return

    # 标记 RUNNING
    _task_registry[task_id] = {"status": "RUNNING"}
    marketplace_db.mark_running(task_id)

    result = await tripo.wait_for_completion(task_id, poll_interval=15.0, max_wait=600.0)
    if result.task_status == "SUCCEEDED":
        pbr_path = None
        base_path = None
        rendered_path = None

        if result.results:
            first = result.results[0]

            if first.pbr_model_url:
                try:
                    pbr_path = await _download_and_cache(
                        first.pbr_model_url, task_id, "model.glb"
                    )
                except Exception as e:
                    print(f"[Tripo] Failed to download GLB: {e}")

            if first.base_model_url:
                try:
                    base_path = await _download_and_cache(
                        first.base_model_url, task_id, "model_base.glb"
                    )
                except Exception as e:
                    print(f"[Tripo] Failed to download base GLB: {e}")

            if first.rendered_image_url:
                try:
                    rendered_path = await _download_and_cache(
                        first.rendered_image_url, task_id, "preview.webp"
                    )
                except Exception as e:
                    print(f"[Tripo] Failed to download preview: {e}")

        task_type = result.usage.task_type if result.usage else None

        _task_registry[task_id] = {
            "status": "SUCCEEDED",
            "task_type": task_type,
            "pbr_model_url": result.results[0].pbr_model_url if result.results else None,
            "base_model_url": result.results[0].base_model_url if result.results else None,
            "rendered_image_url": result.results[0].rendered_image_url if result.results else None,
            "local_glb": str(pbr_path) if pbr_path else None,
            "local_base": str(base_path) if base_path else None,
            "local_preview": str(rendered_path) if rendered_path else None,
            "submit_time": result.submit_time,
            "end_time": result.end_time,
        }

        marketplace_db.mark_succeeded(
            task_id=task_id,
            task_type=task_type,
            glb_path=str(pbr_path) if pbr_path else None,
            base_path=str(base_path) if base_path else None,
            preview_path=str(rendered_path) if rendered_path else None,
            submit_time=result.submit_time,
            end_time=result.end_time,
        )
    elif result.task_status == "FAILED":
        _task_registry[task_id] = {
            "status": "FAILED",
            "error": result.error_message,
        }
        marketplace_db.mark_failed(task_id, result.error_message)
    elif result.task_status == "CANCELED":
        _task_registry[task_id] = {
            "status": "CANCELED",
            "error": "任务已取消",
        }
        marketplace_db.mark_canceled(task_id, "任务已取消")


def _check_api_key():
    if not DASHSCOPE_API_KEY:
        raise HTTPException(status_code=503, detail="DASHSCOPE_API_KEY not configured")


# ============ 提交任务 ============

@router.post("/text-to-3d", response_model=GenerationResponse)
async def text_to_3d(
    req: TextTo3DRequest,
    bg: BackgroundTasks,
    owner_id: str = Depends(_require_user),
):
    """文生3D：提交任务，立即返回 task_id + model_id，后台轮询下载并写库。"""
    _check_api_key()

    from services.aliyun_tripo import AliyunTripo

    tripo = AliyunTripo(
        model=req.model,
        texture_quality=req.texture_quality,
    )
    try:
        task_id = await tripo.text_to_3d(req.prompt)
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=f"Tripo API error: {e.response.text}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    row = marketplace_db.create_pending(
        task_id=task_id,
        owner_id=owner_id,
        task_type="text-to-3d",
        model_name=req.model,
        texture_quality=req.texture_quality,
        prompt=req.prompt,
    )
    _task_registry[task_id] = {"status": "PENDING"}
    bg.add_task(_poll_and_cache, task_id)
    return GenerationResponse(
        code=0,
        message="任务已创建，每月限额3次",
        task_id=task_id,
        model_id=row.id,
        visibility=row.visibility,
    )


@router.post("/image-to-3d", response_model=GenerationResponse)
async def image_to_3d(
    req: ImageTo3DRequest,
    bg: BackgroundTasks,
    owner_id: str = Depends(_require_user),
):
    """单图生3D：提交任务，立即返回 task_id + model_id。"""
    _check_api_key()

    from services.aliyun_tripo import AliyunTripo

    tripo = AliyunTripo(
        model=req.model,
        texture_quality=req.texture_quality,
    )
    try:
        task_id = await tripo.image_to_3d(req.image_url)
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=f"Tripo API error: {e.response.text}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    row = marketplace_db.create_pending(
        task_id=task_id,
        owner_id=owner_id,
        task_type="image-to-3d",
        model_name=req.model,
        texture_quality=req.texture_quality,
        prompt=None,
    )
    _task_registry[task_id] = {"status": "PENDING"}
    bg.add_task(_poll_and_cache, task_id)
    return GenerationResponse(
        code=0,
        message="任务已创建，每月限额3次",
        task_id=task_id,
        model_id=row.id,
        visibility=row.visibility,
    )


@router.post("/multi-image-to-3d", response_model=GenerationResponse)
async def multi_image_to_3d(
    req: MultiImageTo3DRequest,
    bg: BackgroundTasks,
    owner_id: str = Depends(_require_user),
):
    """多图生3D：固定4个视角 [前, 左, 后, 右]，不需要的传空对象 {}"""
    _check_api_key()

    from services.aliyun_tripo import AliyunTripo

    tripo = AliyunTripo(
        model=req.model,
        texture_quality=req.texture_quality,
    )

    # 构建 images 参数：空对象{} 保持为空，ImageItem → {type, file_token}
    images_list = []
    for item in req.images:
        if isinstance(item, dict):
            images_list.append({})
        else:
            images_list.append({
                "type": item.type,
                "file_token": item.file_token,
            })

    try:
        task_id = await tripo.multi_image_to_3d(images_list)
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=f"Tripo API error: {e.response.text}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    row = marketplace_db.create_pending(
        task_id=task_id,
        owner_id=owner_id,
        task_type="multi-image-to-3d",
        model_name=req.model,
        texture_quality=req.texture_quality,
        prompt=None,
    )
    _task_registry[task_id] = {"status": "PENDING"}
    bg.add_task(_poll_and_cache, task_id)
    return GenerationResponse(
        code=0,
        message="任务已创建，每月限额3次",
        task_id=task_id,
        model_id=row.id,
        visibility=row.visibility,
    )


# ============ 状态查询 ============

@router.get("/status/{task_id}", response_model=StatusResponse)
async def get_status(
    task_id: str,
    owner_id: str = Depends(_require_user),
):
    """查询任务状态和结果
    - 优先从内存 registry（正在跑的）拿，缺失则回退 DB
    - SUCCEEDED 后优先返回本地缓存路径
    - 本地未下载完则降级为远程 URL
    - FAILED/CANCELED 返回错误信息
    - 私有模型仅 owner 可查
    """
    # 1) 先在 DB 中查（marketplace 主存）
    db_row = marketplace_db.get_by_task_id(task_id)

    # 2) 内存 registry 仍在（正在跑的）
    in_memory = _task_registry.get(task_id)

    if db_row is None and in_memory is None:
        # 都不在：可能是历史任务，尝试从 DashScope 直接查
        from services.aliyun_tripo import AliyunTripo

        tripo = AliyunTripo()
        if not tripo.is_configured:
            raise HTTPException(status_code=503, detail="DASHSCOPE_API_KEY not configured")
        try:
            result = await tripo.get_task_result(task_id)
            return StatusResponse(
                code=0,
                task_id=task_id,
                task_status=result.task_status,
                task_type=result.usage.task_type if result.usage else None,
                pbr_model_url=result.results[0].pbr_model_url if result.results else None,
                base_model_url=result.results[0].base_model_url if result.results else None,
                rendered_image_url=result.results[0].rendered_image_url if result.results else None,
                submit_time=result.submit_time,
                end_time=result.end_time,
            )
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                raise HTTPException(status_code=404, detail="任务不存在或已过期（task_id有效期24小时）")
            raise HTTPException(status_code=e.response.status_code, detail=str(e))
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

    # 取最新状态：内存覆盖 DB（轮询期间可能刚写到内存）
    if in_memory is not None:
        info = dict(in_memory)
        info["model_id"] = db_row.id if db_row else None
        info["visibility"] = db_row.visibility if db_row else None
    else:
        # 纯 DB 路径
        info = {
            "status": db_row.status,
            "task_type": db_row.task_type,
            "pbr_model_url": None,  # 远程 URL 已在 _task_registry 丢失；走本地
            "base_model_url": None,
            "rendered_image_url": None,
            "local_glb": db_row.glb_path,
            "local_base": db_row.base_path,
            "local_preview": db_row.preview_path,
            "submit_time": db_row.created_at.isoformat() if db_row.created_at else None,
            "end_time": db_row.updated_at.isoformat() if db_row.updated_at else None,
            "model_id": db_row.id,
            "visibility": db_row.visibility,
        }

    # 私有模型访问控制
    if db_row is not None and db_row.visibility == "private" and db_row.owner_id != owner_id:
        raise HTTPException(status_code=403, detail="该模型为私有")

    # GLB URL 降级策略：本地优先，远程兜底
    local_glb = info.get("local_glb")
    if local_glb and Path(local_glb).exists():
        glb_url = f"/tripo/model/{task_id}/glb"
    else:
        glb_url = info.get("pbr_model_url")

    # 预览图
    local_preview = info.get("local_preview")
    if local_preview and Path(local_preview).exists():
        preview_url = f"/tripo/model/{task_id}/preview"
    else:
        preview_url = info.get("rendered_image_url")

    return StatusResponse(
        code=0,
        task_id=task_id,
        task_status=info.get("status", "UNKNOWN"),
        task_type=info.get("task_type"),
        pbr_model_url=glb_url,
        base_model_url=info.get("base_model_url"),
        rendered_image_url=preview_url,
        submit_time=info.get("submit_time"),
        end_time=info.get("end_time"),
        model_id=info.get("model_id"),
        visibility=info.get("visibility"),
    )


# ============ 文件下载（visibility 受控） ============

def _enforce_file_visibility(task_id: str, owner_id: str) -> None:
    """检查私有模型访问权限。"""
    row = marketplace_db.get_by_task_id(task_id)
    if row is None:
        # 没有 DB 行（极老的任务/未走市场的任务）：放行保持兼容
        return
    if row.visibility == "private" and row.owner_id != owner_id:
        raise HTTPException(status_code=403, detail="该模型为私有")


@router.get("/model/{task_id}/glb")
async def download_glb(task_id: str, owner_id: str = Depends(_require_user)):
    """下载 PBR 材质 GLB 文件（本地缓存）"""
    in_mem = _task_registry.get(task_id)
    if in_mem is None and marketplace_db.get_by_task_id(task_id) is None:
        raise HTTPException(status_code=404, detail="任务不存在")
    if in_mem is not None and in_mem.get("status") != "SUCCEEDED":
        raise HTTPException(
            status_code=202,
            detail=f"任务尚未完成，当前状态: {in_mem.get('status')}",
        )

    _enforce_file_visibility(task_id, owner_id)

    local_path = (in_mem or {}).get("local_glb") or (
        marketplace_db.get_by_task_id(task_id).glb_path
        if marketplace_db.get_by_task_id(task_id) else None
    )
    if not local_path or not Path(local_path).exists():
        raise HTTPException(status_code=404, detail="GLB 文件尚未下载完成，请稍后重试")

    return FileResponse(
        local_path,
        media_type="model/gltf-binary",
        filename=f"{task_id}.glb",
    )


@router.get("/model/{task_id}/glb_base")
async def download_glb_base(task_id: str, owner_id: str = Depends(_require_user)):
    """下载无贴图基础 GLB 文件"""
    in_mem = _task_registry.get(task_id)
    if in_mem is None and marketplace_db.get_by_task_id(task_id) is None:
        raise HTTPException(status_code=404, detail="任务不存在")
    if in_mem is not None and in_mem.get("status") != "SUCCEEDED":
        raise HTTPException(status_code=202, detail="任务尚未完成")

    _enforce_file_visibility(task_id, owner_id)

    local_path = (in_mem or {}).get("local_base") or (
        marketplace_db.get_by_task_id(task_id).base_path
        if marketplace_db.get_by_task_id(task_id) else None
    )
    if not local_path or not Path(local_path).exists():
        raise HTTPException(status_code=404, detail="无贴图模型尚未生成")

    return FileResponse(
        local_path,
        media_type="model/gltf-binary",
        filename=f"{task_id}_base.glb",
    )


@router.get("/model/{task_id}/preview")
async def download_preview(task_id: str, owner_id: str = Depends(_require_user)):
    """下载渲染预览图"""
    in_mem = _task_registry.get(task_id)
    if in_mem is None and marketplace_db.get_by_task_id(task_id) is None:
        raise HTTPException(status_code=404, detail="任务不存在")

    _enforce_file_visibility(task_id, owner_id)

    local_path = (in_mem or {}).get("local_preview") or (
        marketplace_db.get_by_task_id(task_id).preview_path
        if marketplace_db.get_by_task_id(task_id) else None
    )
    if not local_path or not Path(local_path).exists():
        raise HTTPException(status_code=404, detail="预览图尚未生成")

    return FileResponse(local_path, media_type="image/webp")


# ============ 市场公开列表 / 详情 / 下载 ============

@router.get("/marketplace")
async def list_marketplace(
    q: Optional[str] = Query(default=None, description="搜索 title/prompt/tags"),
    type: Optional[str] = Query(default=None, description="text-to-3d | image-to-3d | multi-image-to-3d"),
    sort: str = Query(default="recent", pattern="^(recent|popular)$"),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=24, ge=1, le=100),
):
    """公开市场列表（visibility=public）"""
    rows, total = marketplace_db.list_public(
        q=q,
        task_type=type,
        sort=sort,
        page=page,
        page_size=page_size,
    )
    return marketplace_db.public_list_response(rows, total, page, page_size)


@router.get("/marketplace/me")
async def list_my_models(owner_id: str = Depends(_require_user)):
    """列出当前用户的所有模型（含私密）"""
    rows = marketplace_db.list_mine(owner_id)
    return {
        "items": [marketplace_db.to_public_dict(r) for r in rows],
        "total": len(rows),
    }


@router.get("/marketplace/{model_id}")
async def get_marketplace_item(
    model_id: str,
    owner_id: str = Depends(_require_user),
):
    """获取单条市场记录（私有仅 owner 可见）"""
    row = marketplace_db.get_by_id(model_id)
    if row is None:
        raise HTTPException(status_code=404, detail="模型不存在")
    if row.visibility == "private" and row.owner_id != owner_id:
        raise HTTPException(status_code=403, detail="该模型为私有")
    marketplace_db.increment_views(model_id)
    return marketplace_db.to_public_dict(row)


@router.post("/marketplace/{model_id}/download")
async def download_marketplace_model(
    model_id: str,
    owner_id: str = Depends(_require_user),
):
    """下载（递增计数器）并返回可用 URL。"""
    row = marketplace_db.get_by_id(model_id)
    if row is None:
        raise HTTPException(status_code=404, detail="模型不存在")
    if row.visibility == "private" and row.owner_id != owner_id:
        raise HTTPException(status_code=403, detail="该模型为私有")
    if row.status != "SUCCEEDED":
        raise HTTPException(status_code=202, detail=f"模型尚未就绪，当前状态: {row.status}")

    row = marketplace_db.increment_downloads(model_id)
    return marketplace_db.get_full_urls(row)


@router.patch("/marketplace/{model_id}/visibility")
async def patch_visibility(
    model_id: str,
    body: VisibilityPatch,
    owner_id: str = Depends(_require_user),
):
    """修改可见性（仅 owner）"""
    row = marketplace_db.set_visibility(owner_id, model_id, body.visibility)
    if row is None:
        raise HTTPException(status_code=404, detail="模型不存在或非本人")
    return marketplace_db.to_public_dict(row)


@router.put("/marketplace/{model_id}")
async def update_marketplace_item(
    model_id: str,
    body: MarketUpdate,
    owner_id: str = Depends(_require_user),
):
    """编辑 title / tags（仅 owner）"""
    row = marketplace_db.update_meta(
        owner_id, model_id, title=body.title, tags=body.tags,
    )
    if row is None:
        raise HTTPException(status_code=404, detail="模型不存在或非本人")
    return marketplace_db.to_public_dict(row)


@router.delete("/marketplace/{model_id}")
async def delete_marketplace_item(
    model_id: str,
    owner_id: str = Depends(_require_user),
):
    """删除模型（仅 owner，级联删除本地 GLB/preview 文件）"""
    row = marketplace_db.delete_owned(owner_id, model_id)
    if row is None:
        raise HTTPException(status_code=404, detail="模型不存在或非本人")
    # 级联删除本地文件
    _delete_model_files(row.task_id)
    # 同时清理内存 registry
    _task_registry.pop(row.task_id, None)
    return {"code": 0, "deleted": model_id}


# ============ 缓存统计 / 清理 ============

@router.get("/marketplace/cache/stats")
async def get_cache_stats():
    return marketplace_db.cache_stats()


@router.delete("/marketplace/cache")
async def clear_cache(days: int = Query(default=0, ge=0, description="删除 mtime 早于 N 天的文件")):
    removed = marketplace_db.clear_cache_older_than(days)
    return {"code": 0, "removed_files": removed}


# ============ 调试 ============

@router.get("/models_cache/list")
async def list_cached_models():
    """列出本地已缓存的模型（调试用）"""
    files = []
    for f in MODELS_DIR.glob("*"):
        files.append({
            "name": f.name,
            "size": f.stat().st_size,
            "modified": f.stat().st_mtime,
        })
    return {"files": files, "count": len(files)}
