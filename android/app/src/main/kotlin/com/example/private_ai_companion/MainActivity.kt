package com.example.private_ai_companion

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 应用入口 Activity，承载两个平台通道：
 *
 * 1) `private_ai_companion/llm` —— 端侧推理**诊断**通道。真实的 GGUF 推理由 Dart 侧
 *    `llm_llamacpp` 插件直接完成（见 LocalLlmProvider），不经过本通道；这里保留
 *    ping/loadModel/generate 声明，仅用于原生在场性探测与后续扩展。
 *
 * 2) `private_ai_companion/overlay` —— 桌面/伴生悬浮窗通道。Activity 只负责权限探测、
 *    设置页跳转与 Intent 转发；真正的渲染面在 CompanionOverlayService（前台服务）。
 *
 * 后端加固（本轮）：
 * - SDK < 23 调用 Settings.canDrawOverlays 会直接 NoSuchMethodError，全部改走 canDrawOverlays()。
 * - show 通过 startForegroundService 启动，捕获 Android 12+ 的后台启动限制异常，
 *   不让一次权限/时机问题把整个 App 崩掉。
 * - hide 改用 stopService：早期用 startService(ACTION_HIDE) 会在服务未运行时白白创建
 *   一个前台服务，且可能与 START_REDELIVER_INTENT 打架导致悬浮窗自动重现。
 * - Android 13+ 动态申请 POST_NOTIFICATIONS，否则前台服务通知不可见。
 */
class MainActivity : FlutterActivity() {
    private val LLM_CHANNEL = "private_ai_companion/llm"
    private val OVERLAY_CHANNEL = "private_ai_companion/overlay"

    /** 语音 / 声纹 / 识别 / 选文件 / 设备凭证，见 VoiceBridge。 */
    private var voice: VoiceBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureNotificationPermission()

        // 语音与通知能力：在这两个通道里注册，Activity 只做生命周期转发。
        val v = VoiceBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        v.register()
        voice = v
        NotificationBridge(this, flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LLM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 诊断用：真实推理在 Dart 侧 llm_llamacpp 插件，通道本身不承载模型。
                    "ping" -> result.success(false)
                    "loadModel" -> result.success(false)
                    "generate" -> result.success(false)
                    "unload" -> result.success(true)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" ->
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    "checkPermission" ->
                        result.success(canDrawOverlays())
                    "requestPermission" -> {
                        if (!canDrawOverlays()) {
                            try {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                                startActivity(intent)
                            } catch (_: Exception) {
                                // 跳转失败：交由 Flutter 侧提示用户手动开启。
                            }
                        }
                        result.success(canDrawOverlays())
                    }
                    "show" -> {
                        if (!canDrawOverlays()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, CompanionOverlayService::class.java).apply {
                            action = CompanionOverlayService.ACTION_SHOW
                            putExtra(
                                CompanionOverlayService.EXTRA_NAME,
                                call.argument<String>("personaName") ?: "伴伴"
                            )
                            putExtra(
                                CompanionOverlayService.EXTRA_AVATAR,
                                call.argument<String>("avatarPath")
                            )
                            putExtra(
                                CompanionOverlayService.EXTRA_STYLE,
                                call.argument<String>("style") ?: "q"
                            )
                            putExtra(
                                CompanionOverlayService.EXTRA_TRANSPARENT,
                                call.argument<Boolean>("transparent") ?: true
                            )
                            // 人设卡推导的视觉规格（JSON 字符串）：悬浮窗是独立 engine，
                            // 只有把规格一起送过去，形象才可能守住「不脱离人设」。
                            putExtra(
                                CompanionOverlayService.EXTRA_VISUAL_SPEC,
                                call.argument<String>("visualSpec")
                            )
                            putExtra(
                                CompanionOverlayService.EXTRA_MODEL_PATH,
                                call.argument<String>("modelPath")
                            )
                        }
                        val started = try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            true
                        } catch (_: Exception) {
                            // Android 12+ 后台启动前台服务会抛
                            // ForegroundServiceStartNotAllowedException；此时不谎报成功。
                            false
                        }
                        result.success(started)
                    }
                    "update" -> {
                        val intent = Intent(this, CompanionOverlayService::class.java).apply {
                            action = CompanionOverlayService.ACTION_UPDATE
                            putExtra(
                                CompanionOverlayService.EXTRA_MOOD,
                                call.argument<String>("mood")
                            )
                            putExtra(
                                CompanionOverlayService.EXTRA_ACTION,
                                call.argument<String>("action")
                            )
                        }
                        val ok = try {
                            startService(intent)
                            true
                        } catch (_: Exception) {
                            false
                        }
                        result.success(ok)
                    }
                    "hide" -> {
                        // 服务未运行时 stopService 是 no-op，不会凭空创建一个前台服务。
                        val intent = Intent(this, CompanionOverlayService::class.java).apply {
                            action = CompanionOverlayService.ACTION_HIDE
                        }
                        val ok = try {
                            stopService(intent)
                        } catch (_: Exception) {
                            false
                        }
                        result.success(ok)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** API 23 以下没有 SYSTEM_ALERT_WINDOW 设置，视为已授权。 */
    private fun canDrawOverlays(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }

    @Deprecated("FlutterActivity 仍以 Activity 形式回调，这里是唯一入口")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 先给语音桥（SAF 选文件 / 系统凭证），未消费再交给引擎。
        val handled = voice?.onActivityResult(requestCode, resultCode, data) ?: false
        if (!handled) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voice?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        try {
            voice?.dispose()
        } catch (_: Exception) {
        }
        voice = null
        super.onDestroy()
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            try {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
            } catch (_: Exception) {
                // 部分 ROM 可能拒绝请求；前台服务仍可运行，仅通知不可见。
            }
        }
    }
}
