import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.reader(Charsets.UTF_8).use { reader ->
        localProperties.load(reader)
    }
}

android {
    namespace = "com.verygoodapp.tronclass"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    // jvmTarget 统一在根 build.gradle.kts 的 KotlinJvmCompile 里设成 JVM_11。

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.verygoodapp.tronclass"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只出 arm64。配合 gradle.properties 里的 disable-abi-filtering=true：
        // 否则 Flutter gradle 插件会 clear 掉这里再塞回全部 ABI。
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            if (localProperties["storeFile"] != null) {
                storeFile = file(localProperties["storeFile"] as String)
                storePassword = localProperties["storePassword"] as String
                keyAlias = localProperties["keyAlias"] as String
                keyPassword = localProperties["keyPassword"] as String
            } else {
                println("Release build signing not configured. Use debug signing.")
            }
        }
//        getByName("debug") {
//            storeFile = file("../debug-store-file/debug.keystore")
//            storePassword = "android"
//        }
    }

    // 原来在 AndroidManifest 里写的 android:extractNativeLibs="true"。
    // AGP 9 不再接受写在清单里，改成这里声明。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            if (localProperties["storeFile"] != null) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

flutter {
    source = "../.."
}
