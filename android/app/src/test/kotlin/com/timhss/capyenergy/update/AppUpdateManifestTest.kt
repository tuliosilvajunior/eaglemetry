package com.timhss.capyenergy.update

import android.content.pm.PackageInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdateManifestTest {
    @Test
    fun `parses the published latest manifest contract`() {
        val manifest = AppUpdateManifest.parse(manifestJson())

        assertEquals(1, manifest.schemaVersion)
        assertEquals("0.4.6", manifest.versionName)
        assertEquals(59L, manifest.versionCode)
        assertEquals(AppUpdateManifest.PACKAGE_NAME, manifest.packageName)
        assertEquals(21_213_317L, manifest.sizeBytes)
        assertFalse(manifest.requiresReflash)
        assertEquals("0.4.6", manifest.changelog.single().versionName)
        assertEquals("Nota em português", manifest.changelog.single().notes["pt"]?.single())
    }

    @Test
    fun `accepts a schema v1 manifest without a changelog`() {
        val manifest = AppUpdateManifest.parse(
            manifestJson().replace(Regex(",\\s*\\\"changelog\\\": \\[.*]", RegexOption.DOT_MATCHES_ALL), "")
        )

        assertTrue(manifest.changelog.isEmpty())
    }

    @Test
    fun `rejects another package host or release repository`() {
        val wrongPackage = manifestJson().replace(
            AppUpdateManifest.PACKAGE_NAME,
            "com.example.other"
        )
        val wrongHost = manifestJson().replace("github.com", "example.com")
        val wrongRepository = manifestJson().replace(
            "/releases/download/",
            "/releases/unknown/"
        )

        listOf(wrongPackage, wrongHost, wrongRepository).forEach { json ->
            assertThrows(IllegalArgumentException::class.java) {
                AppUpdateManifest.parse(json)
            }
        }
    }

    @Test
    fun `rejects malformed checksum and oversized APK`() {
        val wrongDigest = manifestJson().replace(APK_SHA256, "not-a-digest")
        val oversized = manifestJson().replace(
            "21213317",
            (AppUpdateManifest.MAX_APK_BYTES + 1).toString()
        )

        assertThrows(IllegalArgumentException::class.java) {
            AppUpdateManifest.parse(wrongDigest)
        }
        assertThrows(IllegalArgumentException::class.java) {
            AppUpdateManifest.parse(oversized)
        }
    }

    @Test
    fun `staging command verifies checksum before scheduling install`() {
        val command = AppUpdateManager.stageCommand(
            "/data/user/0/com.timhss.capy/cache/capy-update.apk",
            APK_SHA256
        )

        assertTrue(command.contains("cp '/data/user/0/"))
        assertTrue(command.contains("sha256sum /data/local/tmp/capy-update.apk"))
        assertTrue(command.contains(APK_SHA256))
        assertTrue(command.contains("APP_UPDATE_STAGED"))
    }

    @Test
    fun `install command performs an in-place update and relaunches app`() {
        val command = AppUpdateManager.scheduleInstallCommand()

        assertTrue(command.contains("pm install -r"))
        assertFalse(command.contains("pm uninstall"))
        assertTrue(command.contains("${AppUpdateManifest.PACKAGE_NAME}/.MainActivity"))
        assertTrue(command.contains("APP_UPDATE_SCHEDULED"))
    }

    @Test
    fun `reports which package is missing signing information`() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            AppUpdateManager.signingIdentity(PackageInfo(), "installed app")
        }

        assertTrue(error.message!!.contains("installed app"))
    }

    @Test
    fun `accepts the installed signer in the candidate rotation history`() {
        val installed = signingIdentity(current = setOf("old"))
        val candidate = signingIdentity(
            current = setOf("new"),
            history = setOf("old", "new")
        )

        assertTrue(AppUpdateManager.isCompatibleUpdateSigner(candidate, installed))
        assertFalse(AppUpdateManager.isCompatibleUpdateSigner(installed, candidate))
    }

    @Test
    fun `rejects unrelated and partially matching multiple signers`() {
        val installed = signingIdentity(current = setOf("platform"))
        val unrelated = signingIdentity(current = setOf("attacker"))
        val installedMultiple = signingIdentity(
            current = setOf("platform", "second"),
            multiple = true
        )
        val partialMultiple = signingIdentity(
            current = setOf("platform", "other"),
            multiple = true
        )

        assertFalse(AppUpdateManager.isCompatibleUpdateSigner(unrelated, installed))
        assertFalse(
            AppUpdateManager.isCompatibleUpdateSigner(partialMultiple, installedMultiple)
        )
    }

    private fun signingIdentity(
        current: Set<String>,
        history: Set<String> = current,
        multiple: Boolean = false
    ) = AppSigningIdentity(
        current = current,
        history = history,
        hasMultipleSigners = multiple
    )

    private fun manifestJson(): String =
        """
        {
          "schemaVersion": 1,
          "versionName": "0.4.6",
          "versionCode": 59,
          "packageName": "${AppUpdateManifest.PACKAGE_NAME}",
          "apkUrl": "https://github.com/example/capy_releases/releases/download/v0.4.6/capy-v0.4.6.apk",
          "sha256": "$APK_SHA256",
          "sizeBytes": 21213317,
          "requiresReflash": false,
          "changelog": [
            {
              "versionName": "0.4.6",
              "versionCode": 59,
              "notes": {
                "en": ["English note"],
                "pt": ["Nota em português"],
                "ru": ["Примечание"]
              }
            }
          ]
        }
        """.trimIndent()

    private companion object {
        const val APK_SHA256 =
            "f17c0a367c57f5e53a21e2af2872750f349ea5f8a7691fd55fe7386f328051dd"
    }
}
