package com.example.ai_video

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity

/**
 * 前台音频保活服务
 *
 * 在Android上，当应用进入后台时，系统可能冻结或杀死应用进程。
 * 前台服务（Foreground Service）通过显示一个持久通知来告知用户
 * 应用正在执行后台任务，从而防止系统杀死进程。
 *
 * 用于：录音中、音频播放中、AI思考中等需要持续运行的任务
 */
class AudioForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private val CHANNEL_ID = "ai_video_audio_channel"
    private val NOTIFICATION_ID = 1001

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    /**
     * 构建前台服务通知
     */
    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("AI小芒")
            .setContentText("正在聆听你的声音...")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    /**
     * 创建通知渠道（Android 8.0+ 必须）
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "AI小芒后台服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持AI小芒在后台运行以持续响应"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * 获取屏幕唤醒锁，防止CPU休眠（录制期间保持唤醒）
     */
    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "AIVideo::AudioWakeLock"
        ).apply {
            acquire(10 * 60 * 1000L) // 最多10分钟自动释放
        }
    }

    /**
     * 释放唤醒锁
     */
    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wakeLock = null
    }

    companion object {
        /**
         * 启动前台服务
         */
        fun start(context: Context) {
            val intent = Intent(context, AudioForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * 停止前台服务
         */
        fun stop(context: Context) {
            context.stopService(Intent(context, AudioForegroundService::class.java))
        }
    }
}
