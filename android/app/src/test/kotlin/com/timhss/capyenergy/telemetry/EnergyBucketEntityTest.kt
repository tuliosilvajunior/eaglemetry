package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.toEnergyBucket
import org.junit.Assert.assertEquals
import org.junit.Test

class EnergyBucketEntityTest {

    @Test
    fun `a stored minute reads back field for field`() {
        val bucket = IntervalEntity(
            sessionId = "trip-1",
            startUtcMillis = 1_785_690_900_000L,
            tractionWh = 11.0,
            regenWh = 22.0,
            auxiliaryWh = 33.0,
            climateWh = 44.0,
            deliveredWh = 55.0,
            distanceKm = 66.0,
            coveredSeconds = 77.0,
            climateCoveredSeconds = 88.0,
            deliveredCoveredSeconds = 99.0,
            startSoc = 50.0,
            endSoc = 49.5,
            startVoltage = 380.0,
            endVoltage = 385.0,
            updatedAtUtcMillis = 1_785_690_960_000L
        ).toEnergyBucket()

        assertEquals(1_785_690_900_000L, bucket.startUtcMillis)
        assertEquals(11.0, bucket.tractionWh, 1e-9)
        assertEquals(22.0, bucket.regeneratedWh, 1e-9)
        assertEquals(33.0, bucket.auxiliaryWh, 1e-9)
        assertEquals(44.0, bucket.climateWh, 1e-9)
        assertEquals(55.0, bucket.deliveredWh, 1e-9)
        assertEquals(66.0, bucket.speedDistanceKm, 1e-9)
        assertEquals(77.0, bucket.integratedSeconds, 1e-9)
        assertEquals(88.0, bucket.climateIntegratedSeconds, 1e-9)
        assertEquals(99.0, bucket.deliveredCoveredSeconds, 1e-9)
        assertEquals(50.0, bucket.startSoc!!, 1e-9)
        assertEquals(49.5, bucket.endSoc!!, 1e-9)
        assertEquals(380.0, bucket.startVoltage!!, 1e-9)
        assertEquals(385.0, bucket.endVoltage!!, 1e-9)

        val entity = bucket.toEntity("trip-1", 1_785_690_960_000L)
        assertEquals(50.0, entity.startSoc!!, 1e-9)
        assertEquals(49.5, entity.endSoc!!, 1e-9)
        assertEquals(380.0, entity.startVoltage!!, 1e-9)
        assertEquals(385.0, entity.endVoltage!!, 1e-9)
    }

    @Test
    fun `a stored minute without reading preserves null rather than default`() {
        val bucket = IntervalEntity(
            sessionId = "trip-1",
            startUtcMillis = 1_785_690_900_000L,
            startSoc = null,
            endSoc = null,
            startVoltage = null,
            endVoltage = null,
            updatedAtUtcMillis = 1_785_690_960_000L
        ).toEnergyBucket()

        org.junit.Assert.assertNull(bucket.startSoc)
        org.junit.Assert.assertNull(bucket.endSoc)
        org.junit.Assert.assertNull(bucket.startVoltage)
        org.junit.Assert.assertNull(bucket.endVoltage)

        val entity = bucket.toEntity("trip-1", 1_785_690_960_000L)
        org.junit.Assert.assertNull(entity.startSoc)
        org.junit.Assert.assertNull(entity.endSoc)
        org.junit.Assert.assertNull(entity.startVoltage)
        org.junit.Assert.assertNull(entity.endVoltage)
    }

    @Test
    fun `stored minutes combine with swept ones`() {
        val start = 1_785_690_900_000L
        val stored = IntervalEntity(
            sessionId = "trip-1",
            startUtcMillis = start,
            tractionWh = 100.0,
            regenWh = 10.0,
            auxiliaryWh = 5.0,
            climateWh = 2.0,
            deliveredWh = 0.0,
            distanceKm = 0.5,
            coveredSeconds = 30.0,
            climateCoveredSeconds = 30.0,
            updatedAtUtcMillis = start
        ).toEnergyBucket()

        val swept = EnergyBucket(
            startUtcMillis = start,
            tractionWh = 50.0,
            regeneratedWh = 4.0,
            auxiliaryWh = 3.0,
            integratedSeconds = 20.0,
            speedDistanceKm = 0.25
        )

        val combined = EnergyBucketAccumulator
            .combine(listOf(listOf(stored), listOf(swept)))
            .single()

        assertEquals(150.0, combined.tractionWh, 1e-9)
        assertEquals(14.0, combined.regeneratedWh, 1e-9)
        assertEquals(8.0, combined.auxiliaryWh, 1e-9)
        assertEquals(50.0, combined.integratedSeconds, 1e-9)
    }
}
