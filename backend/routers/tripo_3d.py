"""Tripo 3D模型生成路由 + 3D 形象市场"""
import asyncio
import logging
import httpx
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Header, Query, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel, Field
from config import DASHSCOPE_API_KEY
from services import marketplace_db

logger = logging.getLogger("tripo_3d")

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
    error_message: str | None = None  # 新增：失败原因透传
    can_cancel: bool = False  # 新增：仅 PENDING/RUNNING 且 owner 匹配时为 true


class VisibilityPatch(BaseModel):
    visibility: str = Field(..., pattern="^(public|unlisted|private)$")


class CancelResponse(BaseModel):
    code: int
    task_id: str
    task_status: str  # CANCELED
    message: str = "任务已取消"


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


def _absolute_url(request: Optional[Request], path_or_url: Optional[str]) -> Optional[str]:
    """把相对路径（如 /tripo/model/.../glb）转成带 scheme 的绝对地址。

    - 已带 scheme（http/https）原样返回
    - 相对路径时拼上 request 的 scheme + host（修 bug #1：iOS model_viewer_plus 拒绝相对 URL）
    - request 为 None 时降级返回原值（极少数代码路径下用于纯 DB 渲染）
    """
    if not path_or_url:
        return path_or_url
    if path_or_url.startswith(("http://", "https://")):
        return path_or_url
    if request is None:
        return path_or_url
    scheme = request.url.scheme
    host = request.headers.get("host") or request.url.netloc
    return f"{scheme}://{host}{path_or_url}"


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
    """后台任务：轮询任务状态，SUCCEEDED后下载GLB + 写回 DB

    支持取消：每轮轮询前检查 _task_registry[task_id]["cancel_requested"]，
    若用户已请求取消则直接退出下载循环（资源不浪费）。
    """
    from services.aliyun_tripo import AliyunTripo

    tripo = AliyunTripo()
    if not tripo.is_configured:
        _task_registry[task_id] = {
            "status": "FAILED",
            "error": "DASHSCOPE_API_KEY not configured",
        }
        marketplace_db.mark_failed(task_id, "DASHSCOPE_API_KEY not configured")
        return

    # 标记 RUNNING（保留 cancel_requested 标记）
    existing = _task_registry.get(task_id) or {}
    _task_registry[task_id] = {**existing, "status": "RUNNING"}
    marketplace_db.mark_running(task_id)

    # 取消感知轮询：每 15s 检查一次，但用户取消后立即退出
    elapsed = 0.0
    poll_interval = 15.0
    max_wait = 600.0
    result = None
    while elapsed < max_wait:
        # 用户取消：立即退出循环，不下载
        if _task_registry.get(task_id, {}).get("cancel_requested"):
            logger.info(f"[Tripo] task {task_id} cancel requested, aborting poll loop")
            return
        try:
            result = await tripo.get_task_result(task_id)
        except Exception as e:
            logger.warning(f"[Tripo] get_task_result error for {task_id}: {e}")
            await asyncio.sleep(poll_interval)
            elapsed += poll_interval
            continue
        if result.task_status in ("SUCCEEDED", "FAILED", "CANCELED"):
            break
        await asyncio.sleep(poll_interval)
        elapsed += poll_interval

    if result is None:
        # 超时或多次失败：标记 FAILED
        _task_registry[task_id] = {
            **(existing or {}),
            "status": "FAILED",
            "error": "轮询超时或多次失败",
        }
        marketplace_db.mark_failed(task_id, "轮询超时或多次失败")
        return

    if _task_registry.get(task_id, {}).get("cancel_requested"):
        # 用户在最后一刻取消：尊重用户意图
        logger.info(f"[Tripo] task {task_id} cancel requested after final poll")
        return

    if result.task_status == "SUCCEEDED":
        pbr_path = None
        base_path = None
        rendered_path = None
        download_errors: list[str] = []

        if result.results:
            first = result.results[0]

            if first.pbr_model_url:
                try:
                    pbr_path = await _download_and_cache(
                        first.pbr_model_url, task_id, "model.glb"
                    )
                except Exception as e:
                    msg = f"GLB 下载失败: {e}"
                    logger.warning(f"[Tripo] {task_id} {msg}")
                    download_errors.append(msg)

            if first.base_model_url:
                try:
                    base_path = await _download_and_cache(
                        first.base_model_url, task_id, "model_base.glb"
                    )
                except Exception as e:
                    msg = f"base GLB 下载失败: {e}"
                    logger.warning(f"[Tripo] {task_id} {msg}")
                    download_errors.append(msg)

            if first.rendered_image_url:
                try:
                    rendered_path = await _download_and_cache(
                        first.rendered_image_url, task_id, "preview.webp"
                    )
                except Exception as e:
                    msg = f"预览图下载失败: {e}"
                    logger.warning(f"[Tripo] {task_id} {msg}")
                    download_errors.append(msg)

        task_type = result.usage.task_type if result.usage else None

        # 若核心文件（GLB）下载失败，整体判为 FAILED；仅预览图失败时仍 SUCCEEDED
        if not pbr_path and result.results and result.results[0].pbr_model_url:
            error_msg = "; ".join(download_errors) or "GLB 文件下载失败"
            _task_registry[task_id] = {
                **(existing or {}),
                "status": "FAILED",
                "error": error_msg,
            }
            marketplace_db.mark_failed(task_id, error_msg)
            return

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
            "warning": "; ".join(download_errors) if download_errors else None,
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
            **(existing or {}),
            "status": "FAILED",
            "error": result.error_message,
        }
        marketplace_db.mark_failed(task_id, result.error_message)
    elif result.task_status == "CANCELED":
        _task_registry[task_id] = {
            **(existing or {}),
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
    request: Request,
    owner_id: str = Depends(_require_user),
):
    """查询任务状态和结果
    - 优先从内存 registry（正在跑的）拿，缺失则回退 DB
    - SUCCEEDED 后优先返回本地缓存路径
    - 本地未下载完则降级为远程 URL
    - FAILED/CANCELED 返回错误信息
    - 私有模型仅 owner 可查
    - **URL 一律返回绝对地址**（修 bug #1：iOS model_viewer_plus 不接受相对 URL）
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
                pbr_model_url=_absolute_url(request, result.results[0].pbr_model_url) if result.results else None,
                base_model_url=_absolute_url(request, result.results[0].base_model_url) if result.results else None,
                rendered_image_url=_absolute_url(request, result.results[0].rendered_image_url) if result.results else None,
                submit_time=result.submit_time,
                end_time=result.end_time,
                can_cancel=False,
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
            "pbr_model_url": None,
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

    if db_row is not None and db_row.visibility == "private" and db_row.owner_id != owner_id:
        raise HTTPException(status_code=403, detail="该模型为私有")

    # GLB URL 降级策略：本地优先，远程兜底 → 转绝对地址
    local_glb = info.get("local_glb")
    if local_glb and Path(local_glb).exists():
        glb_url = _absolute_url(request, f"/tripo/model/{task_id}/glb")
    else:
        glb_url = _absolute_url(request, info.get("pbr_model_url"))

    # 预览图
    local_preview = info.get("local_preview")
    if local_preview and Path(local_preview).exists():
        preview_url = _absolute_url(request, f"/tripo/model/{task_id}/preview")
    else:
        preview_url = _absolute_url(request, info.get("rendered_image_url"))

    # can_cancel: 仅 PENDING/RUNNING 且 owner 匹配
    can_cancel = (
        in_memory is not None
        and info.get("status") in ("PENDING", "RUNNING")
        and (db_row is None or db_row.owner_id == owner_id)
    )

    return StatusResponse(
        code=0,
        task_id=task_id,
        task_status=info.get("status", "UNKNOWN"),
        task_type=info.get("task_type"),
        pbr_model_url=glb_url,
        base_model_url=_absolute_url(request, info.get("base_model_url")),
        rendered_image_url=preview_url,
        submit_time=info.get("submit_time"),
        end_time=info.get("end_time"),
        model_id=info.get("model_id"),
        visibility=info.get("visibility"),
        error_message=info.get("error") or info.get("warning"),
        can_cancel=can_cancel,
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


@router.post("/cancel/{task_id}", response_model=CancelResponse)
async def cancel_task(task_id: str, owner_id: str = Depends(_require_user)):
    """取消正在运行的 Tripo 任务（软删除，不入市场，不扣成功配额）

    - 仅 PENDING/RUNNING 状态可取消
    - 后台轮询协程会在下一轮检查到 cancel_requested 后立即退出下载循环
    - 已在市场（DB）中的记录会标记为 CANCELED，但不会删除文件
    """
    in_mem = _task_registry.get(task_id)
    db_row = marketplace_db.get_by_task_id(task_id)

    if in_mem is None and db_row is None:
        raise HTTPException(status_code=404, detail="任务不存在")

    if db_row is not None and db_row.owner_id != owner_id:
        raise HTTPException(status_code=403, detail="非任务所有者，无权取消")

    current_status = (in_mem or {}).get("status") or (db_row.status if db_row else None)
    if current_status not in ("PENDING", "RUNNING"):
        raise HTTPException(
            status_code=409,
            detail=f"任务当前状态 {current_status} 不可取消",
        )

    existing = in_mem or {}
    _task_registry[task_id] = {
        **existing,
        "cancel_requested": True,
    }
    logger.info(f"[Tripo] task {task_id} cancel requested by {owner_id}")

    return CancelResponse(
        code=0,
        task_id=task_id,
        task_status="CANCELED",
        message="取消请求已提交，1秒内生效",
    )


@router.get("/model/{task_id}/glb_lazy")
async def download_glb_lazy(task_id: str, owner_id: str = Depends(_require_user)):
    """懒下载 GLB：本地有走本地；本地无则从远程流式回传（不落盘）

    避免一次性把 50-200MB GLB 加载到内存或磁盘。仅用于"看一眼"场景。
    真正"保存到本地相册"请走 /model/{task_id}/glb（强制落盘）。
    """
    in_mem = _task_registry.get(task_id)
    db_row = marketplace_db.get_by_task_id(task_id)
    if in_mem is None and db_row is None:
        raise HTTPException(status_code=404, detail="任务不存在")

    _enforce_file_visibility(task_id, owner_id)

    local_path = (in_mem or {}).get("local_glb") or (
        db_row.glb_path if db_row else None
    )
    if local_path and Path(local_path).exists():
        return FileResponse(
            local_path,
            media_type="model/gltf-binary",
            filename=f"{task_id}.glb",
            headers={"Cache-Control": "public, max-age=86400"},
        )

    remote_url = (in_mem or {}).get("pbr_model_url")
    status_ok = (in_mem or {}).get("status") == "SUCCEEDED" or (
        db_row is not None and db_row.status == "SUCCEEDED"
    )
    if not remote_url or not status_ok:
        raise HTTPException(status_code=404, detail="GLB 尚未就绪")

    async def _stream():
        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as client:
            async with client.stream("GET", remote_url) as resp:
                resp.raise_for_status()
                async for chunk in resp.aiter_bytes(chunk_size=256 * 1024):
                    yield chunk

    return StreamingResponse(
        _stream(),
        media_type="model/gltf-binary",
        headers={
            "Content-Disposition": f'inline; filename="{task_id}.glb"',
            "Cache-Control": "public, max-age=3600",
        },
    )


@router.get("/model/{task_id}/preview")
async def download_preview(task_id: str, owner_id: str = Depends(_require_user)):
    """下载渲染预览图

    三段降级：
    1) 本地缓存命中 → 直接 FileResponse
    2) 任务 SUCCEEDED 但本地未就绪 → 代理远程 URL（流式回传），
       同时后台异步落盘到 models_cache/，下次直接命中本地
    3) 都失败 → 404
    """
    in_mem = _task_registry.get(task_id)
    db_row = marketplace_db.get_by_task_id(task_id)
    if in_mem is None and db_row is None:
        raise HTTPException(status_code=404, detail="任务不存在")

    _enforce_file_visibility(task_id, owner_id)

    # 1) 本地优先
    local_path = (in_mem or {}).get("local_preview") or (
        db_row.preview_path if db_row else None
    )
    if local_path and Path(local_path).exists():
        return FileResponse(
            local_path,
            media_type="image/webp",
            headers={"Cache-Control": "public, max-age=86400"},
        )

    # 2) 远程代理：必须 SUCCEEDED 且有 remote URL
    remote_url = (in_mem or {}).get("rendered_image_url")
    if not remote_url and in_mem is None and db_row is not None:
        raise HTTPException(status_code=404, detail="预览图尚未生成")

    status_ok = (in_mem or {}).get("status") == "SUCCEEDED" or (
        db_row is not None and db_row.status == "SUCCEEDED"
    )
    if not remote_url or not status_ok:
        raise HTTPException(status_code=404, detail="预览图尚未生成")

    # 后台异步落盘（best-effort，不阻塞响应）
    asyncio.create_task(_cache_remote_preview(task_id, remote_url))

    async def _stream():
        async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
            async with client.stream("GET", remote_url) as resp:
                resp.raise_for_status()
                async for chunk in resp.aiter_bytes(chunk_size=64 * 1024):
                    yield chunk

    return StreamingResponse(
        _stream(),
        media_type="image/webp",
        headers={"Cache-Control": "public, max-age=3600"},
    )


async def _cache_remote_preview(task_id: str, remote_url: str) -> None:
    """后台把远程预览图下载到本地（best-effort，失败不报错）"""
    try:
        await _download_and_cache(remote_url, task_id, "preview.webp")
        logger.info(f"[Tripo] {task_id} preview cached to disk (lazy)")
    except Exception as e:
        logger.warning(f"[Tripo] {task_id} lazy preview cache failed: {e}")


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
