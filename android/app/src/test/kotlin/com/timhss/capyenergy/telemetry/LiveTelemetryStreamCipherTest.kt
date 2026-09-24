package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.ble.LiveTelemetryStreamCipher
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class LiveTelemetryStreamCipherTest {

    private val secretBase64: String =
        Base64.getEncoder().encodeToString("test-secret-key-for-ble-auth-32b".toByteArray())

    @Test
    fun roundtripRecoversPlaintext() {
        val cipher = LiveTelemetryStreamCipher(secretBase64)
        val plaintext = byteArrayOf(0xCB.toByte(), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)

        val frame = cipher.encrypt(plaintext)

        assertArrayEquals(plaintext, cipher.decrypt(frame))
    }

    @Test
    fun frameLayoutMatchesSpec() {
        val cipher = LiveTelemetryStreamCipher(secretBase64, counterSeed = 1)
        val plaintext = ByteArray(12)

        val frame = cipher.encrypt(plaintext)

        assertEquals(LiveTelemetryStreamCipher.FRAME_VERSION, frame[0])
        assertEquals(
            LiveTelemetryStreamCipher.HEADER_BYTES + plaintext.size + 16,
            frame.size
        )
    }

    @Test
    fun nonceIsFourZeroBytesFollowedByCounter() {
        val counterValue = 0x0102030405060708L

        val nonce = LiveTelemetryStreamCipher.nonceFor(counterValue)

        assertEquals(12, nonce.size)
        for (i in 0..3) assertEquals(0.toByte(), nonce[i])
        assertEquals(0x01.toByte(), nonce[4])
        assertEquals(0x08.toByte(), nonce[11])
    }

    @Test
    fun tamperedFrameIsRejected() {
        val cipher = LiveTelemetryStreamCipher(secretBase64)
        val frame = cipher.encrypt(ByteArray(16))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0x01).toByte()

        assertNull(cipher.decrypt(frame))
    }

    @Test
    fun wrongKeyIsRejected() {
        val otherSecret = Base64.getEncoder().encodeToString("wrong-secret-key-for-ble-auth32b".toByteArray())
        val cipher = LiveTelemetryStreamCipher(secretBase64)
        val otherCipher = LiveTelemetryStreamCipher(otherSecret)

        assertNull(otherCipher.decrypt(cipher.encrypt(ByteArray(16))))
    }

    @Test
    fun truncatedAndUnknownVersionFramesAreRejected() {
        val cipher = LiveTelemetryStreamCipher(secretBase64)

        assertNull(cipher.decrypt(ByteArray(4)))
        assertNull(cipher.decrypt(ByteArray(0)))

        val frame = cipher.encrypt(ByteArray(16))
        frame[0] = 1
        assertNull(cipher.decrypt(frame))
    }

    @Test
    fun countersIncreaseStrictlyPerFrame() {
        val cipher = LiveTelemetryStreamCipher(secretBase64)
        var last = -1L

        repeat(5) {
            val counter = counterOf(cipher.encrypt(ByteArray(8)))
            assertTrue(counter > last)
            last = counter
        }
    }

    @Test
    fun counterStartsAboveTheSeedSoARestartNeverReusesANonce() {
        // A restart under the same key must not go back over counters the key
        // already used: GCM breaks if one nonce repeats.
        val beforeRestart = LiveTelemetryStreamCipher(secretBase64, counterSeed = 1_000)
        repeat(20) { beforeRestart.encrypt(ByteArray(4)) }
        val lastBefore = counterOf(beforeRestart.encrypt(ByteArray(4)))

        val afterRestart = LiveTelemetryStreamCipher(secretBase64, counterSeed = 5_000)

        assertTrue(counterOf(afterRestart.encrypt(ByteArray(4))) > lastBefore)
    }

    @Test
    fun defaultSeedIsTheWallClock() {
        val before = System.currentTimeMillis()

        val counter = counterOf(LiveTelemetryStreamCipher(secretBase64).encrypt(ByteArray(4)))

        assertTrue(counter > before)
        assertTrue(counter <= System.currentTimeMillis() + 1)
    }

    @Test
    fun rejectsShortSecrets() {
        val shortSecret = Base64.getEncoder().encodeToString(ByteArray(16))

        var thrown: Throwable? = null
        try {
            LiveTelemetryStreamCipher(shortSecret)
        } catch (e: Throwable) {
            thrown = e
        }
        assertNotNull(thrown)
    }

    @Test
    fun producesKnownCrossLanguageVector() {
        // Frozen vector: the companion Dart codec asserts the same bytes, so a
        // change on either side that breaks the wire format fails a test here.
        val cipher = LiveTelemetryStreamCipher(secretBase64)
        val plaintext = ByteArray(12) { it.toByte() }

        val frame = cipher.encryptWithCounter(plaintext, 0x0102030405060708L)

        assertEquals("0201020304050607087300fa09bf4dde9f801e75c8fc47c23bb619bebd700d52f9228ca427", frame.joinToString("") { "%02x".format(it) })
    }

    private fun counterOf(frame: ByteArray): Long {
        var counter = 0L
        for (b in 1..8) counter = (counter shl 8) or (frame[b].toLong() and 0xFF)
        return counter
    }
}
