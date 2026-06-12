# AI小芒 ProGuard 规则

# ==============================
# TFLite 模型保护（禁止混淆）
# ==============================
# TFLite 模型禁止混淆，安卓 12+ 系统会拦截被混淆的模型文件读取
-keep class org.tensorflow.** { *; }
-keep class com.google.mlkit.** { *; }

# ==============================
# llama.cpp / GGUF 模型保护
# ==============================
-keep class com.example.ai_video.** { *; }

# ==============================
# Flutter 保留规则
# ==============================
-keep class io.flutter.** { *; }
-keep class dev.flutter.** { *; }

# ==============================
# 网络库保护
# ==============================
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn okhttp3.**
-dontwarn okio.**
