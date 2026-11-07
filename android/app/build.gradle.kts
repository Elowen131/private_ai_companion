import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// release 凭据只从 android/key.properties 读取（已被 .gitignore 忽略）。
// 明文写死在构建脚本里会随源码一起泄露；CI / 其它机器上没有该文件时退化为
// debug 签名，保证项目仍可构建，但产物不可用于上架。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
val hasReleaseKeystore = keystorePropertiesFile.exists() &&
    keystoreProperties.containsKey("storeFile")

android {
    namespace = "com.elowen131.privateaicompanion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.elowen131.privateaicompanion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // 缺少 key.properties 时仍可构建（本地调试/侧载），但产物是 debug 签名。
                signingConfigs.getByName("debug")
            }
            isDebuggable = false
            // 生产加固：开启 R8 代码混淆 + 资源压缩，缩小体积、提升逆向门槛。
            // 规则见 android/app/proguard-rules.pro；如需排查混淆导致的崩溃，
            // 可临时加 -printmapping 或在 CI 产物里取 app-release-mapping.txt。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // 包体：排除 llamadart 的 Vulkan GPU 后端（约 42MB）。
    // 本 App 端侧推理固定 gpuLayers=0（CPU-only，见 lib/core/llm/local_llm_provider.dart），
    // 该后端永不加载，属纯冗余体积。如要启用 GPU 推理，须先设置 nGpuLayers>0 并在真机验证，
    // 再删除此 exclude（同时 tools/check_apk_size.py 的 Vulkan 硬检查也要放开）。
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/arm64-v8a/libggml-vulkan.so",
                "lib/armeabi-v7a/libggml-vulkan.so",
                "lib/x86_64/libggml-vulkan.so",
                "lib/x86/libggml-vulkan.so",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
