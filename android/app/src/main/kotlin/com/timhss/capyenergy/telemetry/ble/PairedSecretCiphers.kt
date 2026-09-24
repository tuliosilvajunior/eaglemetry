package com.timhss.capyenergy.telemetry.ble

import com.timhss.capyenergy.telemetry.sync.CompanionDevice
import com.timhss.capyenergy.telemetry.sync.CompanionDeviceManager

/**
 * Manages [LiveTelemetryStreamCipher] instances for paired companion devices.
 *
 * One frame variant is produced per paired secret so that every connected central
 * receives the broadcast snapshot and keeps only what decrypts under its own key.
 * The cipher cache is rebuilt whenever the paired-device set or their shared secrets
 * change.
 *
 * Pure JVM testable.
 */
class PairedSecretCiphers(
    private val pairedDevicesProvider: () -> List<CompanionDevice>
) {
    constructor(companionDeviceManager: CompanionDeviceManager) : this({ companionDeviceManager.pairedDevices() })

    private var cachedSecrets: Map<String, String>? = null
    private val ciphers = mutableMapOf<String, LiveTelemetryStreamCipher>()

    @Synchronized
    fun framesForPairedSecrets(plaintext: ByteArray): List<ByteArray> {
        val devices = pairedDevicesProvider()
        val currentSecrets = devices.associate { it.deviceId to it.sharedSecret }
        if (currentSecrets != cachedSecrets) {
            ciphers.clear()
            for ((deviceId, secret) in currentSecrets) {
                try {
                    ciphers[deviceId] = LiveTelemetryStreamCipher(secret)
                } catch (_: Exception) {
                }
            }
            cachedSecrets = currentSecrets
        }
        return ciphers.values.map { it.encrypt(plaintext) }
    }
}
