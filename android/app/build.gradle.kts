plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.shifter.shifter_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.shifter.shifter_app"
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

    buildFeatures { buildConfig = true }
    flavorDimensions += "distribution"
    productFlavors {
        create("play") { dimension = "distribution" }
        create("direct") { dimension = "distribution" }
    }
    signingConfigs {
        create("production") {
            val file = System.getenv("SHIFTER_ANDROID_KEYSTORE")
            if (file != null) storeFile = rootProject.file(file)
            storePassword = System.getenv("SHIFTER_ANDROID_STORE_PASSWORD")
            keyAlias = System.getenv("SHIFTER_ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("SHIFTER_ANDROID_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("production")
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

// Never produce a distributable debug-signed APK by accident.
tasks.configureEach {
    if (name.startsWith("validateSigning") && name.endsWith("Release")) {
        doFirst {
            for (key in listOf("SHIFTER_ANDROID_KEYSTORE", "SHIFTER_ANDROID_STORE_PASSWORD", "SHIFTER_ANDROID_KEY_ALIAS", "SHIFTER_ANDROID_KEY_PASSWORD")) {
                require(!System.getenv(key).isNullOrBlank()) { "Missing production signing setting: $key" }
            }
        }
    }
}
dependencies {
    "playImplementation"("com.google.android.play:app-update:2.1.0")
}
