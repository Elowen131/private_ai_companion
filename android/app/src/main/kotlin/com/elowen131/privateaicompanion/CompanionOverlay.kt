package com.elowen131.privateaicompanion

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * 桌面/伴生悬浮窗的渲染面（真实 3D 形象）。
 *
 * 与早期「原生 TextView 气泡」不同，本类在 [CompanionOverlayService]（前台服务）中创建
 * **独立的 FlutterEngine**，通过 [FlutterView] 嵌入 [WindowManager] 的悬浮窗，由独立
 * Dart 入口 [OVERLAY_ENTRYPOINT]（见 lib/overlay_main.dart）渲染一个程序化 3D 低多边形
 * 伴生形象。形象随应用退后台仍常驻显示。
 *
 * 与原生 Dart 侧的契约（独立通道，挂在 overlay engine 上）：
 *   MethodChannel('private_ai_companion/overlay_view'):
 *     Dart -> 原生: 'ready'（形象就绪，拉取 pending 初始状态）
 *     Dart -> 原生: 'moveBy' {dx, dy}（戳戳/拎起来手势拖动窗口）
 *     原生 -> Dart: 'update' {name?, mood?, action?, transparent?}（刷新形象）
 */
class CompanionOverlay(private val context: Context) {

    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private val overlayChannelName = "private_ai_companion/overlay_view"
    private val entrypoint = "overlayMain"

    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var root: FrameLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var channel: MethodChannel? = null

    private var ready = false
    private var pendingName: String? = null
    private var pendingMood: String? = null
    private var pendingAction: String? = null
    private var pendingSpec: String? = null // 人设卡推导的视觉规格 JSON
    private var pendingModelPath: String? = null // App 内生成的 .glb 路径
    private var transparent = true // 透明背景；个别机型/ROM 透明 surface 会黑底，需回退不透明

    private var initialX = 0
    private var initialY = 0
    private var initialTouchX = 0f
    private var initialTouchY = 0f

    /** 悬浮窗所需权限（Android M+ 的 SYSTEM_ALERT_WINDOW）。 */
    fun hasPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    fun isShowing(): Boolean = root != null

    /** 显示悬浮伴生；已显示则更新名字与透明模式。无权限 / 加窗失败返回 false。 */
    fun show(
        personaName: String,
        avatarPath: String?,
        style: String,
        transparent: Boolean = true,
        visualSpec: String? = null,
        modelPath: String? = null
    ): Boolean {
        if (!hasPermission()) return false
        if (visualSpec != null) pendingSpec = visualSpec
        if (modelPath != null) pendingModelPath = modelPath
        if (root != null) {
            update(
                personaName = personaName,
                visualSpec = visualSpec,
                modelPath = modelPath
            )
            setTransparent(transparent)
            return true
        }
        this.transparent = transparent

        // 独立 FlutterEngine 的创建 / entrypoint 启动也可能抛（资源不足、引擎初始化失败）。
        // 早期只给 wm.addView 加了 catch，这里一旦异常会直接崩掉前台服务。
        try {
            ensureEngine()
        } catch (_: Exception) {
            hide()
            return false
        }

        val dp = context.resources.displayMetrics.density
        val sizePx = (96 * dp).toInt()

        root = FrameLayout(context).apply {
            addView(
                flutterView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
            )
            setOnTouchListener(::onTouch)
        }

        params = WindowManager.LayoutParams(
            sizePx,
            sizePx,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                WindowManager.LayoutParams.TYPE_PHONE,
            // NOT_FOCUSABLE：不抢输入焦点，用户打字/返回键/键盘照常作用在下层应用。
            // NOT_TOUCH_MODAL：窗口矩形之外的触摸全部透传给下层应用；
            // 配合 96dp 的小角标窗口，屏幕 95% 以上区域完全不受影响。
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            // 透明异常回退：transparent=false 时用 OPAQUE，避免在部分机型上出现黑底。
            if (transparent) PixelFormat.TRANSLUCENT else PixelFormat.OPAQUE
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = (16 * dp).toInt()
            y = (120 * dp).toInt()
        }

        try {
            wm.addView(root, params)
        } catch (_: Exception) {
            // 权限被撤销 / BadTokenException / ROM 限制：清理引擎并返回失败，
            // 由 Service 停止前台，避免留下一个什么都没有的常驻通知。
            hide()
            return false
        }
        // 首屏给个默认心情（style=3d 偏开心），Dart ready 后会用 pending 覆盖。
        update(personaName = personaName, mood = if (style == "3d") "happy" else "calm")
        return true
    }

    /** 运行中切换透明模式：同步 WindowManager 像素格式并通知 Dart 侧回退卡片。 */
    fun setTransparent(value: Boolean) {
        if (transparent == value) return
        transparent = value
        params?.let { p ->
            p.format = if (value) PixelFormat.TRANSLUCENT else PixelFormat.OPAQUE
            root?.let { v ->
                try {
                    wm.updateViewLayout(v, p)
                } catch (_: Exception) {
                    // 视图已移除
                }
            }
        }
        if (ready) pushPending()
    }

    /** 更新心情/动作/名字；原生侧先缓存，Dart 就绪后推送。 */
    fun update(
        mood: String? = null,
        action: String? = null,
        personaName: String? = null,
        visualSpec: String? = null,
        modelPath: String? = null
    ) {
        if (personaName != null) pendingName = personaName
        if (mood != null) pendingMood = mood
        if (action != null) pendingAction = action
        if (visualSpec != null) pendingSpec = visualSpec
        if (modelPath != null) pendingModelPath = modelPath
        if (ready) pushPending()
    }

    /** 隐藏并销毁悬浮窗 + 释放 FlutterEngine。 */
    fun hide() {
        if (root != null) {
            try {
                wm.removeView(root)
            } catch (_: Exception) {
                // 视图已移除
            }
            root = null
        }
        try {
            channel?.setMethodCallHandler(null)
            flutterView?.detachFromFlutterEngine()
        } catch (_: Exception) {
            // 已 detach
        }
        flutterView = null
        try {
            engine?.destroy()
        } catch (_: Exception) {
            // 已销毁
        }
        engine = null
        channel = null
        params = null
        ready = false
        // 清空缓存：否则下次 show 会把上一次角色的心情/动作推给新形象。
        pendingName = null
        pendingMood = null
        pendingAction = null
        pendingSpec = null
        pendingModelPath = null
    }

    /** 创建独立 FlutterEngine 并启动 overlay 入口（仅首次 show 时）。 */
    private fun ensureEngine() {
        if (engine != null) return

        val e = FlutterEngine(context)

        // 透明度经 FlutterSurfaceView 构造参数控制：第二个 boolean 为 opaque。
        // transparent=true 时 opaque=false（真正透明浮在桌面之上）；
        // transparent=false（回退路径）时 opaque=true，避免部分机型透明 surface 黑底。
        val surface = FlutterSurfaceView(context, !transparent)
        surface.setZOrderOnTop(true)

        val fv = FlutterView(context, surface)
        fv.attachToFlutterEngine(e)
        engine = e
        flutterView = fv

        channel = MethodChannel(e.dartExecutor.binaryMessenger, overlayChannelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    ready = true
                    pushPending()
                    result.success(null)
                }
                // 「拎起来」：Dart 手势产生的增量位移，驱动 WindowManager 真正移动窗口。
                "moveBy" -> {
                    val dx = call.argument<Double>("dx") ?: 0.0
                    val dy = call.argument<Double>("dy") ?: 0.0
                    moveBy(dx.toInt(), dy.toInt())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // bundle 路径必须取 FlutterLoader 解析出的真实 flutter_assets 目录。
        // 早期写死 "lib/main.dart"：AOT 下碰巧能用，debug/多引擎场景会找不到 bundle，
        // 表现为悬浮窗一片空白且不报错。
        val bundlePath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(bundlePath, entrypoint)
        )
    }

    /** 把缓存的状态推送给 Dart 形象（仅推送非空字段；transparent 始终下发以驱动回退）。 */
    private fun pushPending() {
        val name = pendingName
        val mood = pendingMood
        val action = pendingAction
        val spec = pendingSpec
        val modelPath = pendingModelPath
        if (name == null && mood == null && action == null &&
            spec == null && modelPath == null) {
            // 仍要至少把 transparent 下发一次（首次 ready 时 Dart 需要知道渲染模式）。
            channel?.invokeMethod("update", mapOf("transparent" to transparent))
            return
        }
        channel?.invokeMethod(
            "update",
            mapOf(
                "name" to name,
                "mood" to mood,
                "action" to action,
                "visualSpec" to spec,
                "modelPath" to modelPath,
                "transparent" to transparent
            )
        )
        pendingName = null
        pendingMood = null
        pendingAction = null
        pendingSpec = null
        pendingModelPath = null
    }

    /** 由悬浮窗内 Dart 手势驱动位移（戳戳/捏捏/拎起来中的「拎起来」）。 */
    private fun moveBy(dx: Int, dy: Int) {
        val p = params ?: return
        val v = root ?: return
        val dm = context.resources.displayMetrics
        // 无边界累加会让窗口被拖出屏幕后永远找不回来。
        val maxX = dm.widthPixels
        val maxY = dm.heightPixels
        p.x = (p.x + dx).coerceIn(-maxX, maxX)
        p.y = (p.y + dy).coerceIn(-maxY, maxY)
        try {
            wm.updateViewLayout(v, p)
        } catch (_: Exception) {
            // 视图已移除
        }
    }

    /**
     * 原生拖拽兜底：FlutterView 通常会消费全部触摸（此时本监听不会触发），
     * 移动由上面的 moveBy 负责；仅在 Flutter 未命中时作为兜底，保证窗口仍可拖动。
     */
    private fun onTouch(v: View, event: MotionEvent): Boolean {
        val p = params ?: return false
        val target = root ?: return false
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                // 角色只占窗口中心的一块圆形区域。落在四角空白处的按下事件
                // 不消费，尽量交还给下层应用（不同 ROM 对窗口内空白透传的
                // 支持程度不同；窗口外由 FLAG_NOT_TOUCH_MODAL 保证透传）。
                val cx = p.width / 2f
                val cy = p.height / 2f
                val r = p.width * 0.47f
                val dx = event.x - cx
                val dy = event.y - cy
                if (dx * dx + dy * dy > r * r) return false
                initialX = p.x
                initialY = p.y
                initialTouchX = event.rawX
                initialTouchY = event.rawY
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                // 与 moveBy 一致地做边界钳制；上一轮只修了 Dart 手势路径，
                // 这条原生兜底路径仍可把窗口拖出屏幕后永远找不回来。
                val dm = context.resources.displayMetrics
                p.x = (initialX + (event.rawX - initialTouchX).toInt())
                    .coerceIn(-dm.widthPixels, dm.widthPixels)
                p.y = (initialY + (event.rawY - initialTouchY).toInt())
                    .coerceIn(-dm.heightPixels, dm.heightPixels)
                try {
                    wm.updateViewLayout(target, p)
                } catch (_: Exception) {
                    // 视图已移除
                }
                return true
            }
        }
        return false
    }
}
