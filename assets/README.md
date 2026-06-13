# 模型文件说明

本目录原本用于存放打包在 app bundle 中的 AI 端侧推理模型。
**自 2026-06 起改为运行时下载**：模型不再随 app 安装包发布，而是在**首次启动时由 app 自动下载到设备的 `Documents/models/` 目录**。

> 这个改动是为了绕过 iOS 平台的两个硬限制：
> 1. `rootBundle.load()` 对大体积资产（≥ 几百 MB）会触发 `AssetManifest.json` 加载失败
> 2. App Store / TestFlight 对安装包体积有严格上限（200MB / 4GB 警告线）
>
> 改为运行时下载后，app 本身只有几十 MB，模型走标准 HTTP 下载到本地磁盘。

## 1. 目录结构

```
AIVideo/
└── assets/
    ├── ball.obj                # 3D 球体模型（打包进 app bundle，小于 1MB）
    ├── ball.mtl
    ├── README.md               # 本文件
    └── download_models.sh      # 桌面端手动预下载脚本（可选）
```

> ⚠️ `assets/models/` 目录已不再需要；即便创建了也不会被打包进 iOS/Android 安装包。
> `.gitignore` 中 `assets/models/*` 仍然保留，防止开发者误将模型提交到仓库。

## 2. 模型清单

| 模型                                    | 用途                       | 大小       | 运行时存放位置                                              |
| --------------------------------------- | -------------------------- | ---------- | ----------------------------------------------------------- |
| `vosk-model-small-cn-0.22.zip`          | 中文 ASR（Vosk）           | ~40 MB     | `<AppDocs>/models/vosk-model-small-cn-0.22/`（解压后）      |
| `Qwen2-VL-2B-Instruct-Q4_K_M.gguf`      | 视觉理解（Qwen2-VL）       | ~990 MB    | `<AppDocs>/models/Qwen2-VL-2B-Instruct-Q4_K_M.gguf`          |
| `mmproj-Qwen2-VL-2B-Instruct-f16.gguf`  | 视觉投影器（mmproj）       | ~1.3 GB    | `<AppDocs>/models/mmproj-Qwen2-VL-2B-Instruct-f16.gguf`     |

`<AppDocs>` 的具体路径：
- iOS: `<App沙盒>/Documents/`（`getApplicationDocumentsDirectory()`）
- Android: `/data/data/<package>/app_flutter/`（同上 API）
- macOS / 桌面端调试: `~/Documents/AIVideo/models/`

## 3. 首次启动自动下载流程

```
[App 启动]
    ↓
AppState.init()
    ↓
OfflineAIEngine.init()
    ↓
checkMissingModels() ──→ 如有缺失，UI 顶部出现绿色下载进度条
    ↓                      状态：Vosk 中文模型 30% / Qwen2-VL 65% / mmproj 100%
    ↓
downloadIfMissing()  (三段式：vosk 30% → vl 35% → mmproj 35%)
    ↓
onDownloadProgress(0.0~1.0, currentFile) 回调
    ↓
onDownloadComplete(true) 触发
    ↓
_loadVosk() + _loadVL()  (从磁盘加载到 native 引擎)
    ↓
asrAvailable=true / vlAvailable=true → 离线模式就绪
```

- 下载源：Vosk 走 alphacephei.com；Qwen2-VL / mmproj 走 ModelScope + HuggingFace 备份源
- 进度可视化：状态栏绿色 banner 实时显示 `下载中 35%`
- 失败重试：状态栏红色条点击重试，无需重启 app
- 幂等：每次启动只检查文件存在性，已存在会跳过

## 4. 桌面端手动预下载（开发/调试用）

如果想在 PC 上预先下载好模型（便于调试或离线分发），运行：

```bash
cd assets
bash download_models.sh
```

脚本会把模型下载到 `./models/`（**仅供桌面参考**）。**移动端 app 不读这个目录**，
只通过运行时 HTTP 拉取。

## 5. 下载源

- Vosk 中文: <https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip>
- Qwen2-VL GGUF（主）: <https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf>
- Qwen2-VL GGUF（备份）: <https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf>
- mmproj（主）: <https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen2-VL-2B-Instruct-f16.gguf>
- mmproj（备份）: <https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen2-VL-2B-Instruct-f16.gguf>

## 6. 校验方式

```bash
# iOS 沙盒
APP_DOCS=$(xcrun simctl get_app_container booted org.xxx.AIVideo data)
ls -lh "$APP_DOCS/Documents/models/"

# 期望输出：
# drwxr-xr-x  vosk-model-small-cn-0.22/        ~40 MB
# -rw-r--r--  Qwen2-VL-2B-Instruct-Q4_K_M.gguf  ~990 MB
# -rw-r--r--  mmproj-Qwen2-VL-2B-Instruct-f16.gguf  ~1.3 GB
```

## 7. 推理后端

- ASR: `vosk_flutter_service ^0.1.1`（社区维护的 vosk_flutter 活跃分支，iOS 兼容）
- VL:  `llama_cpp_dart ^0.2.2`（GGUF 加载 + ChatML 提示词格式）
