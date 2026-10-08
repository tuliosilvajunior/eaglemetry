plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.timhss.capyenergy.companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.timhss.capyenergy.companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // CI beta builds use a persistent signing key so Android can install a
    // new Firebase-distributed APK over the previous one. Local release builds
    // keep using the debug key unless these environment values are present.
    val companionKeystorePath = System.getenv("COMPANION_KEYSTORE_PATH")
    val companionKeystorePassword = System.getenv("COMPANION_KEYSTORE_PASSWORD")
    val companionKeyAlias = System.getenv("COMPANION_KEY_ALIAS")
    val companionKeyPassword = System.getenv("COMPANION_KEY_PASSWORD")
    val hasCompanionSigningKey = listOf(
        companionKeystorePath,
        companionKeystorePassword,
        companionKeyAlias,
        companionKeyPassword
    ).all { !it.isNullOrBlank() }

    if (hasCompanionSigningKey) {
        signingConfigs.create("companionRelease") {
            storeFile = file(requireNotNull(companionKeystorePath))
            storePassword = requireNotNull(companionKeystorePassword)
            keyAlias = requireNotNull(companionKeyAlias)
            keyPassword = requireNotNull(companionKeyPassword)
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasCompanionSigningKey) {
                signingConfigs.getByName("companionRelease")
            } else {
                // Keep local `flutter run --release` usable without secrets.
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    implementation("com.google.firebase:firebase-appdistribution:16.0.0-beta14")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
