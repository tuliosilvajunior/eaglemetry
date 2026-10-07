import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val emulatorBuild = System.getenv("EAGLEMETRY_EMULATOR") == "true"

val supabaseFunctionsUrl: String by lazy {
    val props = Properties()
    val localPropsFile = rootProject.file("local.properties")
    if (localPropsFile.exists()) {
        localPropsFile.inputStream().use { props.load(it) }
    }
    val fromLocal = props.getProperty("SUPABASE_FUNCTIONS_URL")
    val fromGradle = findProperty("SUPABASE_FUNCTIONS_URL") as String?
    val fromEnv = System.getenv("SUPABASE_FUNCTIONS_URL")
    fromLocal ?: fromGradle ?: fromEnv ?: ""
}

// The car's PostgREST endpoint (Lane C control plane). Both land empty unless a
// project is wired, matching SUPABASE_FUNCTIONS_URL: a build with no project is
// a build that runs fully without the cloud.
val supabaseUrl: String by lazy {
    val props = Properties()
    val localPropsFile = rootProject.file("local.properties")
    if (localPropsFile.exists()) {
        localPropsFile.inputStream().use { props.load(it) }
    }
    val fromLocal = props.getProperty("SUPABASE_URL")
    val fromGradle = findProperty("SUPABASE_URL") as String?
    val fromEnv = System.getenv("SUPABASE_URL")
    fromLocal ?: fromGradle ?: fromEnv ?: ""
}

val supabaseAnonKey: String by lazy {
    val props = Properties()
    val localPropsFile = rootProject.file("local.properties")
    if (localPropsFile.exists()) {
        localPropsFile.inputStream().use { props.load(it) }
    }
    val fromLocal = props.getProperty("SUPABASE_ANON_KEY")
    val fromGradle = findProperty("SUPABASE_ANON_KEY") as String?
    val fromEnv = System.getenv("SUPABASE_ANON_KEY")
    fromLocal ?: fromGradle ?: fromEnv ?: ""
}

// Update channel (self-update manifest URL). Local and CI settings can still
// override this value, while the public Eaglemetry release channel is the
// safe default for signed production builds.
val appUpdateManifestUrl: String by lazy {
    val props = Properties()
    val localPropsFile = rootProject.file("local.properties")
    if (localPropsFile.exists()) {
        localPropsFile.inputStream().use { props.load(it) }
    }
    val fromLocal = props.getProperty("APP_UPDATE_MANIFEST_URL")
    val fromGradle = findProperty("APP_UPDATE_MANIFEST_URL") as String?
    val fromEnv = System.getenv("APP_UPDATE_MANIFEST_URL")
    fromLocal ?: fromGradle ?: fromEnv ?:
        "https://github.com/tuliosilvajunior/eaglemetry-releases/releases/latest/download/latest.json"
}

val chargeControlManifestUrl: String by lazy {
    val props = Properties()
    val localPropsFile = rootProject.file("local.properties")
    if (localPropsFile.exists()) {
        localPropsFile.inputStream().use { props.load(it) }
    }
    val fromLocal = props.getProperty("CHARGE_CONTROL_MANIFEST_URL")
    val fromGradle = findProperty("CHARGE_CONTROL_MANIFEST_URL") as String?
    val fromEnv = System.getenv("CHARGE_CONTROL_MANIFEST_URL")
    fromLocal ?: fromGradle ?: fromEnv ?: ""
}

// Cloud sync gate (Lanes A/B/C): real cloud sync is wired and defaults ON.
// Standing decision from the owner: the cloud stays on; an unconfigured
// build still moves nothing because the Supabase URL/key are empty unless a
// project is wired (see above). An explicit `false` in local.properties /
// gradle property / env still turns the gate off for a build that needs it.
// Sourced like the other SUPABASE_* keys: local.properties → gradle
// property → env → "true". Keeps the established credential pattern.
val cloudSyncEnabled: Boolean by lazy {
    val props = Properties()
    val localPropsFile = rootProject.file("local.properties")
    if (localPropsFile.exists()) {
        localPropsFile.inputStream().use { props.load(it) }
    }
    val fromLocal = props.getProperty("CLOUD_SYNC_ENABLED")
    val fromGradle = findProperty("CLOUD_SYNC_ENABLED") as String?
    val fromEnv = System.getenv("CLOUD_SYNC_ENABLED")
    (fromLocal ?: fromGradle ?: fromEnv ?: "true").toBoolean()
}
// Platform keystore resolution: PLATFORM_KEYSTORE_PATH env > in-repo path > actionable failure.
// The repo holds the public AOSP test platform key as refs/aosp-security/platform.pk8 +
// platform.x509.pem (committed, not secret). The JKS is built from
// that pair via scripts/generate_platform_keystore.sh and is ignored by .gitignore.
// Resolution order is: env var if set, else refs/aosp-security/platform.jks inside this repo.
// CI sets PLATFORM_KEYSTORE_PATH to $RUNNER_TEMP/platform.jks via PLATFORM_KEYSTORE_BASE64.
val platformKeystoreInRepo = rootProject.projectDir.parentFile.resolve("refs/aosp-security/platform.jks")
val platformKeystoreEnvPath = System.getenv("PLATFORM_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }
val platformKeystoreFile = if (platformKeystoreEnvPath != null) file(platformKeystoreEnvPath) else platformKeystoreInRepo

android {
    namespace = "com.timhss.capyenergy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    useLibrary("android.car")

    // android.util.Log is a stub in the JVM test runtime. Without this, a
    // class that only logs throws "not mocked" and the test reports a fault
    // the product does not have.
    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    buildFeatures {
        aidl = true
        buildConfig = true
    }

    signingConfigs {
        create("platformRelease") {
            storeFile = platformKeystoreFile
            storePassword = System.getenv("PLATFORM_STORE_PASSWORD") ?: "android"
            keyAlias = System.getenv("PLATFORM_KEY_ALIAS") ?: "platform"
            keyPassword = System.getenv("PLATFORM_KEY_PASSWORD") ?: "android"
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.timhss.capy"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // MigrationTestHelper reads the exported schemas from the test APK assets.
        sourceSets["androidTest"].assets.srcDir("$projectDir/schemas")
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The target head unit is arm64; Roadcast binaries are built for that ABI.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        buildConfigField("String", "SUPABASE_FUNCTIONS_URL", "\"${supabaseFunctionsUrl}\"")
        buildConfigField("String", "SUPABASE_URL", "\"${supabaseUrl}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${supabaseAnonKey}\"")
        buildConfigField("String", "APP_UPDATE_MANIFEST_URL", "\"${appUpdateManifestUrl}\"")
        buildConfigField("String", "CHARGE_CONTROL_MANIFEST_URL", "\"${chargeControlManifestUrl}\"")
        // Cloud-sync gate — defaults ON. Real sinks are resolved only when
        // this flag is true AND Supabase URL/key are configured.
        // See TelemetryGraph.cloudSyncEnabled for the runtime read.
        buildConfigField("boolean", "CLOUD_SYNC_ENABLED", "$cloudSyncEnabled")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    if (emulatorBuild) {
        sourceSets.getByName("debug").manifest.srcFile("src/emulator/AndroidManifest.xml")
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("platformRelease")
        }
        // The app joins `android.uid.system` (see AndroidManifest.xml), and a
        // package only enters a shared uid when its signature matches the other
        // members. A debug APK on the default debug key is refused with
        // INSTALL_FAILED_SHARED_USER_INCOMPATIBLE — and the failed install
        // session removes the app that was there first, data and all. Debug
        // therefore carries the platform key too, which is also what lets the
        // instrumented tests install on the car.
        // When the platform keystore is absent, debug falls back to the
        // default debug keystore so that `flutter test`, `help`, and other
        // non-signing tasks still configure successfully — the release build
        // will still fail with an actionable message (see below).
        debug {
            if (emulatorBuild) {
                applicationIdSuffix = ".emulator"
                buildConfigField("boolean", "CLOUD_SYNC_ENABLED", "false")
                versionNameSuffix = "-debug"
            }
            signingConfig = if (!emulatorBuild && platformKeystoreFile.exists()) {
                signingConfigs.getByName("platformRelease")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Actionable failure when the platform keystore cannot be resolved.
// Only the release signing path is gated — debug already falls back above,
// so a missing keystore does not break `flutter test`, `tasks`, etc.
tasks.matching { it.name == "validateSigningRelease" }.configureEach {
    doFirst {
        val envPath = System.getenv("PLATFORM_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }
        val exists = when {
            envPath != null -> file(envPath).exists()
            else -> platformKeystoreInRepo.exists()
        }
        if (!exists) {
            val hint = if (envPath != null) {
                "PLATFORM_KEYSTORE_PATH is set to '$envPath' but that file does not exist."
            } else {
                "No keystore found at ${platformKeystoreInRepo.absolutePath} and PLATFORM_KEYSTORE_PATH is not set."
            }
            throw GradleException(
                """
                Platform keystore not found for signing config 'platformRelease'.
                $hint

                This is the public AOSP test platform key (alias platform, store and key passwords 'android'), not a confidential OEM production key..

                To generate the keystore, run:
                  scripts/generate_platform_keystore.sh

                That script builds refs/aosp-security/platform.jks from the committed
                public certificate refs/aosp-security/platform.x509.pem and private key
                refs/aosp-security/platform.pk8 via openssl + keytool. The resulting
                certificate SHA-256 is c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8,
                pinned by .github/workflows/release.yml as EXPECTED_SIGNING_CERT_SHA256.

                Alternatively, set PLATFORM_KEYSTORE_PATH to an existing keystore path.
                CI restores it from the PLATFORM_KEYSTORE_BASE64 secret into ${'$'}RUNNER_TEMP/platform.jks.
                """.trimIndent()
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
tasks.withType<Test>().configureEach {
    // `testdata/` sits outside both source trees and holds the one set of cases
    // the two suites are checked against, so neither language owns the
    // specification. See the test fixtures in testdata/.
    systemProperty(
        "geely.testdata",
        rootProject.projectDir.parentFile.resolve("testdata").absolutePath
    )
}

flutter {
    source = "../.."
}

dependencies {
    val roomVersion = "2.8.4"
    val coroutinesVersion = "1.8.1"

    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    // Declared directly because Roadcast owns a long-lived StateFlow outside Room.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:$coroutinesVersion")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    ksp("androidx.room:room-compiler:$roomVersion")
    testImplementation("junit:junit:4.13.2")
    // android.jar ships an org.json stub that throws in JVM tests.
    testImplementation("org.json:json:20231013")
    // Real Postgres convergence tests (Phase 2 Lane B Step 3). The driver is only
    // used by tests that open a JDBC connection to a local Postgres; when no DB
    // is available those tests skip via Assume, so the normal fast unit-test
    // run is unaffected.
    testImplementation("org.postgresql:postgresql:42.7.3")
    // JVM migration tests: apply MIGRATION_44_45 to a v44 database built from
    // the exported Room schema (44.json), exactly the shape that validates on
    // the car. sqlite-jdbc is already in the AndroidX/Robolectric dependency
    // graph, so no new network artifact is introduced.
    testImplementation("org.xerial:sqlite-jdbc:3.41.2.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.room:room-testing:$roomVersion")
}

ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
    arg("room.incremental", "true")
}
