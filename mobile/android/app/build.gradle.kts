plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.sabiowl.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // 【Phase D-Android (2026-07-06)】applicationId を flavor で分岐:
        //   prod flavor: com.sabiowl.app         (App Store / Play Store 提出済)
        //   dev  flavor: com.sabiowl.app.dev     (applicationIdSuffix ".dev" を付与)
        //
        // ⚠ この defaultConfig の applicationId は base 値。実際の値は
        //    productFlavors 内の applicationIdSuffix で確定する。
        applicationId = "com.sabiowl.app"
        //minSdk = flutter.minSdkVersion
        minSdk = 26 // for health plugin
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 【Phase D-Android (2026-07-06)】dev / prod flavor 分離。
    //
    // - dev  flavor: sabiowl-backend-dev.onrender.com + Neon dev branch +
    //                dev Firebase project + dev PostHog + dev RevenueCat に接続
    // - prod flavor: 従来通り本番環境に接続 (App Store / Play Store 版はこちら)
    //
    // Firebase の google-services.json は src/<flavor>/ に配置することで
    // Gradle が自動解決する:
    //   android/app/src/dev/google-services.json  ← dev project 用 (User 手動配置)
    //   android/app/src/prod/google-services.json ← prod project 用 (User 手動配置)
    //   android/app/google-services.json          ← 従来位置 (fallback、初期値は prod と同一を維持)
    flavorDimensions += "env"

    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Sabiowl DEV")
        }
        create("prod") {
            dimension = "env"
            // applicationIdSuffix なし → defaultConfig の com.sabiowl.app のまま
            resValue("string", "app_name", "Sabiowl")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // Desugaring用のライブラリを追加
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}
