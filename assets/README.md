# 模型文件说明

本目录包含 AI小芒 端侧离线推理所需的模型文件。

## 模型清单

| 文件名 | 来源 | 大小 | 说明 |
|--------|------|------|------|
| `whisper-tiny-int8.tflite` | HuggingFace | ~31 MB | Whisper-tiny 语音识别模型（TFLite格式，int8量化） |
| `Qwen-VL-2B-Q4_K_M.gguf` | ModelScope / HuggingFace | ~990 MB | Qwen2-VL-2B 视觉理解模型（GGUF格式，Q4_K_M量化） |
| `ball.obj` | 本项目生成 | ~40 KB | 3D球体OBJ模型（用于flutter_3d_obj渲染） |

## 模型下载

运行根目录的下载脚本：

```bash
cd assets
chmod +x download_models.sh
./download_models.sh
```

### 下载源说明

| 模型 | 推荐下载源 | 原因 |
|------|-----------|------|
| Whisper TFLite | HuggingFace | ModelScope 无官方 TFLite 镜像 |
| Qwen-VL GGUF | ModelScope（国内） | HuggingFace 在国内速度较慢 |

### 环境变量（可选）

```bash
# HuggingFace（用于私有模型或加速）
export HF_TOKEN_COOKIE='从浏览器复制的完整Cookie'

# ModelScope（用于私有模型或加速）
export MS_TOKEN='your_modelscope_token'
```

## 放置位置

下载后将模型文件放入 `assets/` 目录即可：

```
AIVideo/
└── assets/
    ├── whisper-tiny-int8.tflite   # 必须
    ├── Qwen-VL-2B-Q4_K_M.gguf       # 必须
    └── ball.obj                     # 可选（flutter_3d_obj 渲染3D球体用）
```

## 模型加载路径

模型在 Flutter 端按以下顺序查找：

1. 应用私有目录（优先）：`getApplicationDocumentsDirectory()/models/`
2. assets 目录（fallback）：`assets/`

建议首次运行时自动从 assets 复制到私有目录，参考 `offline_ai_engine.dart` 中的 `_getModelPath()` 方法。

## 校验方式

下载后可用以下命令确认文件完整（非 HTML 错误页）：

```bash
# 检查文件大小（tflite 应 > 10MB，gguf 应 > 500MB）
ls -lh assets/*.tflite assets/*.gguf

# 检查文件头（排除 HTML 错误页）
head -c 20 assets/whisper-tiny-int8.tflite | xxd
# 正常TFLite文件头应为: 0x000... 类型的二进制数据
# 若看到 "3c21444f435459"（<!DOCT）则是 HTML 错误页
```

## Whisper TFLite 模型说明

- **模型**: [onnx-community/whisper-tiny-int8](https://huggingface.co/onnx-community/whisper-tiny-int8)
- **格式**: TFLite FlatBuffer（`.tflite`）
- **量化**: int8（体积小，适合移动端）
- **输入**: Mel Spectrogram (80x3000 float32)
- **输出**: 文本（需 CTC 解码）

## Qwen-VL GGUF 模型说明

- **模型**: [bartowski/Qwen2-VL-2B-Instruct-GGUF](https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF)
- **量化**: Q4_K_M（4-bit量化，精度与体积平衡）
- **格式**: GGUF（llama.cpp 原生格式）
- **加载方式**: llama_cpp_dart

> 注意：Qwen-VL GGUF 文件约 1GB，首次加载可能需要 30-60 秒。

## 3D 球体 OBJ

- 如不使用真实 3D 渲染（推荐：当前模拟 2D 方案已足够），可跳过 `ball.obj`
- 如需启用：在 `pubspec.yaml` 中添加 `flutter_3d_obj` 依赖
