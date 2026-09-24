package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AmbientTemperatureSelectorTest {
    @Test
    fun prefersVendorAmbientTemperatureEvenWhenFallbackIsNewer() {
        val snapshot = mapOf(
            SignalKey.AMBIENT_AIR_TEMPERATURE to sample(
                seconds = 0,
                signalId = SignalKey.AMBIENT_AIR_TEMPERATURE,
                value = 18.5f
            ),
            SignalKey.OUTSIDE_TEMPERATURE to sample(
                seconds = 40,
                signalId = SignalKey.OUTSIDE_TEMPERATURE,
                value = 25.0f
            )
        )

        assertEquals(
            18.5f,
            selectedAmbientTemperatureC(snapshot, timestamp(seconds = 40))
        )
    }

    @Test
    fun usesFreshFallbackOnlyWhenVendorIsMissing() {
        val snapshot = mapOf(
            SignalKey.OUTSIDE_TEMPERATURE to sample(
                seconds = 10,
                signalId = SignalKey.OUTSIDE_TEMPERATURE,
                value = 25.0f
            )
        )

        assertEquals(
            25.0f,
            selectedAmbientTemperatureC(snapshot, timestamp(seconds = 10))
        )
    }

    @Test
    fun ignoresStaleFallbackWhenVendorIsMissing() {
        val snapshot = mapOf(
            SignalKey.OUTSIDE_TEMPERATURE to sample(
                seconds = 0,
                signalId = SignalKey.OUTSIDE_TEMPERATURE,
                value = 25.0f
            )
        )

        assertNull(selectedAmbientTemperatureC(snapshot, timestamp(seconds = 40)))
    }

    private fun sample(seconds: Int, signalId: SignalKey, value: Any?): SignalSample {
        return SignalSample(
            signalId = signalId,
            value = value,
            unit = "°C",
            quality = SignalQuality.MEASURED,
            source = SignalSource.VHAL_POLLING,
            propertyId = 0,
            propertyIdHex = "0x00000000",
            areaId = 0,
            timestamp = timestamp(seconds),
            details = "test"
        )
    }

    private fun timestamp(seconds: Int): SignalTimestamp {
        return SignalTimestamp(
            receivedAtUtcMillis = 1_700_000_000_000L + seconds * 1_000L,
            receivedAtElapsedNanos = seconds * 1_000_000_000L,
            sourceTimestampNanos = null,
            accuracy = TimestampAccuracy.POLLED,
            uncertaintyMillis = 0L
        )
    }
}

