# AI小芒 ProGuard 规则
# Android release 构建时生效，防止 TFLite / llama.cpp / httpx / 阿里云 SDK 被混淆

# ==============================
# TFLite 模型保护（禁止混淆）
# ==============================
-keep class org.tensorflow.** { *; }
-keep class com.google.mlkit.** { *; }
-keep class io.tensorflow.** { *; }
-keepclassmembers class org.tensorflow.** { *; }

# ==============================
# llama.cpp / GGUF 模型保护
# ==============================
-keep class llama.cpp.** { *; }
-keep class llama_cpp.** { *; }
-keep class llama_cpp_dart.** { *; }
-keep class io.github.nicknisi.** { *; }
-dontwarn llama.cpp.**
-dontwarn llama_cpp.**
-dontwarn llama_cpp_dart.**

# ==============================
# Flutter 保留规则
# ==============================
-keep class io.flutter.** { *; }
-keep class dev.flutter.** { *; }
-keep class _.packages.** { *; }

# ==============================
# 网络库保护
# ==============================
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn okio.ByteString
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class httpx.** { *; }
-keep class http.** { *; }

# ==============================
# 阿里云 SDK 保护
# ==============================
-keep class com.aliyun.** { *; }
-keep class com.alibaba.** { *; }
-dontwarn com.aliyun.**
-dontwarn com.alibaba.**

# ==============================
# record / audioplayers / flutter_tts
# ==============================
-keep class com.ryanheise.** { *; }
-keep class com.google.android.exoplayer2.** { *; }

# ==============================
# 业务代码保留
# ==============================
-keep class com.example.ai_video.** { *; }
-keep class com.example.ai_video.*.* { *; }

# ==============================
# 通用保留
# ==============================
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# ==============================
# 序列化保护（JSON decode）
# ==============================
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
