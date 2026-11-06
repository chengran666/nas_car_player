plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.nas_car_player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.nas_car_player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        getByName("debug") {
            // Exact copy of the original key: moving computers must not change identity.
            val portableKey = rootProject.file("signing/player.keystore")
            if (portableKey.isFile) {
                storeFile = portableKey
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }

    buildTypes {
        release {
            // Both build types keep the same key for device preference recovery.
            signingConfig = signingConfigs.getByName("debug")
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

// Direct-download packages share one update feed. Flutter normally adds an ABI
// offset to split version codes, which makes a later universal APK look older.
// Register after Flutter's variant callback, before AGP finalizes metadata.
android.applicationVariants.all {
    outputs.forEach { output ->
        (output as com.android.build.gradle.api.ApkVariantOutput)
            .versionCodeOverride = flutter.versionCode
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
