// App module — the `__TOKEN__` placeholders are rewritten by
// `scripts/inject-assets.mjs` before Gradle runs (blueprint §9.5).
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "__PACKAGE_NAME__"
    compileSdk = 34

    defaultConfig {
        applicationId = "__PACKAGE_NAME__"
        minSdk = __MIN_SDK__
        targetSdk = __TARGET_SDK__
        versionCode = __VERSION_CODE__
        versionName = "__VERSION_NAME__"
    }

    // Release signing uses the injected keystore when present; otherwise the
    // build falls back to the debug key so CI never fails on a missing secret
    // (the callback then reports `"signed": false`, blueprint §9.3).
    val keystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")
    val hasReleaseKeystore = !keystorePath.isNullOrBlank()

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystorePath!!)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig =
                if (hasReleaseKeystore) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        buildConfig = false
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.webkit:webkit:1.11.0")
}
