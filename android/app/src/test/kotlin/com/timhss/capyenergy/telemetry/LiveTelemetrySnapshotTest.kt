package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveTelemetrySnapshotTest {

    private fun sample(key: SignalKey, value: Any?, quality: SignalQuality = SignalQuality.MEASURED): SignalSample {
        return SignalSample(
            signalId = key,
            value = value,
            unit = key.unit,
            quality = quality,
            source = SignalSource.CAN_BRIDGE,
            propertyId = 0,
            propertyIdHex = "0x0",
            areaId = 0,
            timestamp = SignalTimestamp(
                receivedAtUtcMillis = 100L,
                receivedAtElapsedNanos = 100L,
                sourceTimestampNanos = 100L,
                accuracy = TimestampAccuracy.SOURCE_EVENT,
                uncertaintyMillis = 0L
            ),
            details = ""
        )
    }

    @Test
    fun binarySerialization_roundTrip_allFieldsPopulated() {
        val original = LiveTelemetrySnapshot(
            utcMillis = 1724443200000L,
            socPercent = 65.4,
            speedKmh = 72.5,
            powerKw = -14.2,
            voltageV = 368.5,
            currentA = -38.5,
            latitude = -23.55052,
            longitude = -46.633308,
            altitudeM = 760.5,
            headingDeg = 184.2,
            isCharging = false,
            isDcfc = false,
            isParked = false,
            ambientTempC = 22.5,
            odometerKm = 14250.8
        )

        val bytes = original.toBinaryPayload()
        val restored = LiveTelemetrySnapshot.fromBinaryPayload(bytes)

        assertEquals(original.utcMillis, restored.utcMillis)
        assertEquals(original.socPercent!!, restored.socPercent!!, 0.01)
        assertEquals(original.speedKmh!!, restored.speedKmh!!, 0.01)
        assertEquals(original.powerKw!!, restored.powerKw!!, 0.01)
        assertEquals(original.voltageV!!, restored.voltageV!!, 0.01)
        assertEquals(original.currentA!!, restored.currentA!!, 0.01)
        assertEquals(original.latitude!!, restored.latitude!!, 0.00001)
        assertEquals(original.longitude!!, restored.longitude!!, 0.00001)
        assertEquals(original.altitudeM!!, restored.altitudeM!!, 0.1)
        assertEquals(original.headingDeg!!, restored.headingDeg!!, 0.01)
        assertFalse(restored.isCharging)
        assertFalse(restored.isDcfc)
        assertFalse(restored.isParked)
        assertEquals(original.ambientTempC!!, restored.ambientTempC!!, 0.01)
        assertEquals(original.odometerKm!!, restored.odometerKm!!, 0.1)
    }

    @Test
    fun binarySerialization_roundTrip_minimalFields() {
        val original = LiveTelemetrySnapshot(
            utcMillis = 1724443200000L,
            isCharging = true,
            isDcfc = true,
            isParked = true
        )

        val bytes = original.toBinaryPayload()
        val restored = LiveTelemetrySnapshot.fromBinaryPayload(bytes)

        assertEquals(original.utcMillis, restored.utcMillis)
        assertNull(restored.socPercent)
        assertNull(restored.speedKmh)
        assertNull(restored.powerKw)
        assertNull(restored.voltageV)
        assertNull(restored.currentA)
        assertNull(restored.latitude)
        assertNull(restored.longitude)
        assertNull(restored.altitudeM)
        assertNull(restored.headingDeg)
        assertTrue(restored.isCharging)
        assertTrue(restored.isDcfc)
        assertTrue(restored.isParked)
        assertNull(restored.ambientTempC)
        assertNull(restored.odometerKm)
    }

    @Test
    fun toAbrpMap_mapsCorrectTelemetryKeys() {
        val snapshot = LiveTelemetrySnapshot(
            utcMillis = 1724443200000L,
            socPercent = 80.0,
            speedKmh = 60.0,
            powerKw = 15.0,
            voltageV = 370.0,
            currentA = 40.5,
            latitude = -23.55,
            longitude = -46.63,
            altitudeM = 750.0,
            headingDeg = 90.0,
            isCharging = true,
            isDcfc = false,
            isParked = true,
            ambientTempC = 25.0,
            odometerKm = 10000.0
        )

        val map = snapshot.toAbrpMap()

        assertEquals(1724443200.0, map["utc"] as Double, 0.001)
        assertEquals(80.0, map["soc"])
        assertEquals(60.0, map["speed"])
        assertEquals(15.0, map["power"])
        assertEquals(370.0, map["voltage"])
        assertEquals(40.5, map["current"])
        assertEquals(-23.55, map["lat"])
        assertEquals(-46.63, map["lon"])
        assertEquals(750.0, map["elevation"])
        assertEquals(90.0, map["heading"])
        assertEquals(1, map["is_charging"])
        assertEquals(0, map["is_dcfc"])
        assertEquals(1, map["is_parked"])
        assertEquals(25.0, map["ext_temp"])
        assertEquals(10000.0, map["odometer"])
    }

    @Test
    fun assembler_assemblesFromStoreAndLocation() {
        val signals = mapOf(
            SignalKey.HV_BATTERY_SOC to sample(SignalKey.HV_BATTERY_SOC, 75.0),
            SignalKey.VEHICLE_SPEED to sample(SignalKey.VEHICLE_SPEED, 85.0),
            SignalKey.EV_BATTERY_INSTANTANEOUS_POWER to sample(SignalKey.EV_BATTERY_INSTANTANEOUS_POWER, 18.5),
            SignalKey.HV_BATTERY_VOLTAGE to sample(SignalKey.HV_BATTERY_VOLTAGE, 372.0),
            SignalKey.HV_BATTERY_CURRENT to sample(SignalKey.HV_BATTERY_CURRENT, 50.0),
            SignalKey.AMBIENT_AIR_TEMPERATURE to sample(SignalKey.AMBIENT_AIR_TEMPERATURE, 24.0),
            SignalKey.ODOMETER to sample(SignalKey.ODOMETER, 15000.0)
        )

        val location = LocationSnapshot(
            latitude = -23.55052,
            longitude = -46.633308,
            altitudeM = 760.0,
            accuracyM = 5.0f,
            provider = "gps",
            elapsedRealtimeNanos = 1000000000L,
            wallTimeUtcMillis = 1724443200000L,
            bearingDeg = 180.0f
        )

        val snapshot = LiveTelemetrySnapshotAssembler.assemble(
            wallTimeUtcMillis = 1724443200000L,
            signalSnapshot = signals,
            locationSnapshot = location,
            isCharging = false,
            isDcfc = false,
            isParked = false
        )

        assertEquals(1724443200000L, snapshot.utcMillis)
        assertEquals(75.0, snapshot.socPercent!!, 0.01)
        assertEquals(85.0, snapshot.speedKmh!!, 0.01)
        assertEquals(18.5, snapshot.powerKw!!, 0.01)
        assertEquals(372.0, snapshot.voltageV!!, 0.01)
        assertEquals(50.0, snapshot.currentA!!, 0.01)
        assertEquals(-23.55052, snapshot.latitude!!, 0.00001)
        assertEquals(-46.633308, snapshot.longitude!!, 0.00001)
        assertEquals(760.0, snapshot.altitudeM!!, 0.1)
        assertEquals(180.0, snapshot.headingDeg!!, 0.01)
        assertEquals(24.0, snapshot.ambientTempC!!, 0.01)
        assertEquals(15000.0, snapshot.odometerKm!!, 0.1)
        assertFalse(snapshot.isCharging)
    }

    @Test
    fun assembler_omitsInvalidOrMutedSignals() {
        val signals = mapOf(
            SignalKey.HV_BATTERY_SOC to sample(SignalKey.HV_BATTERY_SOC, 75.0),
            // Muted or invalid outside temperature:
            SignalKey.AMBIENT_AIR_TEMPERATURE to sample(SignalKey.AMBIENT_AIR_TEMPERATURE, null, SignalQuality.UNAVAILABLE)
        )

        val snapshot = LiveTelemetrySnapshotAssembler.assemble(
            wallTimeUtcMillis = 1724443200000L,
            signalSnapshot = signals,
            locationSnapshot = null,
            isCharging = false,
            isDcfc = false,
            isParked = true
        )

        assertEquals(75.0, snapshot.socPercent!!, 0.01)
        assertNull(snapshot.ambientTempC)
        assertNull(snapshot.latitude)
        assertNull(snapshot.headingDeg)
        assertTrue(snapshot.isParked)
    }

    @Test
    fun assembler_derivesIsDcfcFromPlugType_smallCode() {
        val signals = mapOf(
            SignalKey.EV_CHARGE_PLUG_TYPE to sample(SignalKey.EV_CHARGE_PLUG_TYPE, 2)
        )
        val snapshot = LiveTelemetrySnapshotAssembler.assemble(
            wallTimeUtcMillis = 1724443200000L,
            signalSnapshot = signals,
            locationSnapshot = null,
            isCharging = true,
            isParked = false
        )
        assertTrue(snapshot.isDcfc)
        assertEquals(1724443200000L, snapshot.utcMillis)
    }

    @Test
    fun assembler_derivesIsDcfcFromPlugType_largeHardwareCode() {
        val dc = com.timhss.capyenergy.profile.GeelyProperties.ChargePlugStateDcConnected
        val signals = mapOf(
            SignalKey.EV_CHARGE_PLUG_TYPE to sample(SignalKey.EV_CHARGE_PLUG_TYPE, dc)
        )
        val snapshot = LiveTelemetrySnapshotAssembler.assemble(
            wallTimeUtcMillis = 123456789L,
            signalSnapshot = signals,
            locationSnapshot = null,
            isCharging = true,
            isParked = false
        )
        assertTrue(snapshot.isDcfc)
    }

    @Test
    fun assembler_isDcfcFalseForAcPlug() {
        val signals = mapOf(
            SignalKey.EV_CHARGE_PLUG_TYPE to sample(SignalKey.EV_CHARGE_PLUG_TYPE, 1)
        )
        val snapshot = LiveTelemetrySnapshotAssembler.assemble(
            signalSnapshot = signals,
            locationSnapshot = null,
            isCharging = true,
            isParked = false
        )
        assertFalse(snapshot.isDcfc)
    }

    @Test
    fun assembler_usesWallTimeUtcMillis() {
        val signals = mapOf(
            SignalKey.HV_BATTERY_SOC to sample(SignalKey.HV_BATTERY_SOC, 50.0)
        )
        val snapshot = LiveTelemetrySnapshotAssembler.assemble(
            wallTimeUtcMillis = 999999999L,
            signalSnapshot = signals,
            locationSnapshot = null,
            isCharging = false,
            isParked = false
        )
        assertEquals(999999999L, snapshot.utcMillis)
        assertFalse(snapshot.isDcfc)
    }
}
