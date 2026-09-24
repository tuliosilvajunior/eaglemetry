package com.timhss.capyenergy.roadcast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RoadcastReleaseManifestTest {
    @Test
    fun `parses the published edge manifest contract`() {
        val manifest = RoadcastReleaseManifest.parse(manifestJson())

        assertEquals(1, manifest.manifestVersion)
        assertEquals("edge", manifest.releaseTag)
        assertEquals("981dbacc437ef16593c5fafa22f92d76371980ad", manifest.commit)
        assertEquals("arm64-v8a", manifest.abi)
        assertEquals(28, manifest.minAndroidApi)
        assertEquals(3, manifest.protocol)
        assertEquals(3, manifest.minClientProtocol)
        assertEquals(3, manifest.maxClientProtocol)
        assertEquals("roadcastd", manifest.daemon.file)
        assertEquals(1_239_264L, manifest.daemon.sizeBytes)
        assertNull(
            manifest.compatibilityError(
                sdkInt = 28,
                supportedAbis = listOf("arm64-v8a"),
                clientProtocol = 3
            )
        )
    }

    @Test
    fun `rejects incompatible API ABI and client protocol`() {
        val manifest = RoadcastReleaseManifest.parse(manifestJson())

        assertTrue(
            manifest.compatibilityError(27, listOf("arm64-v8a"), 3)!!
                .contains("API 28")
        )
        assertTrue(
            manifest.compatibilityError(28, listOf("x86_64"), 3)!!
                .contains("ABI")
        )
        assertTrue(
            manifest.compatibilityError(28, listOf("arm64-v8a"), 4)!!
                .contains("client protocol 4")
        )
    }

    @Test
    fun `rejects malformed daemon identity and checksum`() {
        val wrongFile = manifestJson().replace(
            "\"file\": \"roadcastd\"",
            "\"file\": \"other\""
        )
        val wrongDigest = manifestJson().replace(DAEMON_SHA, "not-a-digest")

        assertThrows(IllegalArgumentException::class.java) {
            RoadcastReleaseManifest.parse(wrongFile)
        }
        assertThrows(IllegalArgumentException::class.java) {
            RoadcastReleaseManifest.parse(wrongDigest)
        }
    }

    private fun manifestJson(): String =
        """
        {
          "manifestVersion": 1,
          "version": "edge",
          "releaseTag": "edge",
          "channel": "edge",
          "commit": "981dbacc437ef16593c5fafa22f92d76371980ad",
          "abi": "arm64-v8a",
          "minAndroidApi": 28,
          "protocol": 3,
          "minClientProtocol": 3,
          "maxClientProtocol": 3,
          "schemaVersion": 1,
          "artifacts": {
            "roadcastd": {
              "file": "roadcastd",
              "sha256": "$DAEMON_SHA",
              "sizeBytes": 1239264
            }
          }
        }
        """.trimIndent()

    private companion object {
        const val DAEMON_SHA =
            "e6d6fb610bf4146f3156716f9d1f5d348a539f1ba70627bdff2087dfef156f18"
    }
}
