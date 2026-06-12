"""阿里云百炼平台 Tripo 3D模型生成服务（异步任务模式）"""
import asyncio
import httpx
from dataclasses import dataclass, field
from typing import Literal, Any
from config import DASHSCOPE_API_KEY


TripoModel = Literal["Tripo/Tripo-P1.0", "Tripo/Tripo-H3.1"]
TextureQuality = Literal["standard", "detailed"]
GeometryQuality = Literal["standard", "ultra"]
TripoTaskType = Literal["text-to-3d", "image-to-3d", "multi-image-to-3d"]


@dataclass
class TripoGenerationInput:
    """三种生成模式互斥：只能选一种"""
    prompt: str | None = None       # 文生3D
    image: str | None = None         # 单图生3D
    images: list[dict] | None = None  # 多图生3D（固定4个位置，前/左/后/右）


@dataclass
class TripoUsage:
    """用量统计"""
    task_type: TripoTaskType | None = None
    count: int = 0
    texture_quality: str = "standard"
    geometry_quality: str | None = None


@dataclass
class TripoResultItem:
    """单条生成结果"""
    pbr_model_url: str | None = None   # PBR材质GLB（有效期2小时）
    base_model_url: str | None = None  # 无贴图基础GLB
    rendered_image_url: str | None = None  # 渲染预览图


@dataclass
class TripoGenerationResult:
    task_id: str
    task_status: str  # PENDING / RUNNING / SUCCEEDED / FAILED / CANCELED / UNKNOWN
    results: list[TripoResultItem] = field(default_factory=list)
    request_id: str | None = None
    submit_time: str | None = None
    scheduled_time: str | None = None
    end_time: str | None = None
    usage: TripoUsage | None = None
    error_message: str | None = None


class AliyunTripo:
    """
    通过阿里云百炼平台调用 Tripo 模型生成 3D

    文档: https://help.aliyun.com/zh/model-studio/use-trips/tripo-3d-model-generation
    地域: 仅支持 "中国内地（北京）" cn-north-1
    限制: 每人每月最多生成3次
    """

    BASE_URL = "https://dashscope.aliyuncs.com/api/v1"
    SERVICE_PATH = "services/aigc/video-generation/3d-generation"

    def __init__(
        self,
        model: TripoModel = "Tripo/Tripo-P1.0",
        texture_quality: TextureQuality = "standard",
        geometry_quality: GeometryQuality | None = None,
        texture: bool = True,
        pbr: bool = True,
    ):
        self._api_key = DASHSCOPE_API_KEY
        self._model = model
        self._texture_quality = texture_quality
        self._geometry_quality = geometry_quality
        self._texture = texture
        self._pbr = pbr

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
            "X-DashScope-Async": "enable",
        }

    def _build_payload(self, inp: TripoGenerationInput) -> dict:
        params: dict[str, Any] = {"texture_quality": self._texture_quality}
        if not self._texture:
            params["texture"] = False
            params["pbr"] = False
        elif not self._pbr:
            params["pbr"] = False
        if self._geometry_quality and self._model == "Tripo/Tripo-H3.1":
            params["geometry_quality"] = self._geometry_quality

        input_dict: dict[str, Any] = {}
        if inp.prompt:
            input_dict["prompt"] = inp.prompt
        elif inp.image:
            input_dict["image"] = inp.image
        elif inp.images:
            input_dict["images"] = inp.images

        return {
            "model": self._model,
            "input": input_dict,
            "parameters": params,
        }

    async def create_task(self, inp: TripoGenerationInput) -> str:
        """
        创建 3D 生成任务，返回 task_id

        Raises:
            RuntimeError: API Key 未配置或请求失败
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        payload = self._build_payload(inp)

        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            resp = await client.post(
                f"{self.BASE_URL}/{self.SERVICE_PATH}",
                headers=self._headers(),
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

        request_id = data.get("request_id", "")
        output = data.get("output", {})
        task_id = output.get("task_id", "")
        if not task_id:
            raise RuntimeError(f"Failed to get task_id: {data}")
        return task_id

    async def get_task_result(self, task_id: str) -> TripoGenerationResult:
        """
        查询任务状态和结果

        Returns:
            TripoGenerationResult（含 task_status）
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            resp = await client.get(
                f"{self.BASE_URL}/tasks/{task_id}",
                headers=self._headers(),
            )
            resp.raise_for_status()
            data = resp.json()

        output = data.get("output", {})
        results_raw = output.get("results", [])
        results = []
        for r in results_raw:
            results.append(TripoResultItem(
                pbr_model_url=r.get("pbr_model_url"),
                base_model_url=r.get("base_model_url"),
                rendered_image_url=r.get("rendered_image_url"),
            ))

        usage_raw = data.get("usage", {})
        usage = None
        if usage_raw:
            usage = TripoUsage(
                task_type=usage_raw.get("3d_task_type"),
                count=usage_raw.get("count", 0),
                texture_quality=usage_raw.get("texture_quality", "standard"),
                geometry_quality=usage_raw.get("geometry_quality"),
            )

        return TripoGenerationResult(
            task_id=output.get("task_id", task_id),
            task_status=output.get("task_status", "UNKNOWN"),
            results=results,
            request_id=data.get("request_id"),
            submit_time=output.get("submit_time"),
            scheduled_time=output.get("scheduled_time"),
            end_time=output.get("end_time"),
            usage=usage,
            error_message=data.get("message"),
        )

    async def wait_for_completion(
        self,
        task_id: str,
        poll_interval: float = 15.0,
        max_wait: float = 600.0,
    ) -> TripoGenerationResult:
        """
        轮询等待任务完成

        Args:
            task_id: 任务ID
            poll_interval: 轮询间隔（秒），建议15秒
            max_wait: 最大等待时间（秒），默认10分钟
        """
        elapsed = 0.0
        while elapsed < max_wait:
            result = await self.get_task_result(task_id)
            if result.task_status in ("SUCCEEDED", "FAILED", "CANCELED"):
                return result
            await asyncio.sleep(poll_interval)
            elapsed += poll_interval

        return await self.get_task_result(task_id)

    async def text_to_3d(self, prompt: str) -> str:
        """文生3D：创建任务并返回 task_id"""
        return await self.create_task(TripoGenerationInput(prompt=prompt))

    async def image_to_3d(self, image_url: str) -> str:
        """单图生3D：创建任务并返回 task_id"""
        return await self.create_task(TripoGenerationInput(image=image_url))

    async def multi_image_to_3d(self, images: list[dict]) -> str:
        """
        多图生3D：创建任务并返回 task_id

        images: 必须为4个元素的列表，顺序为 [前视角, 左视角, 后视角, 右视角]
                 不需要的视角传空对象 {} 即可
        """
        return await self.create_task(TripoGenerationInput(images=images))
