package com.timhss.capyenergy.roadcast

import com.timhss.capyenergy.roadcast.RoadcastSample
import com.timhss.capyenergy.roadcast.RoadcastSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VehicleStateRoadcastProvidersTest {
    @Test
    fun driverBeltUsesItsOwnInvertedPolarityAndUnknownClosuresRemainDistinct() {
        val reading = OccupancyRoadcastProvider.read(snapshot(
            OccupancyRoadcastProvider.FRONT_LEFT_DOOR to sample(0),
            OccupancyRoadcastProvider.FRONT_RIGHT_DOOR to sample(0),
            OccupancyRoadcastProvider.REAR_LEFT_DOOR to sample(0),
            OccupancyRoadcastProvider.REAR_RIGHT_DOOR to sample(0),
            OccupancyRoadcastProvider.HOOD to sample(0),
            // Trunk intentionally absent.
            OccupancyRoadcastProvider.DRIVER_BELT to sample(1),
        ))

        assertEquals(KnownBoolean.UNKNOWN, reading.trunkOpen)
        assertEquals(KnownBoolean.FALSE, reading.driverSeatbeltBuckled)
        assertTrue(reading.noClosureIsOpen)
    }

    @Test
    fun keyProviderKeepsFobAndDoorFactsInSameSnapshot() {
        val reading = KeyRoadcastProvider.read(snapshot(
            KeyRoadcastProvider.FOB_NUM to sample(0),
            KeyRoadcastProvider.RKE_COMMAND to sample(3),
            OccupancyRoadcastProvider.FRONT_LEFT_DOOR to sample(0),
        ))

        assertEquals(KnownBoolean.FALSE, reading.fobPresent)
        assertEquals(3L, reading.rkeCommand)
        assertEquals(KnownBoolean.FALSE, reading.frontLeftOpen)
        assertEquals(KnownBoolean.UNKNOWN, reading.rearRightOpen)
    }

    private fun snapshot(vararg entries: Pair<String, RoadcastSample>) = RoadcastSnapshot(
        sampleSequence = 1L,
        receivedAtElapsedNanos = 1L,
        sampleAgeNanos = 1L,
        samples = mapOf(*entries),
        missingSignals = emptySet(),
    )

    private fun sample(raw: Long) = RoadcastSample(
        raw = raw,
        physical = raw.toDouble(),
        valid = true,
        calibrated = false,
        lastChangeNanos = 1L,
    )
}
