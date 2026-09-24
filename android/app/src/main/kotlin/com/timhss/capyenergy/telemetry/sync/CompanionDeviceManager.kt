package com.timhss.capyenergy.telemetry.sync

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Pluggable storage abstraction for paired devices so unit tests run purely on JVM without Robolectric.
 */
interface CompanionDeviceStore {
    fun getPairedDevicesJson(): String?
    fun savePairedDevicesJson(json: String)
    fun clear()
}

class SharedPreferencesCompanionDeviceStore(context: Context) : CompanionDeviceStore {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun getPairedDevicesJson(): String? = prefs.getString(KEY_PAIRED_DEVICES, null)

    override fun savePairedDevicesJson(json: String) {
        prefs.edit().putString(KEY_PAIRED_DEVICES, json).apply()
    }

    override fun clear() {
        prefs.edit().remove(KEY_PAIRED_DEVICES).apply()
    }

    companion object {
        const val PREFS_NAME = "companion_pairing_prefs"
        const val KEY_PAIRED_DEVICES = "paired_devices_json"
    }
}

class InMemoryCompanionDeviceStore : CompanionDeviceStore {
    private var json: String? = null

    override fun getPairedDevicesJson(): String? = json

    override fun savePairedDevicesJson(json: String) {
        this.json = json
    }

    override fun clear() {
        this.json = null
    }
}

/**
 * A paired companion device authorized to synchronize telemetry.
 *
 * [sharedSecret] is stored as a base64 string on the car and on the companion.
 * It is never transmitted across the wire in plaintext during sync operations.
 */
data class CompanionDevice(
    val deviceId: String,
    val deviceName: String,
    val pairedAtUtcMillis: Long,
    val sharedSecret: String
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "deviceId" to deviceId,
        "deviceName" to deviceName,
        "pairedAtUtcMillis" to pairedAtUtcMillis,
        "sharedSecret" to sharedSecret
    )

    fun toPublicMap(): Map<String, Any?> = mapOf(
        "deviceId" to deviceId,
        "deviceName" to deviceName,
        "pairedAtUtcMillis" to pairedAtUtcMillis
    )

    fun toJson(): JSONObject = JSONObject().apply {
        put("deviceId", deviceId)
        put("deviceName", deviceName)
        put("pairedAtUtcMillis", pairedAtUtcMillis)
        put("sharedSecret", sharedSecret)
    }

    companion object {
        fun fromJson(json: JSONObject): CompanionDevice? {
            val deviceId = json.optString("deviceId", "").takeIf { it.isNotBlank() } ?: return null
            val deviceName = json.optString("deviceName", "").takeIf { it.isNotBlank() } ?: return null
            val pairedAt = json.optLong("pairedAtUtcMillis", -1L).takeIf { it > 0 } ?: return null
            val sharedSecret = json.optString("sharedSecret", "").takeIf { it.isNotBlank() } ?: return null
            return CompanionDevice(
                deviceId = deviceId,
                deviceName = deviceName,
                pairedAtUtcMillis = pairedAt,
                sharedSecret = sharedSecret
            )
        }
    }
}


/**
 * Stores paired companion devices and their shared secrets.
 *
 * Pairing itself moved to the cloud (issue #227): the car registers the
 * approved device and keeps the secret for the BLE live-stream cipher.
 * The local Wi-Fi challenge chain is gone; what stays is registration,
 * lookup, revoke, and the HMAC token helpers the protocol fixtures pin.
 */
class CompanionDeviceManager(
    private val store: CompanionDeviceStore,
) {
    constructor(context: Context) :
            this(SharedPreferencesCompanionDeviceStore(context))


    /**
     * Directly registers a companion device with an explicit secret (used for testing or pre-seeded links).
     */
    @Synchronized
    fun registerDevice(device: CompanionDevice) {
        val devices = loadPairedDevices().toMutableList()
        devices.removeAll { it.deviceId == device.deviceId }
        devices.add(device)
        savePairedDevices(devices)
    }

    /**
     * Returns all currently paired companion devices.
     */
    @Synchronized
    fun pairedDevices(): List<CompanionDevice> = loadPairedDevices()

    /**
     * Finds a paired device by [deviceId], or null if not paired.
     */
    @Synchronized
    fun findDevice(deviceId: String): CompanionDevice? =
        loadPairedDevices().firstOrNull { it.deviceId == deviceId }

    /**
     * Revokes pairing for a device.
     */
    @Synchronized
    fun revokeDevice(deviceId: String): Boolean {
        val devices = loadPairedDevices().toMutableList()
        val removed = devices.removeAll { it.deviceId == deviceId }
        if (removed) {
            savePairedDevices(devices)
        }
        return removed
    }

    /**
     * Removes all paired companion devices.
     */
    @Synchronized
    fun clearAllDevices() {
        store.clear()
    }

    /**
     * Validates an incoming request authentication token against the paired device's secret.
     *
     * Token format: `<timestampMillis>:<signatureHex>`
     * Signature: `HMAC-SHA256(secret, "<METHOD>:<pathWithQuery>:<timestampMillis>:<bodySha256Hex>")`
     *
     * Accepts tokens within [TOKEN_TOLERANCE_MILLIS] (5 minutes) of server time.
     * Returns false on malformed headers, invalid base64 secret, or signature mismatches (no unhandled throw).
     */
    fun validateAuthHeader(
        authHeader: String?,
        method: String,
        pathWithQuery: String,
        deviceId: String,
        bodyBytes: ByteArray? = null,
        nowMillis: Long = System.currentTimeMillis()
    ): Boolean {
        if (authHeader.isNullOrBlank()) return false
        val token = authHeader.removePrefix("Bearer ").trim()
        val parts = token.split(":")
        if (parts.size != 2) return false

        val timestampMillis = parts[0].toLongOrNull() ?: return false
        val signature = parts[1]

        if (Math.abs(nowMillis - timestampMillis) > TOKEN_TOLERANCE_MILLIS) {
            return false
        }

        val device = findDevice(deviceId) ?: return false
        val bodySha256Hex = computeSha256Hex(bodyBytes ?: ByteArray(0))
        val expectedSignature = try {
            computeSignature(
                sharedSecret = device.sharedSecret,
                method = method,
                pathWithQuery = pathWithQuery,
                timestampMillis = timestampMillis,
                bodySha256Hex = bodySha256Hex
            )
        } catch (_: Throwable) {
            return false
        }

        return MessageDigest.isEqual(
            signature.toByteArray(StandardCharsets.UTF_8),
            expectedSignature.toByteArray(StandardCharsets.UTF_8)
        )
    }

    /**
     * Generates a valid auth token string for a client using the shared secret and body bytes.
     */
    fun createAuthHeader(
        sharedSecret: String,
        method: String,
        pathWithQuery: String,
        bodyBytes: ByteArray? = null,
        timestampMillis: Long = System.currentTimeMillis()
    ): String {
        val bodySha256Hex = computeSha256Hex(bodyBytes ?: ByteArray(0))
        val signature = computeSignature(sharedSecret, method, pathWithQuery, timestampMillis, bodySha256Hex)
        return "Bearer $timestampMillis:$signature"
    }

    private fun computeSignature(
        sharedSecret: String,
        method: String,
        pathWithQuery: String,
        timestampMillis: Long,
        bodySha256Hex: String
    ): String {
        val message = "${method.uppercase()}:${pathWithQuery.trim()}:$timestampMillis:$bodySha256Hex"
        val keyBytes = Base64.getDecoder().decode(sharedSecret)
        val keySpec = SecretKeySpec(keyBytes, HMAC_ALGORITHM)
        val mac = Mac.getInstance(HMAC_ALGORITHM)
        mac.init(keySpec)
        val hash = mac.doFinal(message.toByteArray(StandardCharsets.UTF_8))
        return hash.joinToString("") { "%02x".format(it) }
    }

    private fun computeSha256Hex(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        val digest = md.digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun loadPairedDevices(): List<CompanionDevice> {
        val jsonString = store.getPairedDevicesJson() ?: return emptyList()
        return try {
            val array = JSONArray(jsonString)
            val list = mutableListOf<CompanionDevice>()
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                CompanionDevice.fromJson(obj)?.let { list.add(it) }
            }
            list
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private fun savePairedDevices(devices: List<CompanionDevice>) {
        val array = JSONArray()
        devices.forEach { array.put(it.toJson()) }
        store.savePairedDevicesJson(array.toString())
    }

    companion object {
        const val TOKEN_TOLERANCE_MILLIS = 5 * 60 * 1000L // 5 minutes
        private const val HMAC_ALGORITHM = "HmacSHA256"
    }
}
