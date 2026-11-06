# ---------------------------------------------------------------------------
# R8 / ProGuard 规则（release 混淆用）
# 目标：混淆 app 代码与字符串、压缩无用资源，同时保留 Flutter / 平台通道 /
# 原生方法 / 序列化所需符号，避免运行期 NoSuchMethod / 反射崩溃。
# ---------------------------------------------------------------------------

# Flutter 框架与嵌入层：保留，避免引擎反射/平台通道调用失败。
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# 原生方法（JNI）声明不能被混淆/裁剪。
-keepclasseswithmembernames class * {
    native <methods>;
}

# 平台通道传递的 Java/Kotlin 数据类型若参与反射（MethodCall 等的实现类）保留。
-keep class io.flutter.plugin.common.** { *; }

# 序列化 / JSON 若使用反射（如 json_serializable / built_value）需保留类名与字段。
# 本项目以手写 toJson/fromJson 为主，但保留通用安全网：
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# sqflite / sqlite 原生库与回调保留。
-keep class io.sqlite.database.** { *; }
-dontwarn io.sqlite.database.**

# 保留 @Keep 标注的类/成员（部分第三方库用到）。
-keep @androidx.annotation.Keep class * { *; }
-keep class * {
    @androidx.annotation.Keep <methods>;
}
-keep class * {
    @androidx.annotation.Keep <fields>;
}
