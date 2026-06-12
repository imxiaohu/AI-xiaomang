"""Tripo 3D模型生成路由"""
import os
import asyncio
import httpx
import io
from pathlib import Path
from fastapi import APIRouter, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel, Field
from config import DASHSCOPE_API_KEY

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


# ============ In-memory task registry ============
# {task_id: {"status": str, "pbr_model_url": str, "base_model_url": str, "rendered_image_url": str, "local_glb": str}}
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


async def _poll_and_cache(task_id: str):
    """后台任务：轮询任务状态，SUCCEEDED后下载GLB"""
    from services.aliyun_tripo import AliyunTripo

    tripo = AliyunTripo()
    if not tripo.is_configured:
        _task_registry[task_id] = {
            "status": "FAILED",
            "error": "DASHSCOPE_API_KEY not configured",
        }
        return

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

        _task_registry[task_id] = {
            "status": "SUCCEEDED",
            "task_type": result.usage.task_type if result.usage else None,
            "pbr_model_url": result.results[0].pbr_model_url if result.results else None,
            "base_model_url": result.results[0].base_model_url if result.results else None,
            "rendered_image_url": result.results[0].rendered_image_url if result.results else None,
            "local_glb": str(pbr_path) if pbr_path else None,
            "local_base": str(base_path) if base_path else None,
            "local_preview": str(rendered_path) if rendered_path else None,
            "submit_time": result.submit_time,
            "end_time": result.end_time,
        }
    elif result.task_status == "FAILED":
        _task_registry[task_id] = {
            "status": "FAILED",
            "error": result.error_message,
        }
    elif result.task_status == "CANCELED":
        _task_registry[task_id] = {
            "status": "CANCELED",
            "error": "任务已取消",
        }


def _check_api_key():
    if not DASHSCOPE_API_KEY:
        raise HTTPException(status_code=503, detail="DASHSCOPE_API_KEY not configured")


# ============ Endpoints ============

@router.post("/text-to-3d", response_model=GenerationResponse)
async def text_to_3d(req: TextTo3DRequest, bg: BackgroundTasks):
    """
    文生3D：提交任务，立即返回 task_id，后台轮询下载

    注意：每人每月最多生成3次
    """
    _check_api_key()

    from services.aliyun_tripo import AliyunTripo, TripoGenerationInput

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

    _task_registry[task_id] = {"status": "PENDING"}
    bg.add_task(_poll_and_cache, task_id)
    return GenerationResponse(code=0, message="任务已创建，每月限额3次", task_id=task_id)


@router.post("/image-to-3d", response_model=GenerationResponse)
async def image_to_3d(req: ImageTo3DRequest, bg: BackgroundTasks):
    """
    单图生3D：提交任务，立即返回 task_id，后台轮询下载

    注意：每人每月最多生成3次
    """
    _check_api_key()

    from services.aliyun_tripo import AliyunTripo, TripoGenerationInput

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

    _task_registry[task_id] = {"status": "PENDING"}
    bg.add_task(_poll_and_cache, task_id)
    return GenerationResponse(code=0, message="任务已创建，每月限额3次", task_id=task_id)


@router.post("/multi-image-to-3d", response_model=GenerationResponse)
async def multi_image_to_3d(req: MultiImageTo3DRequest, bg: BackgroundTasks):
    """
    多图生3D：固定4个视角 [前, 左, 后, 右]，不需要的传空对象 {}

    注意：每人每月最多生成3次
    """
    _check_api_key()

    from services.aliyun_tripo import AliyunTripo, TripoGenerationInput

    tripo = AliyunTripo(
        model=req.model,
        texture_quality=req.texture_quality,
    )

    # 构建 images 参数：空对象{} → null，ImageItem → {type, file_token}
    images_list = []
    for item in req.images:
        if isinstance(item, dict):
            # 空对象 {}
            images_list.append(None)
        else:
            # ImageItem
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

    _task_registry[task_id] = {"status": "PENDING"}
    bg.add_task(_poll_and_cache, task_id)
    return GenerationResponse(code=0, message="任务已创建，每月限额3次", task_id=task_id)


@router.get("/status/{task_id}", response_model=StatusResponse)
async def get_status(task_id: str):
    """
    查询任务状态和结果
    - SUCCEEDED 后优先返回本地缓存路径
    - 本地未下载完则降级为远程 URL
    - FAILED/CANCELED 返回错误信息
    """
    if task_id not in _task_registry:
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

    info = _task_registry[task_id]

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
    )


@router.get("/model/{task_id}/glb")
async def download_glb(task_id: str):
    """下载 PBR 材质 GLB 文件：本地优先，远程兜底"""
    if task_id not in _task_registry:
        raise HTTPException(status_code=404, detail="任务不存在")

    info = _task_registry[task_id]
    if info.get("status") != "SUCCEEDED":
        raise HTTPException(
            status_code=202,
            detail=f"任务尚未完成，当前状态: {info.get('status')}",
        )

    # 本地优先
    local_path = info.get("local_glb")
    if local_path and Path(local_path).exists():
        return FileResponse(
            local_path,
            media_type="model/gltf-binary",
            filename=f"{task_id}.glb",
        )

    # 降级到远程 URL
    remote_url = info.get("pbr_model_url")
    if remote_url:
        try:
            content = await _fetch_url_to_bytes(remote_url)
            return StreamingResponse(
                io.BytesIO(content),
                media_type="model/gltf-binary",
                headers={"Content-Disposition": f'attachment; filename="{task_id}.glb"'},
            )
        except Exception:
            pass

    raise HTTPException(status_code=404, detail="GLB 文件尚未下载完成")


@router.get("/model/{task_id}/glb_base")
async def download_glb_base(task_id: str):
    """下载无贴图基础 GLB 文件"""
    if task_id not in _task_registry:
        raise HTTPException(status_code=404, detail="任务不存在")

    info = _task_registry[task_id]
    if info.get("status") != "SUCCEEDED":
        raise HTTPException(status_code=202, detail="任务尚未完成")

    local_path = info.get("local_base")
    if not local_path or not Path(local_path).exists():
        raise HTTPException(status_code=404, detail="无贴图模型尚未生成")

    return FileResponse(
        local_path,
        media_type="model/gltf-binary",
        filename=f"{task_id}_base.glb",
    )


@router.get("/model/{task_id}/preview")
async def download_preview(task_id: str):
    """下载渲染预览图：本地优先，远程兜底"""
    if task_id not in _task_registry:
        raise HTTPException(status_code=404, detail="任务不存在")

    info = _task_registry[task_id]
    local_path = info.get("local_preview")

    # 本地存在则直接返回
    if local_path and Path(local_path).exists():
        return FileResponse(local_path, media_type="image/webp")

    # 本地不存在，降级到远程 URL
    remote_url = info.get("rendered_image_url")
    if remote_url:
        try:
            content = await _fetch_url_to_bytes(remote_url)
            return StreamingResponse(
                io.BytesIO(content),
                media_type="image/webp",
            )
        except Exception:
            pass

    raise HTTPException(status_code=404, detail="预览图尚未生成")


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
