# AI小芒 — AI 视觉语音对话助手

Flutter AI 视觉语音对话助手，支持**离线端侧推理**（零云端费用）和**阿里云云端增强**两种运行模式。

## 功能特性

| 模式 | 能力 | 费用 |
|------|------|------|
| 离线本地 | Whisper-tiny 端侧语音识别 + Qwen-VL-1.8B 端侧视觉理解 + FlutterTts 本地播报 | 0 |
| 云端增强 | 阿里云实时 ASR + 通义千问 VL + 流式 TTS（SSE） | 按量付费 |

- 双模式手动切换，云端网络超时/欠费自动降级离线
- 端侧量化小模型，内存 ≤ 4GB 自动禁用视觉模型
- 3D 球体 AI 状态动效，低端机自动降级 2D 球体
- 摄像头实时预览，640x480 / JPG65 压缩降 Token 成本

## 技术架构

```
Flutter (Android/iOS)
  ├── 摄像头预览层（camera 插件）
  ├── AI 状态球体动效层（2D/3D）
  ├── 业务调度层（Provider 状态管理）
  ├── 端侧 AI 引擎层
  │     ├── Whisper-tiny TFLite（语音识别）
  │     └── Qwen-VL GGUF（视觉理解）
  └── 网络通信层（SSE 下行 + HTTP 上行）
FastAPI（Python）
  ├── SSE 下行流（文本分片 + MP3 音频分片）
  ├── HTTP 上行接口（图像帧 + 音频分片）
  ├── 阿里云实时 ASR
  ├── 通义千问 VL
  └── 阿里云流式 TTS
```

## 依赖列表

| 依赖 | 版本 | 用途 |
|------|------|------|
| `camera` | ^0.11.0+2 | 摄像头预览 |
| `permission_handler` | ^11.3.0 | 运行时权限管理 |
| `flutter_tts` | ^4.0.2 | 离线 TTS 本地播报 |
| `provider` | ^6.1.2 | 状态管理 |
| `glassmorphism` | ^3.0.0 | 磨砂玻璃 UI 效果 |
| `audioplayers` | ^6.0.0 | 云端 MP3 流式播放 |
| `image` | ^4.1.0 | 图像压缩（640x480 JPG65） |
| `connectivity_plus` | ^6.0.0 | 网络状态检测 |
| `path_provider` | ^2.1.3 | 路径读写（模型/缓存） |
| `http` | ^1.2.1 | SSE 订阅 + HTTP 上行 |
| `tflite_flutter` | ^0.10.4 | Whisper 端侧推理（TFLite） |
| `llama_cpp_dart` | ^0.1.10 | Qwen-VL 端侧推理（GGUF） |

> 原创功能：全部业务逻辑代码均为自主实现，第三方依赖如上所列。

## 环境要求

- Flutter SDK >= 3.22.0
- Dart SDK >= 3.2.0
- Android minSdk = 21（目标 Android 12+）
- iOS 最低版本 = 16.0
- Python >= 3.10（后端）

## 安装运行

### 1. Flutter 客户端

```bash
# 安装依赖
flutter pub get

# 运行（需要真机或模拟器）
flutter run
```

### 2. 后端服务（本地开发）

```bash
cd backend

# 创建虚拟环境
python3 -m venv .venv
source .venv/bin/activate

# 安装依赖
pip install -r requirements.txt

# 配置阿里云凭证（复制模板后填入真实密钥）
cp .env.example .env

# 启动（开发模式）
uvicorn main:app --reload --port 8000
```

### 3. 下载模型文件

```bash
# 进入 assets 目录
cd assets

# 执行下载脚本（需要 HuggingFace 账号）
chmod +x download_models.sh
./download_models.sh
```

## 项目结构

```
AIVideo/
├── lib/                    # Flutter 客户端源码
│   ├── main.dart
│   ├── models/             # 数据模型
│   ├── providers/          # Provider 状态管理
│   ├── screens/           # 页面
│   ├── services/          # 业务服务（网络/AI/音视频）
│   ├── utils/             # 工具类
│   └── widgets/           # 可复用组件
├── assets/                # 模型文件 + 下载脚本
├── android/               # Android 平台配置
├── ios/                   # iOS 平台配置
├── backend/               # FastAPI 后端
│   ├── routers/           # API 路由
│   ├── services/          # 阿里云服务封装
│   └── utils/             # 工具
└── docs/                  # 文档
```

## 权限说明

| 平台 | 权限 | 用途 |
|------|------|------|
| Android | CAMERA | 摄像头实时预览 |
| Android | RECORD_AUDIO | 麦克风录音 |
| Android | FOREGROUND_SERVICE | 后台音频保活 |
| Android | WAKE_LOCK | 屏幕保活 |
| iOS | NSCameraUsageDescription | 摄像头实时预览 |
| iOS | NSMicrophoneUsageDescription | 麦克风录音 |
| iOS | UIBackgroundModes: audio | 后台音频播放 |

## 开发规范

- Commit 格式：`【类型(模块): 简短描述｜详细改动说明】`
- PR 每个只做一件事，合并后主分支保持可运行
- 阿里云密钥必须通过 `.env` 文件加载，`.env` 禁止提交

## 交付文档

| 文档 | 说明 |
|------|------|
| `docs/注意事项清单.md` | 运行时问题排查、合规检查清单 |
| `docs/nginx_sse_config.md` | Nginx SSE 反向代理完整配置 |
| `assets/README.md` | 模型文件下载地址与校验说明 |
