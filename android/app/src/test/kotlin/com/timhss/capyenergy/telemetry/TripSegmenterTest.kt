package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixed-distance cuts, odometer-first, and the trip context that must
 * survive retention. No Room: this is the maths, not the write.
 */
class TripSegmenterTest {
    @Test
    fun `one kilometre at 200 m steps is five segments`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 0f),
                sample(1, odometerKm = 0.2f),
                sample(2, odometerKm = 0.4f),
                sample(3, odometerKm = 0.6f),
                sample(4, odometerKm = 0.8f),
                sample(5, odometerKm = 1.0f),
            )
        )
        assertEquals(5, cut.segments.size)
        cut.segments.forEach { segment ->
            assertEquals(0.2, segment.distanceKm, 1e-6)
        }
        assertEquals(0, cut.segments.first().ordinal)
        assertEquals(4, cut.segments.last().ordinal)
    }

    @Test
    fun `a leftover shorter than 200 m is kept`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 0f),
                sample(1, odometerKm = 0.2f),
                sample(2, odometerKm = 0.35f),
            )
        )
        assertEquals(2, cut.segments.size)
        assertEquals(0.2, cut.segments[0].distanceKm, 1e-6)
        assertEquals(0.15, cut.segments[1].distanceKm, 1e-6)
    }

    @Test
    fun `speed fills in when the odometer is absent`() {
        // 72 km/h for 10 s is 0.2 km.
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, speedKmh = 72f),
                sample(10, speedKmh = 72f),
            )
        )
        assertEquals(1, cut.segments.size)
        assertEquals(0.2, cut.segments.single().distanceKm, 1e-6)
        assertEquals(72.0, cut.segments.single().meanSpeedKmh!!, 1e-9)
    }

    @Test
    fun `odometer wins over speed`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 10f, speedKmh = 200f),
                sample(1, odometerKm = 10.2f, speedKmh = 200f),
            )
        )
        assertEquals(0.2, cut.segments.single().distanceKm, 1e-6)
    }

    @Test
    fun `the CAN interval matches the trip integral`() {
        val samples = listOf(
            sample(0, odometerKm = 0f, driveKw = 30f, volts = 360f, amps = 100f),
            sample(1, odometerKm = 0.2f, driveKw = 30f, volts = 360f, amps = 100f),
        )
        val cut = TripSegmenter.cut(samples)
        val segment = cut.segments.single()
        // 36 kW for 1 s is 10 Wh. Drive 30 kW is 8.333 Wh traction.
        assertEquals(10.0, segment.packWh!!, 1e-6)
        assertEquals(30.0 / 3.6, segment.tractionWh!!, 1e-6)
        assertEquals(0.0, segment.regeneratedWh!!, 1e-9)
        assertEquals(6.0 / 3.6, segment.auxiliaryWh!!, 1e-6)
        assertEquals(1.0, segment.integratedSeconds, 1e-9)
    }

    @Test
    fun `altitude gain and loss are the trip context`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 0f, altitudeM = 100.0),
                sample(1, odometerKm = 0.1f, altitudeM = 110.0),
                sample(2, odometerKm = 0.2f, altitudeM = 105.0),
            )
        )
        assertEquals(10.0, cut.context.altitudeGainM!!, 1e-9)
        assertEquals(5.0, cut.context.altitudeLossM!!, 1e-9)
        assertEquals(10.0, cut.segments.single().altitudeGainM!!, 1e-9)
        assertEquals(5.0, cut.segments.single().altitudeLossM!!, 1e-9)
    }

    @Test
    fun `a GPS glitch is not a climb`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 0f, altitudeM = 100.0),
                sample(1, odometerKm = 0.2f, altitudeM = 200.0),
            )
        )
        assertNull(cut.context.altitudeGainM)
        assertNull(cut.segments.single().altitudeGainM)
    }

    @Test
    fun `mean ambient is the trip context`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 0f, ambientTempC = 20f),
                sample(1, odometerKm = 0.2f, ambientTempC = 24f),
            )
        )
        assertEquals(22.0, cut.context.meanAmbientTempC!!, 1e-9)
    }

    @Test
    fun `the path keeps the coordinates`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 0f, latitude = -10.18, longitude = -48.33),
                sample(1, odometerKm = 0.2f, latitude = -10.19, longitude = -48.34),
            )
        )
        val segment = cut.segments.single()
        assertEquals(-10.18, segment.startLatitude!!, 1e-9)
        assertEquals(-48.34, segment.endLongitude!!, 1e-9)
        assertEquals(2, segment.path.size)
        assertEquals(
            "-10.18,-48.33;-10.19,-48.34",
            TripSegmenter.encodePath(segment.path),
        )
    }

    @Test
    fun `no samples is no geometry`() {
        val cut = TripSegmenter.cut(emptyList())
        assertTrue(cut.segments.isEmpty())
        assertNull(cut.context.meanAmbientTempC)
        assertNull(cut.context.altitudeGainM)
    }

    @Test
    fun `toEntity carries the session account onto every rewritten stretch`() {
        val cut = TripSegmenter.cut(
            listOf(
                sample(0, odometerKm = 0f),
                sample(1, odometerKm = 0.2f),
                sample(2, odometerKm = 0.4f),
            )
        )
        val rows = cut.segments.map { TripSegmenter.toEntity(it, "sess-1", "acc-a") }
        assertTrue(rows.isNotEmpty())
        rows.forEach { row ->
            assertEquals("sess-1", row.sessionId)
            // The close rewrites the stretches inside the finalizer's
            // transaction; the account must survive that rewrite.
            assertEquals("acc-a", row.accountId)
        }
    }

    private fun sample(
        seconds: Long,
        odometerKm: Float? = null,
        speedKmh: Float? = null,
        ambientTempC: Float? = null,
        latitude: Double? = null,
        longitude: Double? = null,
        altitudeM: Double? = null,
        driveKw: Float? = null,
        volts: Float? = null,
        amps: Float? = null,
    ) = SessionAggregateSampleRow(
        elapsedRealtimeNanos = seconds * 1_000_000_000L,
        wallTimeUtcMillis = seconds * 1_000L,
        speedKmh = speedKmh,
        socPercent = 80f,
        odometerKm = odometerKm,
        voltageV = null,
        currentA = null,
        powerKw = null,
        freshnessMask = 0,
        canDrivePowerKw = driveKw,
        canPackVoltageV = volts,
        canPackCurrentA = amps,
        ambientTempC = ambientTempC,
        latitude = latitude,
        longitude = longitude,
        altitudeM = altitudeM,
    )
}
