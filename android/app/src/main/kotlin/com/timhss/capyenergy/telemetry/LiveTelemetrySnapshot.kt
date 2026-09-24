package com.timhss.capyenergy.telemetry

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * An instantaneous snapshot of vehicle telemetry designed for low-latency live
 * transmission over Bluetooth Low Energy (BLE) and external forwarding (e.g. ABRP).
 */
data class LiveTelemetrySnapshot(
    val utcMillis: Long,
    val socPercent: Double? = null,
    val speedKmh: Double? = null,
    val powerKw: Double? = null,
    val voltageV: Double? = null,
    val currentA: Double? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val altitudeM: Double? = null,
    val headingDeg: Double? = null,
    val isCharging: Boolean = false,
    val isDcfc: Boolean = false,
    val isParked: Boolean = false,
    val ambientTempC: Double? = null,
    val odometerKm: Double? = null
) {
    /**
     * Map representation matching ABRP Telemetry API field requirements.
     */
    fun toAbrpMap(): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        map["utc"] = utcMillis / 1000.0
        socPercent?.let { map["soc"] = it }
        speedKmh?.let { map["speed"] = it }
        powerKw?.let { map["power"] = it }
        voltageV?.let { map["voltage"] = it }
        currentA?.let { map["current"] = it }
        latitude?.let { map["lat"] = it }
        longitude?.let { map["lon"] = it }
        altitudeM?.let { map["elevation"] = it }
        headingDeg?.let { map["heading"] = it }
        map["is_charging"] = if (isCharging) 1 else 0
        map["is_dcfc"] = if (isDcfc) 1 else 0
        map["is_parked"] = if (isParked) 1 else 0
        ambientTempC?.let { map["ext_temp"] = it }
        odometerKm?.let { map["odometer"] = it }
        return map
    }

    /**
     * Compact binary encoding for BLE GATT notifications (fits in small MTU).
     */
    fun toBinaryPayload(): ByteArray {
        var mask = 0
        if (socPercent != null) mask = mask or (1 shl 0)
        if (speedKmh != null) mask = mask or (1 shl 1)
        if (powerKw != null) mask = mask or (1 shl 2)
        if (voltageV != null) mask = mask or (1 shl 3)
        if (currentA != null) mask = mask or (1 shl 4)
        if (latitude != null && longitude != null) mask = mask or (1 shl 5)
        if (altitudeM != null) mask = mask or (1 shl 6)
        if (headingDeg != null) mask = mask or (1 shl 7)
        if (ambientTempC != null) mask = mask or (1 shl 8)
        if (odometerKm != null) mask = mask or (1 shl 9)
        if (isCharging) mask = mask or (1 shl 10)
        if (isDcfc) mask = mask or (1 shl 11)
        if (isParked) mask = mask or (1 shl 12)

        val buffer = ByteBuffer.allocate(64).order(ByteOrder.BIG_ENDIAN)
        buffer.put(MAGIC_BYTE)
        buffer.put(VERSION_BYTE)
        buffer.putShort(mask.toShort())
        buffer.putLong(utcMillis)

        socPercent?.let { buffer.putShort((it * 100).toInt().toShort()) }
        speedKmh?.let { buffer.putShort((it * 100).toInt().toShort()) }
        powerKw?.let { buffer.putInt((it * 100).toInt()) }
        voltageV?.let { buffer.putInt((it * 100).toInt()) }
        currentA?.let { buffer.putInt((it * 100).toInt()) }
        if (latitude != null && longitude != null) {
            buffer.putInt((latitude * 1_000_000).toInt())
            buffer.putInt((longitude * 1_000_000).toInt())
        }
        altitudeM?.let { buffer.putShort((it * 10).toInt().toShort()) }
        headingDeg?.let { buffer.putShort((it * 100).toInt().toShort()) }
        ambientTempC?.let { buffer.putShort((it * 100).toInt().toShort()) }
        odometerKm?.let { buffer.putInt((it * 10).toInt()) }

        val result = ByteArray(buffer.position())
        buffer.flip()
        buffer.get(result)
        return result
    }

    companion object {
        const val MAGIC_BYTE: Byte = 0xCB.toByte()
        const val VERSION_BYTE: Byte = 1

        fun fromBinaryPayload(bytes: ByteArray): LiveTelemetrySnapshot {
            require(bytes.size >= 12) { "Invalid payload length: ${bytes.size}" }
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
            val magic = buffer.get()
            require(magic == MAGIC_BYTE) { "Invalid magic byte: $magic" }
            val version = buffer.get()
            require(version == VERSION_BYTE) { "Unsupported version: $version" }
            val mask = buffer.short.toInt() and 0xFFFF
            val utcMillis = buffer.long

            val socPercent = if ((mask and (1 shl 0)) != 0) buffer.short.toDouble() / 100.0 else null
            val speedKmh = if ((mask and (1 shl 1)) != 0) buffer.short.toDouble() / 100.0 else null
            val powerKw = if ((mask and (1 shl 2)) != 0) buffer.int.toDouble() / 100.0 else null
            val voltageV = if ((mask and (1 shl 3)) != 0) buffer.int.toDouble() / 100.0 else null
            val currentA = if ((mask and (1 shl 4)) != 0) buffer.int.toDouble() / 100.0 else null
            val (latitude, longitude) = if ((mask and (1 shl 5)) != 0) {
                Pair(buffer.int.toDouble() / 1_000_000.0, buffer.int.toDouble() / 1_000_000.0)
            } else {
                Pair(null, null)
            }
            val altitudeM = if ((mask and (1 shl 6)) != 0) buffer.short.toDouble() / 10.0 else null
            val headingDeg = if ((mask and (1 shl 7)) != 0) buffer.short.toDouble() / 100.0 else null
            val ambientTempC = if ((mask and (1 shl 8)) != 0) buffer.short.toDouble() / 100.0 else null
            val odometerKm = if ((mask and (1 shl 9)) != 0) buffer.int.toDouble() / 10.0 else null
            val isCharging = (mask and (1 shl 10)) != 0
            val isDcfc = (mask and (1 shl 11)) != 0
            val isParked = (mask and (1 shl 12)) != 0

            return LiveTelemetrySnapshot(
                utcMillis = utcMillis,
                socPercent = socPercent,
                speedKmh = speedKmh,
                powerKw = powerKw,
                voltageV = voltageV,
                currentA = currentA,
                latitude = latitude,
                longitude = longitude,
                altitudeM = altitudeM,
                headingDeg = headingDeg,
                isCharging = isCharging,
                isDcfc = isDcfc,
                isParked = isParked,
                ambientTempC = ambientTempC,
                odometerKm = odometerKm
            )
        }
    }
}
