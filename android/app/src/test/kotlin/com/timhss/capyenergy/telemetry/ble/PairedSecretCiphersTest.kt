package com.timhss.capyenergy.telemetry.ble

import com.timhss.capyenergy.telemetry.sync.CompanionDevice
import com.timhss.capyenergy.telemetry.sync.CompanionDeviceManager
import com.timhss.capyenergy.telemetry.sync.InMemoryCompanionDeviceStore
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class PairedSecretCiphersTest {

    private fun sampleSecret(seed: String): String {
        val bytes = ByteArray(32)
        val seedBytes = seed.toByteArray()
        for (i in bytes.indices) {
            bytes[i] = seedBytes[i % seedBytes.size]
        }
        return Base64.getEncoder().encodeToString(bytes)
    }

    @Test
    fun returnsEmptyListWhenNoDevicesArePaired() {
        val pairedCiphers = PairedSecretCiphers { emptyList() }
        val frames = pairedCiphers.framesForPairedSecrets(byteArrayOf(1, 2, 3))
        assertTrue(frames.isEmpty())
    }

    @Test
    fun encryptsPayloadForSinglePairedDevice() {
        val secret = sampleSecret("primary-key")
        val device = CompanionDevice(
            deviceId = "dev-1",
            deviceName = "Phone 1",
            pairedAtUtcMillis = 1000L,
            sharedSecret = secret
        )
        val pairedCiphers = PairedSecretCiphers { listOf(device) }
        val plaintext = byteArrayOf(0xCA.toByte(), 0xFE.toByte(), 1, 2, 3)

        val frames = pairedCiphers.framesForPairedSecrets(plaintext)

        assertEquals(1, frames.size)
        val decryptor = LiveTelemetryStreamCipher(secret)
        assertArrayEquals(plaintext, decryptor.decrypt(frames[0]))
    }

    @Test
    fun fansOutPayloadToMultiplePairedDevices() {
        val secret1 = sampleSecret("secret-for-phone-1")
        val secret2 = sampleSecret("secret-for-phone-2")
        val dev1 = CompanionDevice("dev-1", "Phone 1", 1000L, secret1)
        val dev2 = CompanionDevice("dev-2", "Phone 2", 2000L, secret2)
        val pairedCiphers = PairedSecretCiphers { listOf(dev1, dev2) }
        val plaintext = byteArrayOf(42, 43, 44)

        val frames = pairedCiphers.framesForPairedSecrets(plaintext)

        assertEquals(2, frames.size)
        val cipher1 = LiveTelemetryStreamCipher(secret1)
        val cipher2 = LiveTelemetryStreamCipher(secret2)

        // One frame decrypts under secret1, one under secret2
        val decrypted1 = frames.mapNotNull { cipher1.decrypt(it) }
        val decrypted2 = frames.mapNotNull { cipher2.decrypt(it) }

        assertEquals(1, decrypted1.size)
        assertArrayEquals(plaintext, decrypted1[0])

        assertEquals(1, decrypted2.size)
        assertArrayEquals(plaintext, decrypted2[0])
    }

    @Test
    fun worksWithCompanionDeviceManagerDirectly() {
        val store = InMemoryCompanionDeviceStore()
        val manager = CompanionDeviceManager(store)
        val secret = sampleSecret("manager-secret")
        val dev = CompanionDevice("dev-mgr", "Phone Mgr", 1000L, secret)
        manager.registerDevice(dev)

        val pairedCiphers = PairedSecretCiphers(manager)
        val plaintext = byteArrayOf(7, 8, 9)
        val frames = pairedCiphers.framesForPairedSecrets(plaintext)

        assertEquals(1, frames.size)
        val decryptor = LiveTelemetryStreamCipher(secret)
        assertArrayEquals(plaintext, decryptor.decrypt(frames[0]))
    }

    @Test
    fun reusesCiphersAcrossFramesWhenDeviceListIsUnchanged() {
        val secret = sampleSecret("monotonic-key")
        val dev = CompanionDevice("dev-1", "Phone 1", 1000L, secret)
        val pairedCiphers = PairedSecretCiphers { listOf(dev) }

        val frame1 = pairedCiphers.framesForPairedSecrets(byteArrayOf(1))[0]
        val frame2 = pairedCiphers.framesForPairedSecrets(byteArrayOf(2))[0]

        val counter1 = extractCounter(frame1)
        val counter2 = extractCounter(frame2)

        assertEquals(counter1 + 1, counter2)
    }

    @Test
    fun reusesCiphersWhenDeviceOrderInListChanges() {
        val secret1 = sampleSecret("order-key-1")
        val secret2 = sampleSecret("order-key-2")
        val dev1 = CompanionDevice("dev-1", "Phone 1", 1000L, secret1)
        val dev2 = CompanionDevice("dev-2", "Phone 2", 2000L, secret2)

        var list = listOf(dev1, dev2)
        val pairedCiphers = PairedSecretCiphers { list }

        val frames1 = pairedCiphers.framesForPairedSecrets(byteArrayOf(1))
        val cipher1 = LiveTelemetryStreamCipher(secret1)
        val f1dev1 = frames1.first { cipher1.decrypt(it) != null }
        val c1 = extractCounter(f1dev1)

        // Swap order
        list = listOf(dev2, dev1)
        val frames2 = pairedCiphers.framesForPairedSecrets(byteArrayOf(2))
        val f2dev1 = frames2.first { cipher1.decrypt(it) != null }
        val c2 = extractCounter(f2dev1)

        assertEquals(c1 + 1, c2)
    }

    @Test
    fun evictsStaleKeyWhenDeviceIsUnpaired() {
        val secret1 = sampleSecret("staying-key")
        val secret2 = sampleSecret("unpaired-key")
        val dev1 = CompanionDevice("dev-1", "Phone 1", 1000L, secret1)
        val dev2 = CompanionDevice("dev-2", "Phone 2", 2000L, secret2)

        var currentDevices = listOf(dev1, dev2)
        val pairedCiphers = PairedSecretCiphers { currentDevices }

        val initialFrames = pairedCiphers.framesForPairedSecrets(byteArrayOf(10, 11))
        assertEquals(2, initialFrames.size)

        // Unpair dev2
        currentDevices = listOf(dev1)
        val subsequentFrames = pairedCiphers.framesForPairedSecrets(byteArrayOf(20, 21))

        assertEquals(1, subsequentFrames.size)
        val cipher2 = LiveTelemetryStreamCipher(secret2)
        // Stale secret2 must not be able to decrypt any frame from subsequentFrames
        for (frame in subsequentFrames) {
            org.junit.Assert.assertNull(cipher2.decrypt(frame))
        }
        val cipher1 = LiveTelemetryStreamCipher(secret1)
        assertArrayEquals(byteArrayOf(20, 21), cipher1.decrypt(subsequentFrames[0]))
    }

    @Test
    fun replacesCipherWhenDeviceSecretChanges() {
        val oldSecret = sampleSecret("old-secret-version-1")
        val newSecret = sampleSecret("new-secret-version-2")
        var currentDevices = listOf(CompanionDevice("dev-1", "Phone 1", 1000L, oldSecret))

        val pairedCiphers = PairedSecretCiphers { currentDevices }
        val frameOld = pairedCiphers.framesForPairedSecrets(byteArrayOf(1, 2))[0]
        assertArrayEquals(byteArrayOf(1, 2), LiveTelemetryStreamCipher(oldSecret).decrypt(frameOld))

        // Change secret
        currentDevices = listOf(CompanionDevice("dev-1", "Phone 1", 1000L, newSecret))
        val frameNew = pairedCiphers.framesForPairedSecrets(byteArrayOf(3, 4))[0]

        assertArrayEquals(byteArrayOf(3, 4), LiveTelemetryStreamCipher(newSecret).decrypt(frameNew))
        org.junit.Assert.assertNull(LiveTelemetryStreamCipher(oldSecret).decrypt(frameNew))
    }

    @Test
    fun skipsMalformedOrInvalidSecretWithoutFailingValidDevices() {
        val validSecret = sampleSecret("valid-secret")
        val invalidSecret = Base64.getEncoder().encodeToString(ByteArray(16)) // 16 bytes is invalid for AES-256

        val devInvalid = CompanionDevice("dev-bad", "Bad Phone", 1000L, invalidSecret)
        val devValid = CompanionDevice("dev-good", "Good Phone", 2000L, validSecret)

        val pairedCiphers = PairedSecretCiphers { listOf(devInvalid, devValid) }
        val plaintext = byteArrayOf(99)
        val frames = pairedCiphers.framesForPairedSecrets(plaintext)

        assertEquals(1, frames.size)
        val cipher = LiveTelemetryStreamCipher(validSecret)
        assertArrayEquals(plaintext, cipher.decrypt(frames[0]))
    }

    private fun extractCounter(frame: ByteArray): Long {
        var counter = 0L
        for (b in 1..8) {
            counter = (counter shl 8) or (frame[b].toLong() and 0xFF)
        }
        return counter
    }
}
