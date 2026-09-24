package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import org.junit.Assert.assertEquals
import org.junit.Test

class FrameSpeedSourceTest {
    @Test
    fun `Room speed uses CarPropertyManager value instead of Roadcast`() {
        val vhalSpeed = sample(72.0f, SignalSource.VHAL_CALLBACK)
        val roadcast = RoadcastTripMetrics(
            drivePowerKw = null,
            packVoltageV = null,
            packCurrentA = null,
            packCurrentRaw = null,
            packCurrentEstimated = null,
            vehicleSpeedKmh = 19.0f,
            receivedAtElapsedNanos = 1_000_000_000L,
            sourceAgeNanos = 0L,
        )

        assertEquals(
            72.0f,
            persistedFrameSpeedKmh(mapOf(SignalKey.VEHICLE_SPEED to vhalSpeed), roadcast),
        )
        assertEquals(72.0f, vehicleSpeedPayload(vhalSpeed)["speedKmh"])
    }

    @Test
    fun `Room speed has no Roadcast fallback when CarPropertyManager is absent`() {
        val roadcast = RoadcastTripMetrics(
            drivePowerKw = null,
            packVoltageV = null,
            packCurrentA = null,
            packCurrentRaw = null,
            packCurrentEstimated = null,
            vehicleSpeedKmh = 19.0f,
            receivedAtElapsedNanos = 1_000_000_000L,
            sourceAgeNanos = 0L,
        )

        assertEquals(null, persistedFrameSpeedKmh(emptyMap(), roadcast))
    }

    private fun sample(value: Float, source: SignalSource) = SignalSample(
        signalId = SignalKey.VEHICLE_SPEED,
        value = value,
        unit = "km/h",
        quality = SignalQuality.MEASURED,
        source = source,
        propertyId = 291504647,
        propertyIdHex = "0x11600207",
        areaId = 0,
        timestamp = SignalTimestamp(
            receivedAtUtcMillis = 1_000L,
            receivedAtElapsedNanos = 1_000_000_000L,
            sourceTimestampNanos = 900_000_000L,
            accuracy = TimestampAccuracy.SOURCE_EVENT,
            uncertaintyMillis = 0L,
        ),
        details = "test",
    )
}
