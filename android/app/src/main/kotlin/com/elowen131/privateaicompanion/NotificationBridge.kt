package com.elowen131.privateaicompanion

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

/**
 * 本地通知桥（`private_ai_companion/notify`）。
 *
 * 全部走系统 NotificationManager + AlarmManager，不引入任何推送 SDK：
 * 本 App 承诺「数据不出设备」，不可能把提醒托管到云端推送。
 *
 * - `show`：立即通知（用于「发一条测试通知」验证链路）。
 * - `scheduleDaily`：每天固定时刻的弱提醒（inexact，省电、无需精确闹钟权限）。
 * - 提醒内容由 Dart 侧传入并持久化在偏好里，重启后由 Dart 侧重新下发。
 */
class NotificationBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "private_ai_companion/notify"
        const val CHANNEL_ID = "companion_reminder"
        const val ALARM_ACTION = "com.elowen131.privateaicompanion.DAILY_REMINDER"
        const val REQ_DAILY = 3001

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(
                CHANNEL_ID,
                "陪伴提醒",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "角色问候、世界动态与每日提醒"
                setShowBadge(true)
            }
            nm.createNotificationChannel(ch)
        }

        fun build(context: Context, title: String, body: String): Notification {
            val open = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pi = PendingIntent.getActivity(
                context, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                        PendingIntent.FLAG_IMMUTABLE else 0
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(context, CHANNEL_ID)
            else
                @Suppress("DEPRECATION") Notification.Builder(context)
            return builder
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build()
        }

        fun post(context: Context, id: Int, title: String, body: String) {
            ensureChannel(context)
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(id, build(context, title, body))
            } catch (_: Exception) {
                // 缺权限或 ROM 限制时静默失败，由 Dart 侧读状态提示用户。
            }
        }
    }

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
        ensureChannel(activity)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> result.success(state())
            "show" -> {
                val title = call.argument<String>("title") ?: "陪伴提醒"
                val body = call.argument<String>("body") ?: "这是一条测试通知"
                post(activity, call.argument<Int>("id") ?: 1001, title, body)
                result.success(state())
            }
            "scheduleDaily" -> {
                val hour = (call.argument<Int>("hour") ?: 9).coerceIn(0, 23)
                val minute = (call.argument<Int>("minute") ?: 0).coerceIn(0, 59)
                val title = call.argument<String>("title") ?: "今天的陪伴"
                val body = call.argument<String>("body") ?: "角色正在等你回来"
                result.success(scheduleDaily(hour, minute, title, body))
            }
            "cancelDaily" -> {
                cancelDaily()
                result.success(true)
            }
            "requestPermission" -> {
                if (Build.VERSION.SDK_INT >= 33) {
                    val granted = activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                        PackageManager.PERMISSION_GRANTED
                    if (!granted) {
                        activity.requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001
                        )
                    }
                }
                result.success(state())
            }
            else -> result.notImplemented()
        }
    }

    private fun state(): Map<String, Any> {
        var enabled = true
        var canPost = true
        if (Build.VERSION.SDK_INT >= 33) {
            canPost = activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.getNotificationChannel(CHANNEL_ID)?.let {
                enabled = it.importance != NotificationManager.IMPORTANCE_NONE
            }
        }
        return mapOf(
            "permission" to if (canPost) "granted" else "denied",
            "channelEnabled" to enabled,
            "scheduled" to hasAlarm(),
        )
    }

    private fun scheduleDaily(hour: Int, minute: Int, title: String, body: String): Boolean {
        return try {
            val cal = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
            }
            val intent = Intent(activity, ReminderReceiver::class.java).apply {
                action = ALARM_ACTION
                putExtra("title", title)
                putExtra("body", body)
            }
            val pi = PendingIntent.getBroadcast(
                activity, REQ_DAILY, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                        PendingIntent.FLAG_IMMUTABLE else 0
            )
            val am = activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            // 用不精确闹钟：每日问候不需要秒级准时，换来的是不需要精确闹钟权限
            // 且几乎不耗电（Doze 下由系统合并唤醒）。
            am.setInexactRepeating(
                AlarmManager.RTC_WAKEUP,
                cal.timeInMillis,
                AlarmManager.INTERVAL_DAY,
                pi
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun cancelDaily() {
        try {
            val intent = Intent(activity, ReminderReceiver::class.java).apply {
                action = ALARM_ACTION
            }
            val pi = PendingIntent.getBroadcast(
                activity, REQ_DAILY, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                        PendingIntent.FLAG_IMMUTABLE else 0
            )
            (activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pi)
            pi.cancel()
        } catch (_: Exception) {
        }
    }

    private fun hasAlarm(): Boolean {
        val intent = Intent(activity, ReminderReceiver::class.java).apply {
            action = ALARM_ACTION
        }
        val pi = PendingIntent.getBroadcast(
            activity, REQ_DAILY, intent,
            PendingIntent.FLAG_NO_CREATE or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_IMMUTABLE else 0
        )
        return pi != null
    }
}

/** 每日提醒的落地端：闹钟响了就直接发一条本地通知。 */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) return
        if (intent?.action != NotificationBridge.ALARM_ACTION) return
        val title = intent.getStringExtra("title") ?: "今天的陪伴"
        val body = intent.getStringExtra("body") ?: "角色正在等你回来"
        NotificationBridge.post(context, 1002, title, body)
    }
}
