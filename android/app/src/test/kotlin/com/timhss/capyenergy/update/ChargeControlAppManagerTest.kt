package com.timhss.capyenergy.update

import java.io.File
import java.net.URL
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * What the installer of the charge-control app promises.
 *
 * The APK is verified against the manifest before it reaches the package
 * manager, and no copy of it survives the attempt.
 */
class ChargeControlAppManagerTest {

    @get:Rule
    val cacheFolder = TemporaryFolder()

    @get:Rule
    val stagingFolder = TemporaryFolder()

    @Test
    fun `states the installed version without asking the network`() {
        var reads = 0
        val manager = manager(
            installed = InstalledApp(versionName = "0.1.0", versionCode = 9L),
            downloader = object : FakeDownloader(apkBytes = ByteArray(0)) {
                override fun read(url: URL, maxBytes: Long): ByteArray {
                    reads += 1
                    return super.read(url, maxBytes)
                }
            }
        )

        val status = manager.status()

        assertTrue(status.installed)
        assertEquals("0.1.0", status.installedVersionName)
        assertEquals(9L, status.installedVersionCode)
        assertEquals(0, reads)
    }

    @Test
    fun `an update is offered only when the published code is newer`() {
        val apk = "an apk".toByteArray()

        val fresh = manager(installed = InstalledApp("0.1.0", 9L), downloader = FakeDownloader(apk))
            .checkStatus()
        assertFalse(fresh.updateAvailable)
        assertEquals(9L, fresh.availableVersionCode)

        val stale = manager(installed = InstalledApp("0.0.9", 8L), downloader = FakeDownloader(apk))
            .checkStatus()
        assertTrue(stale.updateAvailable)
        assertNull(stale.error)

        val absent = manager(installed = null, downloader = FakeDownloader(apk)).checkStatus()
        assertFalse(absent.installed)
        assertTrue(absent.updateAvailable)
    }

    @Test
    fun `a manifest that cannot be read is reported, not thrown`() {
        val manager = manager(
            installed = InstalledApp("0.1.0", 9L),
            downloader = object : FakeDownloader(ByteArray(0)) {
                override fun read(url: URL, maxBytes: Long): ByteArray =
                    throw java.io.IOException("host unreachable")
            }
        )

        val status = manager.checkStatus()

        assertEquals("host unreachable", status.error)
        assertTrue(status.installed)
    }

    @Test
    fun `a verified apk is installed and no copy of it is left behind`() {
        val apk = "the real apk bytes".toByteArray()
        val installed = mutableListOf<File>()
        val manager = manager(
            installed = null,
            downloader = FakeDownloader(apk),
            installer = { file ->
                installed += file
                assertTrue("the file must exist when it is installed", file.isFile)
                "Success"
            }
        )

        val status = manager.downloadAndInstall()

        assertTrue(status.installScheduled)
        assertTrue(status.installed)
        assertEquals("0.1.0", status.installedVersionName)
        assertNull(status.error)
        assertEquals(1, installed.size)
        assertFalse(File(cacheFolder.root, "geelychargecontrol.apk").exists())
    }

    @Test
    fun `an apk whose checksum does not match the manifest is never installed`() {
        var installs = 0
        val manager = manager(
            installed = null,
            // The manifest states the checksum of the real bytes; the download
            // answers with different ones of the same length, so the size
            // check passes and only the checksum can catch the substitution.
            downloader = FakeDownloader(apkBytes = "the real apk bytes".toByteArray()) {
                "a substituted apk!".toByteArray()
            },
            installer = { installs += 1; "Success" }
        )

        val status = manager.downloadAndInstall()

        assertEquals(0, installs)
        assertFalse(status.installScheduled)
        assertNotNull(status.error)
        assertTrue(status.error!!.contains("checksum"))
        assertFalse(File(cacheFolder.root, "geelychargecontrol.apk").exists())
    }

    @Test
    fun `a truncated download is never installed`() {
        var installs = 0
        val manager = manager(
            installed = null,
            downloader = FakeDownloader(apkBytes = "the real apk bytes".toByteArray()) {
                "short".toByteArray()
            },
            installer = { installs += 1; "Success" }
        )

        val status = manager.downloadAndInstall()

        assertEquals(0, installs)
        assertTrue(status.error!!.contains("size"))
    }

    @Test
    fun `a refused install keeps the version that is already there`() {
        val manager = manager(
            installed = InstalledApp("0.0.9", 8L),
            downloader = FakeDownloader("the real apk bytes".toByteArray()),
            installer = { "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]" }
        )

        val status = manager.downloadAndInstall()

        assertFalse(status.installScheduled)
        assertTrue(status.installed)
        assertEquals("0.0.9", status.installedVersionName)
        assertEquals("Install failed", status.error)
        assertFalse(File(cacheFolder.root, "geelychargecontrol.apk").exists())
        assertFalse(File(stagingFolder.root, "geelychargecontrol.apk").exists())
    }

    @Test
    fun `download progress is reported to the caller`() {
        val apk = "the real apk bytes".toByteArray()
        val progressValues = mutableListOf<Float>()
        val manager = manager(
            installed = null,
            downloader = FakeDownloader(apk),
            installer = { "Success" }
        )

        manager.downloadAndInstall(onProgress = { progressValues += it })

        assertTrue(progressValues.isNotEmpty())
        assertEquals(1f, progressValues.last(), 0.001f)
    }

    private fun manager(
        installed: InstalledApp?,
        downloader: FakeDownloader,
        installer: (File) -> String? = { "Success" }
    ) = ChargeControlAppManager(
        probe = { installed },
        cacheDir = cacheFolder.root,
        launcher = { true },
        stagingDir = stagingFolder.root,
        downloader = downloader,
        installer = installer,
        manifestUrl = "https://raw.githubusercontent.com/example/capy_releases/main/geelychargecontrol-latest.json"
    )

    /**
     * A manifest that describes [apkBytes], and a download that answers with
     * whatever [answer] returns — the same bytes unless a test substitutes
     * them.
     */
    private open class FakeDownloader(
        private val apkBytes: ByteArray,
        private val answer: () -> ByteArray = { apkBytes }
    ) : AppUpdateDownloader {

        override fun read(url: URL, maxBytes: Long): ByteArray =
            manifestJson(apkBytes).toByteArray()

        override fun download(
            url: URL,
            destination: File,
            expectedBytes: Long,
            onProgress: ((bytesRead: Long, totalBytes: Long) -> Unit)?
        ) {
            destination.parentFile?.mkdirs()
            val bytes = answer()
            destination.writeBytes(bytes)
            onProgress?.invoke(bytes.size.toLong(), expectedBytes)
        }
    }

    private companion object {
        fun manifestJson(apk: ByteArray): String = """
            {
              "schemaVersion": 1,
              "versionName": "0.1.0",
              "versionCode": 9,
              "apkUrl": "https://github.com/example/capy_releases/releases/download/v0.1.0-chargecontrol/geelychargecontrol-v0.1.0.apk",
              "packageName": "com.timhss.geelychargecontrol",
              "sha256": "${sha256(apk)}",
              "sizeBytes": ${apk.size},
              "requiresReflash": false
            }
        """.trimIndent()

        fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
    }

    // --- The install-time dexopt --------------------------------------------
    //
    // The head unit compiles only the first dex file at install. The control
    // app then dies at startup on a class in the second one, so the install is
    // not finished until the compile has been forced.

    @Test
    fun `a successful install forces the app to be recompiled`() {
        val commands = mutableListOf<String>()
        val apk = File.createTempFile("charge-control", ".apk")
        apk.deleteOnExit()

        ChargeControlAppManager.installViaAdb(apk) { command ->
            commands += command
            "Success"
        }

        assertTrue(
            "the install must be followed by a forced compile",
            commands.contains(ChargeControlAppManager.RECOMPILE_COMMAND)
        )
        assertTrue(
            "the compile comes after the install, never before",
            commands.indexOf(ChargeControlAppManager.RECOMPILE_COMMAND) >
                commands.indexOfFirst { it.startsWith("pm install") }
        )
    }

    @Test
    fun `a failed install does not recompile`() {
        val commands = mutableListOf<String>()
        val apk = File.createTempFile("charge-control", ".apk")
        apk.deleteOnExit()

        ChargeControlAppManager.installViaAdb(apk) { command ->
            commands += command
            "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]"
        }

        assertFalse(
            "nothing was installed, so there is nothing to compile",
            commands.contains(ChargeControlAppManager.RECOMPILE_COMMAND)
        )
    }
}
