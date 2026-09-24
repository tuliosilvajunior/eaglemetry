package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one-time backfill: pairing sample rows back into a Track path.
 *
 * The reference is `packages/telemetry_core/test/track_backfill_test.dart`,
 * the Dart implementation this migration mirrors. The fixtures here are the
 * same drives and the same expectations, so the car and the Dart model agree
 * on what a legacy route means.
 */
class TrackBackfillTest {

    private fun makeRow(
        key: String,
        elapsedNanos: Long,
        value: Double,
        utcMillis: Long = 1_000_000L,
        groupId: String? = null,
        validity: String = LegacyTrackBackfill.VALIDITY_INVALID
    ): LegacyTrackBackfill.SampleRow = LegacyTrackBackfill.SampleRow(
        key = key,
        value = value,
        validity = validity,
        groupId = groupId,
        tUtcMillis = utcMillis,
        tElapsedNanos = elapsedNanos
    )

    private fun measured(
        key: String,
        elapsedNanos: Long,
        value: Double,
        utcMillis: Long = 1_000_000L,
        groupId: String? = null
    ) = makeRow(key, elapsedNanos, value, utcMillis, groupId, validity = "MEASURED")

    @Test
    fun `converts sample point fixture to TrackRow and matches route points`() {
        val rows = listOf(
            measured(LegacyTrackBackfill.KEY_LATITUDE, 0L, -23.550520, groupId = "g1"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 5_000_000_000L, -23.551000, groupId = "g2"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 10_000_000_000L, -23.552000, groupId = "g3"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 0L, -46.633308, groupId = "g1"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 5_000_000_000L, -46.634000, groupId = "g2"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 10_000_000_000L, -46.635000, groupId = "g3"),
        )

        val points = LegacyTrackBackfill.trackPoints(rows, startedAtElapsedNanos = 0L, startedAtUtcMillis = null)
        assertEquals(3, points.size)
        assertEquals(-23.550520, points[0].latitude, 1e-5)
        assertEquals(-46.633308, points[0].longitude, 1e-5)
        assertEquals(0.0, points[0].tSeconds, 1e-3)
        assertEquals(-23.551000, points[1].latitude, 1e-5)
        assertEquals(5.0, points[1].tSeconds, 1e-3)
        assertEquals(-23.552000, points[2].latitude, 1e-5)
        assertEquals(10.0, points[2].tSeconds, 1e-3)
    }

    @Test
    fun `holds altitude and speed forward, and counts climb and descent`() {
        val rows = listOf(
            measured(LegacyTrackBackfill.KEY_LATITUDE, 0L, -23.550520, groupId = "g1"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 5_000_000_000L, -23.551000, groupId = "g2"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 10_000_000_000L, -23.552000, groupId = "g3"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 0L, -46.633308, groupId = "g1"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 5_000_000_000L, -46.634000, groupId = "g2"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 10_000_000_000L, -46.635000, groupId = "g3"),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 0L, 750.0, groupId = "g1"),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 5_000_000_000L, 760.0, groupId = "g2"),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 10_000_000_000L, 755.0, groupId = "g3"),
            measured(LegacyTrackBackfill.KEY_SPEED, 0L, 0.0),
            measured(LegacyTrackBackfill.KEY_SPEED, 4_000_000_000L, 30.0),
            measured(LegacyTrackBackfill.KEY_SPEED, 8_000_000_000L, 50.0),
        )

        val points = LegacyTrackBackfill.trackPoints(rows, startedAtElapsedNanos = 0L, startedAtUtcMillis = null)
        assertEquals(3, points.size)
        assertEquals(750.0, points[0].altitudeM, 0.1)
        assertEquals(0.0, points[0].speedKmh, 0.1)
        assertEquals(760.0, points[1].altitudeM, 0.1)
        assertEquals(30.0, points[1].speedKmh, 0.1)
        assertEquals(755.0, points[2].altitudeM, 0.1)
        assertEquals(50.0, points[2].speedKmh, 0.1)

        val (climb, descent) = LegacyTrackBackfill.computeClimbDescent(points)
        assertEquals(10.0, climb, 1e-3)
        assertEquals(5.0, descent, 1e-3)

        val outcome = LegacyTrackBackfill.backfill(
            "s-1",
            points,
            rows.filter { it.key == LegacyTrackBackfill.KEY_ALTITUDE },
            nowUtcMillis = 1_000L
        )
        assertEquals(3, outcome.fixCount)
        assertEquals(10.0, outcome.climbM, 1e-3)
        assertEquals(5.0, outcome.descentM, 1e-3)
        assertEquals(3, outcome.track?.pointCount)
        assertTrue(outcome.track != null)

        val decoded = TrackCodec.decode(outcome.track!!.toRow())
        assertEquals(-23.55052, decoded[0].latitude, 1e-5)
        assertEquals(-46.63331, decoded[0].longitude, 1e-5)
        assertEquals(750.0, decoded[0].altitudeM, 0.1)
    }

    @Test
    fun `pairs points by timestamp when groupId is missing`() {
        val rows = listOf(
            measured(LegacyTrackBackfill.KEY_LATITUDE, 1_000_000_000L, -23.550520),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 2_000_000_000L, -23.551000),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 1_000_000_000L, -46.633308),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 2_000_000_000L, -46.634000),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 1_000_000_000L, 700.0),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 2_000_000_000L, 720.0),
        )

        val points = LegacyTrackBackfill.trackPoints(
            rows,
            startedAtElapsedNanos = 1_000_000_000L,
            startedAtUtcMillis = null
        )
        assertEquals(2, points.size)
        assertEquals(0.0, points[0].tSeconds, 1e-3)
        assertEquals(1.0, points[1].tSeconds, 1e-3)

        val (climb, descent) = LegacyTrackBackfill.computeClimbDescent(points)
        assertEquals(20.0, climb, 1e-3)
        assertEquals(0.0, descent, 1e-3)
    }

    @Test
    fun `computes climbM and descentM matching altitude deltas accurately`() {
        val rows = listOf(
            measured(LegacyTrackBackfill.KEY_LATITUDE, 0L, -23.0, groupId = "1"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 1_000_000_000L, -23.01, groupId = "2"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 2_000_000_000L, -23.02, groupId = "3"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 3_000_000_000L, -23.03, groupId = "4"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 0L, -46.0, groupId = "1"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 1_000_000_000L, -46.01, groupId = "2"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 2_000_000_000L, -46.02, groupId = "3"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 3_000_000_000L, -46.03, groupId = "4"),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 0L, 100.0, groupId = "1"),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 1_000_000_000L, 150.0, groupId = "2"),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 2_000_000_000L, 120.0, groupId = "3"),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 3_000_000_000L, 180.0, groupId = "4"),
        )

        val points = LegacyTrackBackfill.trackPoints(rows, startedAtElapsedNanos = null, startedAtUtcMillis = null)
        val (climb, descent) = LegacyTrackBackfill.computeClimbDescent(points)
        assertEquals(110.0, climb, 1e-3)
        assertEquals(30.0, descent, 1e-3)
    }

    @Test
    fun `handles sparse, mismatched, or missing coordinates gracefully`() {
        val rows = listOf(
            measured(LegacyTrackBackfill.KEY_LATITUDE, 1_000_000_000L, -23.550, groupId = "matched"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 2_000_000_000L, -23.551, groupId = "lon_missing"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 1_000_000_000L, -46.633, groupId = "matched"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 3_000_000_000L, -46.635, groupId = "lat_missing"),
        )

        val points = LegacyTrackBackfill.trackPoints(rows, startedAtElapsedNanos = null, startedAtUtcMillis = null)
        assertEquals(1, points.size)
        assertEquals(-23.550, points[0].latitude, 1e-5)
        assertEquals(-46.633, points[0].longitude, 1e-5)
    }

    @Test
    fun `empty samples produce no points and no track`() {
        val points = LegacyTrackBackfill.trackPoints(
            emptyList(),
            startedAtElapsedNanos = null,
            startedAtUtcMillis = null
        )
        assertEquals(0, points.size)

        val outcome = LegacyTrackBackfill.backfill(
            "s-1",
            points,
            altitudeRows = emptyList(),
            nowUtcMillis = 1_000L
        )
        assertTrue(outcome.track == null)
        assertEquals(0, outcome.fixCount)
        assertEquals(0.0, outcome.climbM, 1e-3)
    }

    @Test
    fun `altitude-only session keeps its climb without a track row`() {
        val altitudeRows = listOf(
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 0L, 100.0),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 1_000_000_000L, 150.0),
            measured(LegacyTrackBackfill.KEY_ALTITUDE, 2_000_000_000L, 120.0),
        )

        val outcome = LegacyTrackBackfill.backfill(
            "s-1",
            raw = emptyList(),
            altitudeRows = altitudeRows,
            nowUtcMillis = 1_000L
        )
        assertTrue(outcome.track == null)
        assertEquals(50.0, outcome.climbM, 1e-3)
        assertEquals(30.0, outcome.descentM, 1e-3)
    }

    @Test
    fun `invalid readings are not route points`() {
        val rows = listOf(
            makeRow(LegacyTrackBackfill.KEY_LATITUDE, 0L, -23.550520, groupId = "g1", validity = "INVALID"),
            measured(LegacyTrackBackfill.KEY_LATITUDE, 5_000_000_000L, -23.551000, groupId = "g2"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 0L, -46.633308, groupId = "g1"),
            measured(LegacyTrackBackfill.KEY_LONGITUDE, 5_000_000_000L, -46.634000, groupId = "g2"),
        )

        val points = LegacyTrackBackfill.trackPoints(rows, startedAtElapsedNanos = 0L, startedAtUtcMillis = null)
        assertEquals(1, points.size)
        assertEquals(-23.551000, points[0].latitude, 1e-5)
        assertEquals(-46.634000, points[0].longitude, 1e-5)
    }
}