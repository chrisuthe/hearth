pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("com.android.kotlin.multiplatform.library") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    id("org.jetbrains.kotlin.jvm") version "2.4.0" apply false
    id("org.jetbrains.kotlin.multiplatform") version "2.4.0" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.4.0" apply false
}

include(":app")

// The voice satellite is our Ava fork, pinned as a submodule. Its own build
// scripts pin an older AGP, Kotlin and Gradle, so the three library modules
// are built from the scripts under ava/, whose source sets point into the
// submodule. Dependency versions come from the fork's catalog so they move
// with the pin.
val avaCatalog = file("third_party/ava/gradle/libs.versions.toml")
require(avaCatalog.isFile) {
    "android/third_party/ava is empty. Run: git submodule update --init"
}

dependencyResolutionManagement {
    versionCatalogs {
        create("ava") {
            from(files(avaCatalog))
        }
    }
}

for (module in listOf("esphomeproto", "microfeatures", "satellite")) {
    include(":ava-$module")
    project(":ava-$module").projectDir = file("ava/$module")
}

// The Sendspin player is SendspinDroid's :shared and :player, pinned as a
// submodule by commit and built from the scripts under sendspin/. SendspinDroid
// has no version catalog; those scripts carry its dependency versions.
require(file("third_party/sendspindroid/android/player").isDirectory) {
    "android/third_party/sendspindroid is empty. Run: git submodule update --init"
}

for (module in listOf("shared", "player")) {
    include(":sendspin-$module")
    project(":sendspin-$module").projectDir = file("sendspin/$module")
}
