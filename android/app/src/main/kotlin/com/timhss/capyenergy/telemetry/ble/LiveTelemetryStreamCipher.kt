package com.timhss.capyenergy.telemetry.ble

import java.nio.ByteBuffer
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * One-way encrypted frame codec for the BLE live telemetry stream.
 *
 * The vehicle GATT server app never receives ATT requests from the vendor
 * stack, so no challenge-response is possible. Frames are instead protected
 * in the payload itself: AES-256-GCM under the Wi-Fi pairing shared secret,
 * with a strictly increasing counter that doubles as the GCM nonce suffix so
 * receivers can reject replays and out-of-order frames.
 *
 * The counter starts at the wall clock in milliseconds, not at a random
 * value. GCM breaks catastrophically if one key ever reuses a nonce, and the
 * car rebuilds its ciphers on every app start and on every pairing change.
 * A clock seed keeps the counter above every value the same key already used,
 * at any rate below 1000 frames per second. The stream runs at 1 Hz.
 *
 * Frame layout (notification value on 0xCB02):
 *
 * ```
 * [0]     version = 2
 * [1..8]  counter, uint64 big-endian
 * [9..]   ciphertext || 128-bit GCM tag
 * ```
 *
 * nonce = 4 zero bytes || counter (12 bytes), key = base64-decoded secret.
 */
class LiveTelemetryStreamCipher(
    sharedSecretBase64: String,
    counterSeed: Long = System.currentTimeMillis()
) {
    private val key: SecretKeySpec

    @Volatile
    private var counter: Long

    init {
        val keyBytes = Base64.getDecoder().decode(sharedSecretBase64)
        require(keyBytes.size == 32) { "Shared secret must decode to 32 bytes, was ${keyBytes.size}" }
        key = SecretKeySpec(keyBytes, "AES")
        require(counterSeed > 0) { "Counter seed must be positive, was $counterSeed" }
        counter = counterSeed
    }

    fun encrypt(plaintext: ByteArray): ByteArray {
        val current = synchronized(this) { ++counter }
        return encryptWithCounter(plaintext, current)
    }

    fun encryptWithCounter(plaintext: ByteArray, counterValue: Long): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonceFor(counterValue)))
        val ciphertext = cipher.doFinal(plaintext)
        val frame = ByteBuffer.allocate(HEADER_BYTES + ciphertext.size)
        frame.put(FRAME_VERSION)
        frame.putLong(counterValue)
        frame.put(ciphertext)
        return frame.array()
    }

    fun decrypt(frame: ByteArray): ByteArray? {
        if (frame.size <= HEADER_BYTES) return null
        if (frame[0] != FRAME_VERSION) return null
        val buffer = ByteBuffer.wrap(frame)
        buffer.position(1)
        val counterValue = buffer.long
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonceFor(counterValue)))
            val ciphertext = ByteArray(frame.size - HEADER_BYTES)
            buffer.get(ciphertext)
            cipher.doFinal(ciphertext)
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        const val FRAME_VERSION: Byte = 2
        const val HEADER_BYTES = 9
        const val TAG_BITS = 128
        private const val TRANSFORMATION = "AES/GCM/NoPadding"

        fun nonceFor(counterValue: Long): ByteArray {
            val nonce = ByteBuffer.allocate(12)
            nonce.putInt(0)
            nonce.putLong(counterValue)
            return nonce.array()
        }
    }
}
