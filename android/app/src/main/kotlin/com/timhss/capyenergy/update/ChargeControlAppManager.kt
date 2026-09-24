package com.timhss.capyenergy.update

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import com.timhss.capyenergy.roadcast.LocalAdbShell
import java.io.File
import java.net.URL
import java.security.MessageDigest

data class ChargeControlAppStatus(
    val installed: Boolean,
    val installedVersionName: String? = null,
    val installedVersionCode: Long? = null,
    val availableVersionName: String? = null,
    val availableVersionCode: Long? = null,
    val updateAvailable: Boolean = false,
    val installScheduled: Boolean = false,
    val error: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "installed" to installed,
        "installedVersionName" to installedVersionName,
        "installedVersionCode" to installedVersionCode,
        "availableVersionName" to availableVersionName,
        "availableVersionCode" to availableVersionCode,
        "updateAvailable" to updateAvailable,
        "installScheduled" to installScheduled,
        "error" to error
    )
}

/** What the head unit already has installed, as far as this app can tell. */
internal data class InstalledApp(
    val versionName: String?,
    val versionCode: Long
)

/**
 * The dedicated charge-control app, as this app can see and install it.
 *
 * Capy Energy writes nothing to the vehicle. It only states whether the
 * control app is here, fetches its signed manifest, verifies the APK against
 * it, and hands the file to the package manager.
 *
 * Nothing here holds a [Context]: the package probe, the cache directory and
 * the launcher are the three seams, so the download, the checksum and the
 * install path are testable without a device.
 */
class ChargeControlAppManager internal constructor(
    private val probe: () -> InstalledApp?,
    private val cacheDir: File,
    private val launcher: () -> Boolean,
    private val stagingDir: File = File(DEFAULT_STAGING_DIR),
    private val downloader: AppUpdateDownloader = HttpAppUpdateDownloader(),
    private val installer: (File) -> String? = { apk ->
        installViaAdb(apk)
    },
    private val manifestUrl: String = com.timhss.capyenergy.BuildConfig.CHARGE_CONTROL_MANIFEST_URL,
) {
    constructor(appContext: Context) : this(
        probe = { installedPackage(appContext) },
        cacheDir = appContext.cacheDir,
        launcher = { launch(appContext) }
    )

    fun status(): ChargeControlAppStatus {
        val installed = probe()
        return ChargeControlAppStatus(
            installed = installed != null,
            installedVersionName = installed?.versionName,
            installedVersionCode = installed?.versionCode
        )
    }

    fun checkStatus(): ChargeControlAppStatus {
        val installed = probe()
        return try {
            val manifest = fetchManifest()
            ChargeControlAppStatus(
                installed = installed != null,
                installedVersionName = installed?.versionName,
                installedVersionCode = installed?.versionCode,
                availableVersionName = manifest.versionName,
                availableVersionCode = manifest.versionCode,
                updateAvailable = manifest.versionCode > (installed?.versionCode ?: 0L)
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to check charge control app manifest", e)
            ChargeControlAppStatus(
                installed = installed != null,
                installedVersionName = installed?.versionName,
                installedVersionCode = installed?.versionCode,
                error = e.message ?: "Failed to check updates"
            )
        }
    }

    /**
     * Downloads the APK the manifest names and installs it.
     *
     * The size and the SHA-256 are checked before the file reaches the package
     * manager, so a truncated or substituted download is never installed. Both
     * copies of the file are deleted, whichever path was taken.
     */
    fun downloadAndInstall(onProgress: ((Float) -> Unit)? = null): ChargeControlAppStatus {
        val installed = probe()
        val candidate = File(cacheDir, CANDIDATE_FILE)
        val staged = File(stagingDir, CANDIDATE_FILE)
        try {
            val manifest = fetchManifest()
            onProgress?.invoke(0f)
            downloader.download(
                URL(manifest.apkUrl),
                candidate,
                manifest.sizeBytes,
                onProgress = { bytesRead, totalBytes ->
                    if (totalBytes > 0) {
                        val pct = (bytesRead.toFloat() / totalBytes.toFloat()).coerceIn(0f, 1f)
                        onProgress?.invoke(pct)
                    }
                }
            )
            require(candidate.isFile && candidate.length() == manifest.sizeBytes) {
                "Downloaded APK size does not match the manifest"
            }
            require(sha256(candidate) == manifest.sha256) {
                "APK checksum does not match the manifest"
            }

            var installOk = install(candidate)
            if (!installOk) {
                // The installer cannot always read the app's own cache directory.
                // A staged copy in the shell's directory is the second try.
                runCatching {
                    candidate.copyTo(staged, overwrite = true)
                    installOk = install(staged)
                }
            }

            val freshlyInstalled = probe()
            val isSuccess = installOk ||
                (installed == null && freshlyInstalled != null) ||
                (installed != null && freshlyInstalled != null && freshlyInstalled.versionCode > installed.versionCode)
            if (isSuccess) {
                onProgress?.invoke(1f)
            }

            return ChargeControlAppStatus(
                installed = isSuccess || installed != null,
                installedVersionName =
                    if (isSuccess) (freshlyInstalled?.versionName ?: manifest.versionName) else installed?.versionName,
                installedVersionCode =
                    if (isSuccess) (freshlyInstalled?.versionCode ?: manifest.versionCode) else installed?.versionCode,
                installScheduled = isSuccess,
                error = if (isSuccess) null else "Install failed"
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to install the charge control app", e)
            val freshlyInstalled = probe()
            val isSuccess = (installed == null && freshlyInstalled != null) ||
                (installed != null && freshlyInstalled != null && freshlyInstalled.versionCode > installed.versionCode)
            return ChargeControlAppStatus(
                installed = isSuccess || installed != null,
                installedVersionName =
                    if (isSuccess) freshlyInstalled.versionName else installed?.versionName,
                installedVersionCode =
                    if (isSuccess) freshlyInstalled.versionCode else installed?.versionCode,
                installScheduled = isSuccess,
                error = if (isSuccess) null else (e.message ?: "Install failed")
            )
        } finally {
            // An APK left behind is a signed installer sitting in a world
            // readable directory. Neither copy outlives the attempt.
            candidate.delete()
            staged.delete()
        }
    }

    fun launchApp(): Boolean = launcher()

    private fun install(apk: File): Boolean {
        val output = runCatching { installer(apk) }.getOrNull()
        return output?.contains("Success", ignoreCase = true) == true
    }

    private fun fetchManifest(): AppUpdateManifest {
        require(manifestUrl.isNotBlank()) {
            "Charge control update channel is not configured (CHARGE_CONTROL_MANIFEST_URL is empty)"
        }
        val json = downloader.read(URL(manifestUrl), MAX_MANIFEST_BYTES)
            .toString(Charsets.UTF_8)
        return AppUpdateManifest.parse(json, expectedPackage = PACKAGE_NAME)
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read > 0) digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    companion object {
        private const val TAG = "ChargeControlAppManager"
        const val PACKAGE_NAME = "com.timhss.geelychargecontrol"

        /**
         * Rebuilds the installed app's compiled code.
         *
         * The dexopt this head unit runs at install time leaves artifacts that
         * cover only the first dex file. The app then starts, fails to find
         * `androidx.startup.InitializationProvider` in the second one, and dies
         * before its first screen. Measured on 2026-08-28 with v0.5.0: the
         * install left a 537 KB base.odex, and this command raised it to 68 MB
         * and the app opened.
         */
        internal const val RECOMPILE_COMMAND = "cmd package compile -f -m speed $PACKAGE_NAME"

        /**
         * The manifest the release script publishes. The file name is fixed
         * by the publisher's release process: configure CHARGE_CONTROL_MANIFEST_URL
         * (local.properties → gradle property → env) with its full HTTPS URL.
         * Empty (the default) disables the channel.
         */
        private const val MAX_MANIFEST_BYTES = 64L * 1024L
        private const val CANDIDATE_FILE = "geelychargecontrol.apk"
        private const val DEFAULT_STAGING_DIR = "/data/local/tmp"

        private fun installedPackage(context: Context): InstalledApp? =
            try {
                val info = context.packageManager.getPackageInfo(PACKAGE_NAME, 0)
                InstalledApp(
                    versionName = info.versionName,
                    versionCode = info.longVersionCode
                )
            } catch (_: Exception) {
                installedPackageViaAdb()
            }

        private fun installedPackageViaAdb(): InstalledApp? =
            try {
                val dumpsys = LocalAdbShell().execute("dumpsys package $PACKAGE_NAME")
                if (dumpsys.contains("Package [$PACKAGE_NAME]") || dumpsys.contains("pkg=Package{$PACKAGE_NAME")) {
                    val versionNameMatch = Regex("""versionName=([^\s]+)""").find(dumpsys)
                    val versionCodeMatch = Regex("""versionCode=(\d+)""").find(dumpsys)
                    InstalledApp(
                        versionName = versionNameMatch?.groupValues?.get(1),
                        versionCode = versionCodeMatch?.groupValues?.get(1)?.toLongOrNull() ?: 0L
                    )
                } else {
                    null
                }
            } catch (_: Exception) {
                null
            }

        /**
         * Runs the install, then rebuilds the installed app's compiled code.
         *
         * [run] is the one seam: every shell command goes through it, so the
         * order and the commands are testable without a head unit.
         */
        internal fun installViaAdb(
            apk: File,
            run: (String) -> String? = LocalAdbShell()::execute
        ): String? {
            val path = apk.absolutePath
            val output = runCatching {
                run("chmod 777 $path")
                run("pm install -r -d -g $path")
            }.getOrNull()?.takeIf { it.contains("Success", ignoreCase = true) }
                ?: runCatching {
                    run("cp $path /data/local/tmp/geelychargecontrol.apk 2>/dev/null || cat $path > /data/local/tmp/geelychargecontrol.apk")
                    run("chmod 777 /data/local/tmp/geelychargecontrol.apk")
                    val out = run("pm install -r -d -g /data/local/tmp/geelychargecontrol.apk")
                    run("rm -f /data/local/tmp/geelychargecontrol.apk")
                    out
                }.getOrNull()
                ?: runCatching {
                    run("cat $path | pm install -r -d -g -S ${apk.length()}")
                }.getOrNull()

            if (output != null && output.contains("Success", ignoreCase = true)) {
                recompile(run)
            }
            return output
        }

        /**
         * Runs [RECOMPILE_COMMAND] after a successful install.
         *
         * A failure here is not fatal to the install, so it is logged and the
         * install still reports what `pm` said.
         */
        private fun recompile(run: (String) -> String?) {
            runCatching {
                run(RECOMPILE_COMMAND)
            }.onSuccess {
                Log.i(TAG, "Recompiled $PACKAGE_NAME after install: $it")
            }.onFailure {
                Log.w(TAG, "Failed to recompile $PACKAGE_NAME after install", it)
            }
        }

        private fun launch(context: Context): Boolean {
            val pm = context.packageManager
            // 1. Try standard launch intent
            val launchIntent = pm.getLaunchIntentForPackage(PACKAGE_NAME)
            if (launchIntent != null) {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(launchIntent)
                    return true
                } catch (e: Exception) {
                    Log.w(TAG, "Standard launch intent failed", e)
                }
            }

            // 2. Try explicit activity from package info
            try {
                val packageInfo = pm.getPackageInfo(PACKAGE_NAME, PackageManager.GET_ACTIVITIES)
                val activities = packageInfo.activities
                if (!activities.isNullOrEmpty()) {
                    val mainActivity = activities.firstOrNull { it.exported } ?: activities.first()
                    val explicitIntent = Intent().apply {
                        component = android.content.ComponentName(PACKAGE_NAME, mainActivity.name)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(explicitIntent)
                    return true
                }
            } catch (e: Exception) {
                Log.w(TAG, "Explicit activity launch failed", e)
            }

            // 3. Fallback to LocalAdbShell
            return launchViaAdb()
        }

        private fun launchViaAdb(): Boolean =
            try {
                val shell = LocalAdbShell()
                val monkeyOutput = runCatching {
                    shell.execute("monkey -p $PACKAGE_NAME -c android.intent.category.LAUNCHER 1")
                }.getOrNull()
                if (monkeyOutput?.contains("Events injected: 1") == true) {
                    true
                } else {
                    val dumpsys = runCatching {
                        shell.execute("dumpsys package $PACKAGE_NAME")
                    }.getOrNull()

                    val activityMatch = dumpsys?.let {
                        Regex("""$PACKAGE_NAME/([a-zA-Z0-9_.]+)""").find(it)?.groupValues?.get(1)
                    }

                    if (activityMatch != null) {
                        val target = if (activityMatch.startsWith(".")) "$PACKAGE_NAME$activityMatch" else activityMatch
                        val out = shell.execute("am start -n $PACKAGE_NAME/$target")
                        !out.contains("Error:", ignoreCase = true) && !out.contains("Exception", ignoreCase = true)
                    } else {
                        val out = shell.execute("am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p $PACKAGE_NAME")
                        !out.contains("Error:", ignoreCase = true) && !out.contains("Exception", ignoreCase = true)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "ADB launch failed", e)
                false
            }
    }
}
