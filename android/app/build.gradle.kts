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

    // 包体：排除「永不加载」的 GPU / WebGPU / OpenCL 原生后端。
    // 本 App 端侧推理固定 gpuLayers=0（CPU-only，见 lib/core/llm/local_llm_provider.dart），
    // 且 3D 是纯 Dart CPU 软渲染（见 lib/core/avatar3d/avatar_view.dart），从不走 GPU/WebGPU，
    // 因此以下后端在 CPU-only 路径下永不被 dlopen，属纯冗余体积：
    //   1) llamadart 的 Vulkan 后端（约 42MB）；
    //   2) LiteRT 的 GPU / WebGPU 加速器 + OpenCL/WebGPU 采样器 + Dawn WebGPU 运行时
    //      （libwebgpu_dawn / libLiteRtGpuAccelerator / libLiteRtWebGpuAccelerator /
    //       libLiteRtTopKOpenClSampler / libLiteRtTopKWebGpuSampler，约 21.8MB）。
    // 保留项（红色底线，不得排除）：llama.cpp CPU 后端（libllama.so / libllama-common.so /
    // libggml-base.so / libggml-cpu-*）；以及 LiteRT 的 CPU 推理核心（libLiteRtLm.so /
    // libGemmaModelConstraintProvider.so）——后者是 llamadart 可能启用的备选引擎核心，
    // 待真机验证确认不加载后可进一步剥离（见 docs/performance-architecture.md §10.5）。
    // 如要启用 GPU 推理，须先设置 nGpuLayers>0 并在真机验证，再删除对应 exclude
    // （同时 tools/check_apk_size.py 的硬检查也要放开）。
    packaging {
        jniLibs {
            val gpuBackends = listOf(
                "libggml-vulkan.so",
                "libwebgpu_dawn.so",
                "libLiteRtGpuAccelerator.so",
                "libLiteRtWebGpuAccelerator.so",
                "libLiteRtTopKOpenClSampler.so",
                "libLiteRtTopKWebGpuSampler.so",
            )
            val abis = listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
            excludes += gpuBackends.flatMap { so -> abis.map { "lib/$it/$so" } }.toSet()
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
