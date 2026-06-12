# AI小芒 模型文件说明

## 模型文件下载地址

### 1. Whisper-tiny-int8（TFLite 格式）
- **用途**：端侧语音识别（ASR）
- **HuggingFace**：https://huggingface.co/onnx-community/whisper-tiny-int8/tree/main
- **文件名**：`whisper-tiny-int8.tflite`（约 31MB）
- **加载方式**：`tflite_flutter` 插件加载到 `/assets/whisper-tiny-int8.tflite`
- **魔搭**：魔搭无官方 TFLite 镜像，默认从 HuggingFace 下载

### 2. Qwen2-VL-2B-Instruct（GGUF 量化格式）
- **用途**：端侧视觉理解（VL）
- **魔搭（推荐，国内高速）**：https://modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF
- **HuggingFace（国际）**：https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF
- **推荐量化**：Q4_K_M（约 0.99GB）
- **本地文件名**：`Qwen-VL-2B-Q4_K_M.gguf`
- **加载方式**：`llama_cpp_dart` 插件加载到 `/assets/Qwen-VL-2B-Q4_K_M.gguf`

### 3. Ball OBJ（3D 球体模型）
- **用途**：3D 球体渲染
- **下载地址**：使用代码生成的球体，无需下载

## 下载脚本

```bash
cd assets/
chmod +x download_models.sh
./download_models.sh              # 自动选择最优源
./download_models.sh ms           # 强制从魔搭下载（国内推荐）
./download_models.sh hf           # 强制从 HuggingFace 下载
```

### 下载源说明

| 模型 | 魔搭 | HuggingFace | 默认源 |
|------|------|-------------|--------|
| Whisper TFLite | 无镜像 | ✅ 完整 | HF |
| Qwen-VL GGUF | ✅ bartowski 镜像 | ✅ 完整 | 魔搭 |

## 校验方式

```bash
# Whisper TFLite
md5 assets/whisper-tiny-int8.tflite

# Qwen-VL GGUF
md5 assets/Qwen-VL-2B-Q4_K_M.gguf
```

## 模型文件大小估算

| 模型 | 量化 | 预估大小 |
|------|------|---------|
| Whisper-tiny | int8 TFLite | ~31MB |
| Qwen2-VL-2B | Q4_K_M GGUF | ~0.99GB |

## 重要说明

- 模型文件存放在 `assets/` 目录，通过 `path_provider` 动态路径访问
- **禁止**将模型文件提交到 git 仓库（已在 `.gitignore` 中排除）
- 首次运行时自动检测模型是否存在，不存在则提示用户下载
- 模型文件使用完成后可通过设置页面手动清理缓存释放空间
