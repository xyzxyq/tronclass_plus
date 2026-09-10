allprojects {
    repositories {
        google()
        mavenCentral()
    }

    // AGP 9 拿掉了 android.kotlinOptions，jvmTarget 统一在这里设。
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    afterEvaluate {
        if (project.hasProperty("android")) {
            project.extensions.findByName("android")?.let { extension ->
                if (extension is com.android.build.gradle.LibraryExtension) {
                    configureAndroid(extension)
                }
            }
        }
    }
}

fun Project.configureAndroid(extension: com.android.build.gradle.LibraryExtension) {
    if (extension.namespace == null) {
        extension.namespace = project.group.toString()
    }

    // 老插件(编的是 android-31 之类)在 AGP 9 下会因为 androidx 依赖要求
    // compileSdk>=33 直接构建失败。这里统一拉到和 app 一致，省得每个插件
    // 等上游更新。
    val appCompileSdk = 36
    val current = extension.compileSdkVersion
        ?.removePrefix("android-")
        ?.toIntOrNull() ?: 0
    if (current < appCompileSdk) {
        extension.compileSdkVersion(appCompileSdk)
    }

    extension.compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
