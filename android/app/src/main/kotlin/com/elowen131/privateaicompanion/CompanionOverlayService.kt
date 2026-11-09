package com.elowen131.privateaicompanion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.IBinder

/**
 * 桌面/伴生悬浮窗前台服务（退后台常驻）。
 *
 * 把 [CompanionOverlay] 的渲染从 [MainActivity] 搬到本 Service：即使宿主 Activity 被系统
 * 回收、或应用退到后台，悬浮窗依然存活并显示在其他应用之上。通过 startForeground + 常驻
 * 通知满足 Android 8+ 前台服务约束；Android 14 注册 foregroundServiceType=specialUse。
 *
 * 命令契约（由 MainActivity 的 overlay 通道转发，亦可由其它组件直接发 Intent）：
 *   ACTION_SHOW   extra: name / avatar / style / transparent / passthrough -> 启动前台 + 显示悬浮伴生
 *   ACTION_UPDATE extra: mood / action                       -> 更新心情/动作
 *   ACTION_SET_PASSTHROUGH extra: passthrough                -> 动态切换「完全点击透传」
 *   ACTION_HIDE                                            -> 隐藏并停止服务
 *
 * 约束：
 * - HIDE 用 `stopSelfResult(startId)` + START_NOT_STICKY，避免系统把最后的 SHOW 重投回来。
 * - 任何可能创建服务的 action 都先 `ensureForeground()`；**失败必须立即停止服务**，
 *   不能继续 addView（早期实现 catch 里只 stopSelf 却仍继续显示，会留下孤儿窗口并
 *   返回 START_REDELIVER_INTENT 让系统反复重启）。
 * - 缓存最近一次 SHOW 参数，进程被回收后 intent 为 null、或 UPDATE 先于 SHOW 到达时
 *   也能恢复悬浮窗。
 */
class CompanionOverlayService : Service() {

    private val overlay = CompanionOverlay(this)
    private var foregroundStarted = false

    /** 最近一次 SHOW 的参数，用于进程回收后恢复。 */
    private var lastShow: Bundle? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_HIDE -> {
                overlay.hide()
                lastShow = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                // 带 startId 停止：系统认为该 intent 已处理完成，不会重投最后的 SHOW。
                stopSelfResult(startId)
                foregroundStarted = false
                START_NOT_STICKY
            }

            ACTION_SHOW, null -> {
                val extras = if (intent?.action == ACTION_SHOW) intent?.extras else lastShow
                if (extras == null) {
                    stopSelfResult(startId)
                    START_NOT_STICKY
                } else {
                    lastShow = Bundle(extras)
                    if (showFrom(extras, startId)) START_REDELIVER_INTENT else START_NOT_STICKY
                }
            }

            ACTION_UPDATE -> {
                if (!overlay.isShowing()) {
                    // 服务被系统重建、但 Activity 先发来 update：用缓存的 SHOW 恢复窗口，
                    // 而不是简单停服务导致用户已经开启的悬浮窗凭空消失。
                    val cached = lastShow
                    if (cached == null || !showFrom(cached, startId)) {
                        START_NOT_STICKY
                    } else {
                        applyUpdate(intent)
                        START_REDELIVER_INTENT
                    }
                } else if (!ensureForeground()) {
                    stopSelfResult(startId)
                    START_NOT_STICKY
                } else {
                    applyUpdate(intent)
                    START_REDELIVER_INTENT
                }
            }

            ACTION_SET_PASSTHROUGH -> {
                val enabled = intent?.getBooleanExtra(EXTRA_PASSTHROUGH, false) ?: false
                // 记进进程级缓存与 SHOW 参数：服务被系统回收重建后，showFrom 会按这个值
                // 恢复窗口 flags，用户开的「完全点击透传」不会重启后悄悄失效。
                pendingPassthrough = enabled
                lastShow?.putBoolean(EXTRA_PASSTHROUGH, enabled)
                if (overlay.isShowing()) {
                    overlay.setPassthrough(enabled)
                    if (!ensureForeground()) {
                        stopSelfResult(startId)
                        START_NOT_STICKY
                    } else {
                        START_REDELIVER_INTENT
                    }
                } else {
                    // 窗口未显示时 startService 可能凭空创建了服务，立刻收尾，
                    // 绝不留一个没有渲染面的孤儿前台服务；值已缓存，下次 SHOW 生效。
                    stopSelfResult(startId)
                    START_NOT_STICKY
                }
            }

            else -> {
                stopSelfResult(startId)
                START_NOT_STICKY
            }
        }
    }

    private fun applyUpdate(intent: Intent?) {
        overlay.update(
            mood = intent?.getStringExtra(EXTRA_MOOD),
            action = intent?.getStringExtra(EXTRA_ACTION),
        )
    }

    /** 进入前台并显示悬浮窗；任何一步失败都统一收尾，绝不留空通知或孤儿窗口。 */
    private fun showFrom(extras: Bundle, startId: Int): Boolean {
        if (!ensureForeground()) {
            stopSelfResult(startId)
            return false
        }
        // 在 addView 之前恢复透传偏好：CompanionOverlay.show 会按 passthrough 字段
        // 构建 LayoutParams.flags，先设值才能保证新建窗口就带 FLAG_NOT_TOUCHABLE。
        overlay.setPassthrough(
            extras.getBoolean(EXTRA_PASSTHROUGH, pendingPassthrough),
        )
        val ok = overlay.show(
            extras.getString(EXTRA_NAME) ?: "伴伴",
            extras.getString(EXTRA_AVATAR),
            extras.getString(EXTRA_STYLE) ?: "q",
            extras.getBoolean(EXTRA_TRANSPARENT, true),
            extras.getString(EXTRA_VISUAL_SPEC),
            extras.getString(EXTRA_MODEL_PATH),
        )
        if (!ok) {
            lastShow = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
            foregroundStarted = false
        }
        return ok
    }

    override fun onDestroy() {
        overlay.hide()
        foregroundStarted = false
        isRunning = false
        super.onDestroy()
    }

    /** 所有会创建/唤醒服务的路径都必须先进入前台，否则 Android 8+ 会在数秒内杀掉服务。 */
    private fun ensureForeground(): Boolean {
        if (foregroundStarted) return true
        return try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= 34) {
                // Android 14 要求显式声明 foregroundServiceType，否则抛
                // MissingForegroundServiceTypeException。
                startForeground(
                    NOTIF_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIF_ID, notification)
            }
            foregroundStarted = true
            true
        } catch (_: Exception) {
            // 后台启动限制 / 通知渠道异常：由调用方 stopSelfResult 收尾。
            false
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "伴生悬浮窗",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                setShowBadge(false)
                description = "私人 AI 陪伴 · 桌面伴生悬浮窗常驻通知"
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launch = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("伴生悬浮窗运行中")
            .setContentText("轻点返回应用 · 关闭请下拉此通知")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(pi)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    companion object {
        const val ACTION_SHOW = "com.elowen131.privateaicompanion.overlay.SHOW"
        const val ACTION_UPDATE = "com.elowen131.privateaicompanion.overlay.UPDATE"
        const val ACTION_SET_PASSTHROUGH =
            "com.elowen131.privateaicompanion.overlay.SET_PASSTHROUGH"
        const val ACTION_HIDE = "com.elowen131.privateaicompanion.overlay.HIDE"

        const val EXTRA_NAME = "name"
        const val EXTRA_AVATAR = "avatar"
        const val EXTRA_STYLE = "style"
        const val EXTRA_TRANSPARENT = "transparent"
        const val EXTRA_VISUAL_SPEC = "visualSpec"
        const val EXTRA_MODEL_PATH = "modelPath"
        const val EXTRA_MOOD = "mood"
        const val EXTRA_ACTION = "action"
        const val EXTRA_PASSTHROUGH = "passthrough"

        /**
         * 服务是否在运行。MainActivity 用它判断「切换透传」时能不能安全地
         * startService：服务未运行仍发 Intent 会凭空创建一个前台服务。
         * 进程级缓存，服务被回收重建后由 showFrom 读取并恢复窗口 flags。
         */
        @Volatile
        @JvmStatic
        var isRunning = false

        /** 用户在设置页选的完全点击透传状态（跨服务实例存活于本进程内）。 */
        @Volatile
        @JvmStatic
        var pendingPassthrough = false

        const val CHANNEL_ID = "companion_overlay_channel"
        const val NOTIF_ID = 1001
    }
}
