package com.elowen131.privateaicompanion

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 系统级分享（缺口 #113）：把导出文件送进 Android 的 ACTION_SEND 分享面板。
 *
 * 设计取舍：
 * - **不引入任何 Dart 第三方插件**。受限网络下 pub.dev 不可达，新依赖会让
 *   `flutter pub get` 直接失败；这里用项目已有的 MethodChannel 模式，零新增包体。
 * - **不直接暴露源路径**。源文件来自 getApplicationDocumentsDirectory()/exports，
 *   通过 [FileProvider] 用 file:// 分享在 Android 7+ 会抛 FileUriExposedException，
 *   且把整个私有目录授权给外部 App 风险过大。因此先复制到 cacheDir/share/，
 *   再用 `<cache-path name="share" path="share/">` 生成 content:// URI。
 * - 只接受**应用私有目录内**的源文件，并对文件名取 basename，杜绝路径穿越与
 *   「把系统任意文件分享出去」的可能。
 */
class ShareBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "private_ai_companion/share"
        private const val MAX_SHARE_BYTES = 64L * 1024 * 1024
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    fun register() {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareFile" -> result.success(
                share(call.argument<String>("path"), call.argument<String>("subject"))
            )
            else -> result.notImplemented()
        }
    }

    private fun share(path: String?, subject: String?): Boolean {
        if (path.isNullOrEmpty()) return false
        val source = File(path)
        // 只分享本 App 私有数据目录里的导出文件；拒绝任意外部路径。
        val privateRoot = context.dataDir?.canonicalFile ?: return false
        if (!source.isFile || !source.canRead()) return false
        if (!source.canonicalFile.path.startsWith(privateRoot.path + File.separator)) return false
        if (source.length() > MAX_SHARE_BYTES) return false

        return try {
            val shareDir = File(context.cacheDir, "share")
            if (!shareDir.exists() && !shareDir.mkdirs()) return false
            // 每次分享前清掉上次的副本，避免缓存无限堆积。
            shareDir.listFiles()?.forEach { runCatching { it.delete() } }
            val copy = File(shareDir, source.name)
            source.copyTo(copy, overwrite = true)

            val uri: Uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                copy,
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mimeTypeOf(source.name)
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, subject ?: source.name)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, "分享导出文件").apply {
                // 从 Service/ApplicationContext 之外的非 Activity context 启动需 NEW_TASK；
                // 这里 context 是 Activity，但保留 flag 对分屏/自由窗口更稳。
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(chooser)
            true
        } catch (_: Exception) {
            // 没有可处理该类型的应用 / FileProvider 配置异常：不崩，返回 false。
            false
        }
    }

    private fun mimeTypeOf(name: String): String = when {
        name.endsWith(".json", ignoreCase = true) -> "application/json"
        name.endsWith(".csv", ignoreCase = true) -> "text/csv"
        name.endsWith(".txt", ignoreCase = true) -> "text/plain"
        else -> "application/octet-stream" // .aicbak 加密容器
    }
}
