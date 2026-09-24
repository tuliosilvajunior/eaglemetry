package com.timhss.capyenergy.roadcast

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.File

/**
 * Installs and supervises the preferred Roadcast daemon through the vehicle's
 * root adbd. A verified downloaded release takes precedence over the APK asset.
 */
class RoadcastDaemon(context: Context) {
    private val appContext = context.applicationContext
    private val localAdb = LocalAdbShell()
    private val binaryStore = RoadcastBinaryStore(appContext)
    private var installationVerified = false
    private var runtimeVerified = false

    data class Status(
        val running: Boolean,
        val socketReachable: Boolean,
        val startedByApp: Boolean = false,
        val error: String? = null
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "running" to running,
            "socketReachable" to socketReachable,
            "startedByApp" to startedByApp,
            "error" to error
        )
    }

    fun ensureRunning(): Status = synchronized(processLock) {
        runCatching { installIfChanged() }.getOrElse { error ->
            return Status(
                running = false,
                socketReachable = probeSocket(),
                error = "Failed to install Roadcast through local ADB: ${error.message}"
            )
        }

        if (probeSocket() && (runtimeVerified || verifyRuntimeContext())) {
            runtimeVerified = true
            return Status(running = true, socketReachable = true)
        }

        runtimeVerified = false
        val launchOutput = runCatching {
            localAdb.execute(launchCommand())
        }.getOrElse { error ->
            return Status(
                running = false,
                socketReachable = false,
                error = "Failed to launch Roadcast through local ADB: ${error.message}"
            )
        }

        if (!launchOutput.contains(LAUNCH_OK_MARKER)) {
            if (launchOutput.contains(MISSING_BINARY_MARKER)) {
                installationVerified = false
                return runCatching {
                    installIfChanged()
                    launchInstalledDaemon()
                }.getOrElse { error ->
                    Status(
                        running = false,
                        socketReachable = false,
                        error = "Failed to recover the Roadcast installation: ${error.message}"
                    )
                }
            }
            return Status(
                running = false,
                socketReachable = false,
                error = launchOutput.ifBlank { "Local ADB returned no launch result" }
            )
        }

        var delayMillis = INITIAL_PROBE_DELAY_MILLIS
        repeat(START_PROBE_ATTEMPTS) {
            if (probeSocket()) {
                runtimeVerified = true
                return Status(
                    running = true,
                    socketReachable = true,
                    startedByApp = true
                )
            }
            Thread.sleep(delayMillis)
            delayMillis = (delayMillis * 2).coerceAtMost(MAX_PROBE_DELAY_MILLIS)
        }

        return Status(
            running = false,
            socketReachable = false,
            startedByApp = true,
            error = "Roadcast was launched but @roadcast did not become reachable"
        )
    }

    fun status(): Status = synchronized(processLock) {
        val reachable = probeSocket()
        val contextValid = reachable && (runtimeVerified || verifyRuntimeContext())
        runtimeVerified = contextValid
        Status(
            running = contextValid,
            socketReachable = reachable,
            error = when {
                !reachable -> "Roadcast socket is not reachable"
                !contextValid -> "Roadcast is not running in $EXPECTED_RUNTIME_CONTEXT"
                else -> null
            }
        )
    }

    fun restart(): Status = synchronized(processLock) {
        runtimeVerified = false
        runCatching {
            localAdb.execute(stopCommand())
        }.getOrElse { error ->
            return Status(
                running = false,
                socketReachable = probeSocket(),
                error = "Failed to stop Roadcast through local ADB: ${error.message}"
            )
        }
        ensureRunning()
    }

    fun installAndRestart(candidate: File, expectedSha256: String): Status =
        synchronized(processLock) {
            require(candidate.isFile) { "Roadcast update candidate is missing" }
            require(RoadcastReleaseManifest.sha256(candidate) == expectedSha256) {
                "Roadcast update candidate checksum changed before installation"
            }
            runtimeVerified = false
            installationVerified = false
            val output = runCatching {
                localAdb.execute(installCommand(candidate.absolutePath, expectedSha256))
            }.getOrElse { error ->
                return Status(
                    running = false,
                    socketReachable = probeSocket(),
                    error = "Failed to install Roadcast update through local ADB: ${error.message}"
                )
            }
            val installedDigest = parseSha256(output)
            if (installedDigest != expectedSha256) {
                return Status(
                    running = false,
                    socketReachable = probeSocket(),
                    error = output.ifBlank { "Installed Roadcast update checksum does not match" }
                )
            }
            installationVerified = true
            launchInstalledDaemon()
        }

    fun reinstallPreferred(): Status = synchronized(processLock) {
        installationVerified = false
        restart()
    }

    fun installedSha256(): String? = synchronized(processLock) {
        parseSha256(localAdb.execute("sha256sum $REMOTE_PATH 2>/dev/null"))
    }

    private fun launchInstalledDaemon(): Status {
        val output = localAdb.execute(launchCommand())
        check(output.contains(LAUNCH_OK_MARKER)) {
            output.ifBlank { "Local ADB returned no launch result" }
        }
        var delayMillis = INITIAL_PROBE_DELAY_MILLIS
        repeat(START_PROBE_ATTEMPTS) {
            if (probeSocket()) {
                runtimeVerified = true
                return Status(
                    running = true,
                    socketReachable = true,
                    startedByApp = true
                )
            }
            Thread.sleep(delayMillis)
            delayMillis = (delayMillis * 2).coerceAtMost(MAX_PROBE_DELAY_MILLIS)
        }
        return Status(
            running = false,
            socketReachable = false,
            startedByApp = true,
            error = "Roadcast was launched but @roadcast did not become reachable"
        )
    }

    private fun installIfChanged() {
        if (installationVerified) return

        val activeRelease = binaryStore.activeRelease()
        if (activeRelease == null) {
            try {
                appContext.assets.open(ASSET_NAME).close()
            } catch (_: Exception) {
                error(
                    "Roadcast daemon binary is not bundled in this build. " +
                        "This repository does not distribute the Roadcast binaries on purpose — " +
                        "see the Roadcast section of the README for how to build them from " +
                        "https://github.com/Timoteohss/roadcast and where to place them."
                )
            }
        }
        val preferredDigest: String = activeRelease?.manifest?.daemon?.sha256
            ?: appContext.assets.open(ASSET_NAME).use(RoadcastReleaseManifest::sha256)
        val remoteDigest = parseSha256(
            localAdb.execute("sha256sum $REMOTE_PATH 2>/dev/null")
        )
        if (preferredDigest == remoteDigest) {
            installationVerified = true
            return
        }

        val stagingFile = File(appContext.cacheDir, "$ASSET_NAME.install")
        try {
            if (activeRelease != null) {
                activeRelease.daemonFile.inputStream().use { input ->
                    stagingFile.outputStream().use { output -> input.copyTo(output) }
                }
            } else {
                appContext.assets.open(ASSET_NAME).use { input ->
                    stagingFile.outputStream().use { output -> input.copyTo(output) }
                }
            }
            val output = localAdb.execute(
                installCommand(stagingFile.absolutePath, preferredDigest)
            )
            val installedDigest = parseSha256(output)
            check(installedDigest == preferredDigest) {
                output.ifBlank { "Installed Roadcast checksum does not match the preferred release" }
            }
            installationVerified = true
        } finally {
            stagingFile.delete()
        }
    }

    private fun probeSocket(): Boolean {
        val socket = LocalSocket()
        return try {
            socket.connect(
                LocalSocketAddress(
                    SOCKET_NAME.removePrefix("@"),
                    LocalSocketAddress.Namespace.ABSTRACT
                )
            )
            true
        } catch (_: Exception) {
            false
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun verifyRuntimeContext(): Boolean =
        runCatching {
            localAdb.execute(runtimeContextCommand())
                .lineSequence()
                .any { it.trim() == EXPECTED_RUNTIME_CONTEXT }
        }.getOrDefault(false)

    companion object {
        const val ASSET_NAME = "roadcastd"
        const val REMOTE_PATH = "/data/local/tmp/roadcastd"
        const val SOCKET_NAME = "@roadcast"
        const val DEFAULT_HZ = 60

        private val processLock = Any()
        private const val LAUNCH_OK_MARKER = "ROADCAST_LAUNCHED"
        private const val MISSING_BINARY_MARKER = "ROADCAST_ERROR:missing"
        private const val EXPECTED_RUNTIME_CONTEXT = "u:r:su:s0"
        private const val INITIAL_PROBE_DELAY_MILLIS = 50L
        private const val MAX_PROBE_DELAY_MILLIS = 400L
        private const val START_PROBE_ATTEMPTS = 8
        private val SHA256_PATTERN = Regex("^[0-9a-fA-F]{64}$")

        internal fun launchCommand(): String =
            "if [ ! -x $REMOTE_PATH ]; then " +
                "echo ROADCAST_ERROR:missing:$REMOTE_PATH; " +
                "else " +
                "pids=\$(pidof roadcastd 2>/dev/null); " +
                "[ -z \"\$pids\" ] || kill \$pids; " +
                "sleep 1; " +
                "nohup $REMOTE_PATH --hz $DEFAULT_HZ --socket $SOCKET_NAME " +
                "</dev/null >/dev/null 2>&1 & " +
                "echo $LAUNCH_OK_MARKER; " +
                "fi"

        internal fun runtimeContextCommand(): String =
            "for pid in \$(pidof roadcastd 2>/dev/null); do " +
                "cat /proc/\"\$pid\"/attr/current 2>/dev/null; " +
                "echo; " +
                "done"

        internal fun stopCommand(): String =
            "pids=\$(pidof roadcastd 2>/dev/null); " +
                "if [ -n \"\$pids\" ]; then kill \$pids; fi; " +
                "sleep 1; echo ROADCAST_STOPPED"

        internal fun installCommand(stagingPath: String, expectedSha256: String): String {
            require(SHA256_PATTERN.matches(expectedSha256)) {
                "Invalid expected Roadcast checksum"
            }
            val temporaryPath = "$REMOTE_PATH.new"
            return "for pid in \$(pidof roadcastd 2>/dev/null); do kill \"\$pid\"; done; " +
                "sleep 1; " +
                "rm -f $temporaryPath; " +
                "if cp '${shellSingleQuote(stagingPath)}' $temporaryPath; then " +
                "chown root:root $temporaryPath; " +
                "chmod 0755 $temporaryPath; " +
                "digest=\$(sha256sum $temporaryPath 2>/dev/null | cut -d' ' -f1); " +
                "if [ \"\$digest\" = \"$expectedSha256\" ]; then " +
                "mv -f $temporaryPath $REMOTE_PATH; " +
                "echo \"\$digest  $REMOTE_PATH\"; " +
                "else rm -f $temporaryPath; echo ROADCAST_ERROR:checksum; fi; " +
                "else echo ROADCAST_ERROR:install; fi"
        }

        internal fun parseSha256(output: String): String? =
            output.lineSequence()
                .flatMap { it.trim().split(Regex("\\s+")).asSequence() }
                .firstOrNull { SHA256_PATTERN.matches(it) }
                ?.lowercase()

        private fun shellSingleQuote(value: String): String =
            value.replace("'", "'\"'\"'")

    }
}
