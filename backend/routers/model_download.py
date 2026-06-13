"""
离线模型下载路由（端侧 ASR/VL 模型统一分发入口）

端点:
    GET /models/manifest
        返回模型清单（JSON），含 name / version / size / sha256_hint / source
        source 字段："assets" | "cache" | "missing" — 客户端展示用

    GET /models/{name}
        流式返回模型文件二进制
        - 支持 HTTP Range（断点续传）
        - 三层兜底解析路径：
            ① <MODELS_ASSETS_DIR>/<local_assets_filename>  （最高优：随仓库发布）
            ② <MODELS_CACHE_DIR>/<name>.bin                  （次优：运行时下载缓存）
            ③ 上游 ModelScope / HuggingFace                  （兜底：双工 stream + 写盘）
        - 状态头：Accept-Ranges: bytes / Content-Length / ETag / X-Model-Source

    GET /models/{name}/info
        查询单个模型的解析状态（source / size / cached / meta 等）

    GET /models/_cache/stats
        整体缓存统计（不含 assets 预置，assets 是只读只算）

    DELETE /models/{name}/cache
        强制清缓存（不影响 assets）；下次请求会重新解析为 assets 或重新下载

设计要点:
    1) 解析路径：assets → cache → upstream
    2) 上游下载：httpx.streaming，逐 chunk 写盘 + 透传客户端（双工）
    3) 透传兜底：所有路径都失败时返回 502
    4) Range 支持：磁盘已就绪（assets/cache 之一）→ 直接 serve file w/ range
    5) 简单 ETag：version + size 组合，触发 304 节省带宽
"""
import asyncio
import hashlib
import os
import time
from pathlib import Path
from typing import AsyncGenerator, Optional, Tuple

import httpx
from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

from config import (
    MODEL_REGISTRY,
    MANIFEST_VERSION,
    MODELS_CACHE_DIR,
    MODELS_ASSETS_DIR,
)

router = APIRouter(prefix="/models", tags=["offline-models"])

# ── 路径工具 ───────────────────────────────────────────────────────────
CHUNK_SIZE = 64 * 1024  # 64KB（兼顾吞吐和内存）


def _cache_path(name: str) -> Path:
    """<MODELS_CACHE_DIR>/<name>.bin"""
    d = Path(MODELS_CACHE_DIR)
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{name}.bin"


def _meta_path(name: str) -> Path:
    """<MODELS_CACHE_DIR>/<name>.meta.json"""
    d = Path(MODELS_CACHE_DIR)
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{name}.meta.json"


def _assets_path(name: str) -> Optional[Path]:
    """
    返回 assets/models/ 下该模型的实际文件路径（若 local_assets_filename 缺失或文件不存在则 None）
    """
    cfg = MODEL_REGISTRY.get(name, {})
    fn = cfg.get("local_assets_filename")
    if not fn:
        return None
    p = Path(MODELS_ASSETS_DIR) / fn
    return p if p.exists() else None


def _resolve_path(name: str) -> Tuple[Optional[Path], str]:
    """
    三层解析：assets → cache → None

    Returns:
        (path, source)
        - (Path, "assets")  — 预置命中
        - (Path, "cache")   — 下载缓存命中
        - (None, "missing") — 都未命中，需走上游下载
    """
    a = _assets_path(name)
    if a is not None:
        return a, "assets"
    c = _cache_path(name)
    if c.exists():
        return c, "cache"
    return None, "missing"


def _safe_name(name: str) -> str:
    """防止路径穿越：只允许字母数字 + . + - + _"""
    if not name or not all(c.isalnum() or c in ".-_" for c in name):
        raise HTTPException(status_code=400, detail="invalid model name")
    if name not in MODEL_REGISTRY:
        raise HTTPException(status_code=404, detail=f"unknown model: {name}")
    return name


# ── 缓存元数据（与文件同目录，写入轻量 JSON） ────────────────────────
import json


def _write_meta(name: str, version: str, size: int, sha256: str = "") -> None:
    meta = {
        "name": name,
        "version": version,
        "size": size,
        "sha256": sha256,
        "cached_at": int(time.time()),
    }
    _meta_path(name).write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")


def _read_meta(name: str) -> Optional[dict]:
    """读取 cache 层的元数据（assets 层没有 meta）"""
    p = _meta_path(name)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


# ── 上游下载（多源回退，带进度回调） ──────────────────────────────────
async def _stream_upstream(
    name: str,
    on_chunk=None,  # 异步回调 bytes -> None（写盘用）
) -> AsyncGenerator[bytes, None]:
    """
    从 MODEL_REGISTRY[name]['upstream_urls'] 逐源尝试下载。
    只要某个源 200 OK 就持续 stream 完，不再切下一个源。
    失败会重试下一个源；所有源都失败 → 抛 HTTPException 502。
    """
    cfg = MODEL_REGISTRY[name]
    urls = cfg["upstream_urls"]
    last_err: Optional[Exception] = None

    timeout = httpx.Timeout(connect=15.0, read=120.0, write=120.0, pool=120.0)
    async with httpx.AsyncClient(
        timeout=timeout,
        follow_redirects=True,
        headers={"User-Agent": "AIVideo-Backend/1.0 (offline-model-distributor)"},
    ) as client:
        for url in urls:
            try:
                print(f"[model_download] GET upstream {url}")
                async with client.stream("GET", url) as resp:
                    if resp.status_code != 200:
                        print(f"[model_download] upstream {url} → {resp.status_code}, trying next")
                        last_err = httpx.HTTPStatusError(
                            f"{url} → {resp.status_code}",
                            request=resp.request,
                            response=resp,
                        )
                        continue
                    # 200 OK：全量 stream
                    async for chunk in resp.aiter_bytes(chunk_size=CHUNK_SIZE):
                        if on_chunk is not None:
                            await on_chunk(chunk)
                        yield chunk
                    return  # 成功收尾
            except (httpx.RequestError, httpx.HTTPStatusError) as e:
                print(f"[model_download] upstream {url} error: {e}")
                last_err = e
                continue
            except Exception as e:
                print(f"[model_download] upstream {url} unexpected: {e}")
                last_err = e
                continue

    # 所有源都失败
    raise HTTPException(
        status_code=502,
        detail=f"all upstream sources failed for {name}: {last_err}",
    )


# ── /models/manifest ────────────────────────────────────────────────
@router.get("/manifest")
async def get_manifest() -> JSONResponse:
    """
    返回模型清单。
    - manifest_version: 整体版本（客户端用此判断是否要重下整个 manifest）
    - models: 各模型详情，键名与 GET /models/{name} 一致
        - source: "assets" | "cache" | "missing" — 客户端展示"已就绪"用
    """
    items = []
    for name, cfg in MODEL_REGISTRY.items():
        resolved_p, source = _resolve_path(name)
        cache_p = _cache_path(name)
        cached = _read_meta(name)
        items.append({
            "name": name,
            "kind": cfg["kind"],
            "version": cfg["version"],
            "size": cfg["size"],
            "sha256_hint": cfg.get("sha256_hint", ""),
            "source": source,  # assets | cache | missing
            "cached": cached is not None and cache_p.exists(),  # 仅 cache 层有 meta
            "cache_meta": cached,  # None 表示 cache 层未缓存
            "local_assets_filename": cfg.get("local_assets_filename", ""),
        })

    return JSONResponse({
        "manifest_version": MANIFEST_VERSION,
        "models": items,
    })


# ── /models/{name}/info ─────────────────────────────────────────────
@router.get("/{name}/info")
async def get_model_info(name: str) -> JSONResponse:
    name = _safe_name(name)
    cfg = MODEL_REGISTRY[name]
    resolved_p, source = _resolve_path(name)
    cache_p = _cache_path(name)
    cache_meta = _read_meta(name)
    assets_p = _assets_path(name)
    return JSONResponse({
        "name": name,
        "kind": cfg["kind"],
        "version": cfg["version"],
        "size": cfg["size"],
        "source": source,
        "resolved_path": str(resolved_p) if resolved_p else None,
        "assets_path": str(assets_p) if assets_p else None,
        "cache_path": str(cache_p) if cache_p.exists() else None,
        "cache_size": cache_p.stat().st_size if cache_p.exists() else 0,
        "cache_meta": cache_meta,
    })


# ── /models/{name}（核心下载 + 缓存 + Range）────────────────────────
@router.get("/{name}")
async def download_model(name: str, request: Request):
    """
    流式返回模型文件。三层解析：
      ① assets 命中 → serve
      ② cache 命中 → serve
      ③ 都不命中 → 双工 stream（边从上游拉边写 cache 边回传客户端）
    """
    name = _safe_name(name)
    cfg = MODEL_REGISTRY[name]
    resolved_p, source = _resolve_path(name)

    # 公共响应头
    common_headers = {
        "Accept-Ranges": "bytes",
        "X-Model-Name": name,
        "X-Model-Version": str(cfg["version"]),
        "X-Model-Size": str(cfg["size"]),
        "X-Model-Source": source,  # 客户端可知道这次走的是 assets 还是 cache
    }

    # ── 路径 A 或 B：磁盘就绪（assets 或 cache）→ 直接 serve file ──
    if resolved_p is not None:
        return _serve_from_disk(name, resolved_p, source, request, common_headers)

    # ── 路径 C：都不命中 → 双工 stream（边下边写边回传） ──
    cache_p = _cache_path(name)
    if request.headers.get("range"):
        # 客户端带了 Range 但磁盘未命中：先全量下到磁盘，再 Range 切片
        # 为简化：直接返回 200 全量，客户端重新走一遍请求
        pass

    return await _stream_and_cache(name, cache_p, common_headers)


# ── 磁盘服务（带 Range 切片） ─────────────────────────────────────
def _serve_from_disk(
    name: str, file_p: Path, source: str, request: Request, common_headers: dict
) -> Response:
    """
    source: "assets" | "cache" — 用于 ETag 与响应头
    assets 文件没有 meta → ETag 用 version + size
    cache 文件有 meta → ETag 优先用 meta 里的 version
    """
    file_size = file_p.stat().st_size
    range_header = request.headers.get("range") or request.headers.get("Range")
    meta = _read_meta(name) if source == "cache" else None
    version_str = (meta.get("version", "v1") if meta else MODEL_REGISTRY[name]["version"])
    etag = '"' + str(version_str) + "-" + str(file_size) + '"'

    # 处理 If-None-Match
    if_none_match = request.headers.get("if-none-match")
    if if_none_match and if_none_match == etag:
        return Response(status_code=304, headers={**common_headers, "ETag": etag})

    # 处理 Range
    if range_header and range_header.startswith("bytes="):
        try:
            start_str, _, end_str = range_header[len("bytes="):].partition("-")
            if start_str == "" and end_str:
                # 后缀区间：bytes=-N → 取最后 N 字节
                suffix_len = int(end_str)
                if suffix_len <= 0:
                    raise HTTPException(
                        status_code=416,
                        detail="requested range not satisfiable",
                        headers={"Content-Range": f"bytes */{file_size}"},
                    )
                end = file_size - 1
                start = max(0, file_size - suffix_len)
            else:
                start = int(start_str) if start_str else 0
                end = int(end_str) if end_str else file_size - 1
                end = min(end, file_size - 1)
            if start < 0 or start > end or end >= file_size:
                raise HTTPException(
                    status_code=416,
                    detail="requested range not satisfiable",
                    headers={"Content-Range": f"bytes */{file_size}"},
                )
            length = end - start + 1
            headers = {
                **common_headers,
                "Content-Range": f"bytes {start}-{end}/{file_size}",
                "Content-Length": str(length),
                "Content-Type": "application/octet-stream",
                "ETag": etag,
            }
            return StreamingResponse(
                _file_range_iterator(file_p, start, end),
                status_code=206,
                headers=headers,
                media_type="application/octet-stream",
            )
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"bad Range header: {e}")

    # 全量
    headers = {
        **common_headers,
        "Content-Length": str(file_size),
        "Content-Type": "application/octet-stream",
        "ETag": etag,
    }
    return StreamingResponse(
        _file_full_iterator(file_p),
        status_code=200,
        headers=headers,
        media_type="application/octet-stream",
    )


def _file_full_iterator(p: Path) -> AsyncGenerator[bytes, None]:
    async def gen():
        with p.open("rb") as f:
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                yield chunk
    return gen()


def _file_range_iterator(p: Path, start: int, end: int) -> AsyncGenerator[bytes, None]:
    length = end - start + 1

    async def gen():
        remaining = length
        with p.open("rb") as f:
            f.seek(start)
            while remaining > 0:
                chunk = f.read(min(CHUNK_SIZE, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk
    return gen()


# ── 双工 stream（边从上游拉边写盘边回传客户端） ────────────────────
async def _stream_and_cache(
    name: str, cache_p: Path, common_headers: dict
) -> StreamingResponse:
    """
    上游 → 双工：
      1) 每个 chunk 同时 (a) 写入磁盘 (b) 推给客户端
      2) 上游完成 → flush + 写 meta
      3) 中途失败 → 清理半成品文件，下次请求会重下
    """
    cfg = MODEL_REGISTRY[name]
    partial_p = cache_p.with_suffix(cache_p.suffix + ".part")

    # 状态（双协程共享：上游写入 partial_p → 客户端读取 partial_p）
    file_lock = asyncio.Lock()
    ready_event = asyncio.Event()
    error_event: Optional[asyncio.Event] = None  # 简化：异常时用 try/except 抛出
    sha256_hasher = hashlib.sha256()
    bytes_written = 0

    async def on_chunk(chunk: bytes) -> None:
        """上游 chunk 回调：写盘 + 更新哈希"""
        nonlocal bytes_written
        async with file_lock:
            sha256_hasher.update(chunk)
            bytes_written += len(chunk)
            # 同步 IO 在线程池执行，避免阻塞 event loop
            await asyncio.to_thread(_append_bytes, partial_p, chunk)

    async def body_iter() -> AsyncGenerator[bytes, None]:
        # 使用上游 stream 作为唯一 source of truth
        try:
            async for chunk in _stream_upstream(name, on_chunk=on_chunk):
                yield chunk
        except Exception as e:
            print(f"[model_download] stream_and_cache aborted: {e}")
            # 清理半成品
            try:
                if partial_p.exists():
                    await asyncio.to_thread(partial_p.unlink)
            except Exception:
                pass
            raise
        # 落盘完成 → 原子重命名 + 写 meta
        await asyncio.to_thread(_finalize_file, partial_p, cache_p, name, cfg, bytes_written, sha256_hasher.hexdigest())
        print(f"[model_download] {name} cached: {bytes_written} bytes")

    headers = {
        **common_headers,
        "Content-Type": "application/octet-stream",
        # 首次全量：长度用预估；客户端能容忍"实际略大/略小"
        "Content-Length": str(cfg["size"]),
    }
    return StreamingResponse(
        body_iter(),
        status_code=200,
        headers=headers,
        media_type="application/octet-stream",
    )


# ── 文件 IO 工具（线程池） ─────────────────────────────────────────
def _append_bytes(p: Path, data: bytes) -> None:
    with p.open("ab") as f:
        f.write(data)


def _finalize_file(
    partial_p: Path, final_p: Path, name: str, cfg: dict, size: int, sha256: str
) -> None:
    partial_p.rename(final_p)
    _write_meta(name, str(cfg["version"]), size, sha256)


# ── 管理接口（可选，调试用） ───────────────────────────────────────
@router.delete("/{name}/cache")
async def clear_cache(name: str) -> JSONResponse:
    """删除磁盘缓存（强制下次重下）"""
    name = _safe_name(name)
    cache_p = _cache_path(name)
    meta_p = _meta_path(name)
    removed = []
    for p in (cache_p, meta_p):
        if p.exists():
            p.unlink()
            removed.append(p.name)
    return JSONResponse({"name": name, "removed": removed})


@router.get("/_cache/stats")
async def cache_stats() -> JSONResponse:
    """
    查看所有模型的解析状态（assets 预置 + cache 缓存 + upstream 兜底）
    """
    items = []
    total_assets = 0
    total_cache = 0
    for name in MODEL_REGISTRY:
        a_p = _assets_path(name)
        c_p = _cache_path(name)
        a_size = a_p.stat().st_size if a_p else 0
        c_size = c_p.stat().st_size if c_p.exists() else 0
        meta = _read_meta(name)
        _, source = _resolve_path(name)
        total_assets += a_size
        total_cache += c_size
        items.append({
            "name": name,
            "source": source,
            "assets_size": a_size,
            "assets_path": str(a_p) if a_p else None,
            "cache_size": c_size,
            "cache_meta": meta,
        })
    return JSONResponse({
        "assets_dir": str(Path(MODELS_ASSETS_DIR)),
        "cache_dir": str(Path(MODELS_CACHE_DIR)),
        "total_assets_bytes": total_assets,
        "total_cache_bytes": total_cache,
        "models": items,
    })
