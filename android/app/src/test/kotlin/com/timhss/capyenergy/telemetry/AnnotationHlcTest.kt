package com.timhss.capyenergy.telemetry

import org.junit.Assert.*
import org.junit.Test

class AnnotationHlcTest {
    @Test
    fun `local tick increments counter on same millis`() {
        val clock = AnnotationHlcClock("car", nowMillis = { 5000000L })
        val t1 = clock.tickAt(5000000L)
        assertEquals(5000000L, t1.millis)
        assertEquals(0, t1.counter)
        assertEquals("car", t1.deviceId)

        val t2 = clock.tickAt(5000000L)
        assertEquals(5000000L, t2.millis)
        assertEquals(1, t2.counter)
        assertEquals("car", t2.deviceId)

        val t3 = clock.tickAt(5000001L)
        assertEquals(5000001L, t3.millis)
        assertEquals(0, t3.counter)
    }

    @Test
    fun `remote merge advances clock beyond remote`() {
        val clock = AnnotationHlcClock("car", nowMillis = { 6000000L })
        // No local state yet, merge remote with future time
        val remote = AnnotationHlc(millis = 9000000L, counter = 5, deviceId = "phone")
        clock.merge(remote)
        val current = clock.currentOrNull()!!
        assertTrue(current.millis >= 9000000L)
        if (current.millis == 9000000L) {
            assertTrue(current.counter > 5)
        }
        assertEquals("car", current.deviceId)

        // Next tick should be > remote
        val next = clock.tickAt(6000000L)
        assertTrue(next.millis >= remote.millis)
        if (next.millis == remote.millis) assertTrue(next.counter > remote.counter)
    }

    @Test
    fun `HLC now decides winner despite smaller wall - slow clock later wins`() {
        // Existing has larger wall millis, incoming has larger HLC but smaller wall.
        // After 6b, HLC must decide, so incoming wins despite smaller wall.
        val existingHlc = AnnotationHlc(millis = 8000000L, counter = 0, deviceId = "car")
        val incomingHlc = AnnotationHlc(millis = 9000000L, counter = 1, deviceId = "phone")
        // Wall would have said existing wins (8000000 > 7000000 with wall 7000000), but HLC says incoming wins.
        // Use wall 7000000 for incoming to show divergence, but HLC millis is 9000000.
        val shouldReplaceHlc = AnnotationConvergence.shouldReplace(
            existingHlc = existingHlc,
            existingOrigin = "car",
            incomingHlc = incomingHlc,
            incomingOrigin = "phone"
        )
        assertTrue("HLC must decide: larger HLC wins despite smaller wall", shouldReplaceHlc)
        // Also verify wall-clock comparison would have disagreed (demonstrates bug that 6b fixed)
        val wallComparison = AnnotationConvergence.shouldReplaceWallClock(
            existingUpdatedAtUtcMillis = 8000000L,
            existingOrigin = "car",
            incomingUpdatedAtUtcMillis = 7000000L,
            incomingOrigin = "phone"
        )
        assertFalse("wall-clock would have picked existing, HLC correctly picks incoming", wallComparison)
        // Direct HLC compare also picks incoming
        val hlcComparison = AnnotationHlc.compareHlc(incomingHlc.millis, incomingHlc.counter, incomingHlc.deviceId, existingHlc.millis, existingHlc.counter, existingHlc.deviceId)
        assertTrue("HLC comparison picks incoming", hlcComparison > 0)
    }

    @Test
    fun `HLC tie uses counter then deviceId lexicographic (origin rank removed)`() {
        // Same HLC millis and counter, deviceId decides (H-1: origin rank removed)
        val shouldReplacePhoneOverCar = AnnotationConvergence.shouldReplace(
            existingHlcMillis = 5000000L,
            existingHlcCounter = 0,
            existingHlcDeviceId = "car",
            existingOrigin = "car",
            incomingHlcMillis = 5000000L,
            incomingHlcCounter = 0,
            incomingHlcDeviceId = "phone",
            incomingOrigin = "phone"
        )
        assertTrue("same HLC, phone deviceId > car deviceId => phone wins (rank removed)", shouldReplacePhoneOverCar)
        val shouldReplaceCarOverPhone = AnnotationConvergence.shouldReplace(
            existingHlcMillis = 5000000L,
            existingHlcCounter = 0,
            existingHlcDeviceId = "phone",
            existingOrigin = "phone",
            incomingHlcMillis = 5000000L,
            incomingHlcCounter = 0,
            incomingHlcDeviceId = "car",
            incomingOrigin = "car"
        )
        assertFalse("same HLC, car deviceId < phone => car loses", shouldReplaceCarOverPhone)
        // Counter decides before deviceId
        val counterWins = AnnotationConvergence.shouldReplace(
            existingHlcMillis = 5000000L,
            existingHlcCounter = 0,
            existingHlcDeviceId = "zzz",
            existingOrigin = "car",
            incomingHlcMillis = 5000000L,
            incomingHlcCounter = 1,
            incomingHlcDeviceId = "aaa",
            incomingOrigin = "phone"
        )
        assertTrue("same millis, counter 1 > 0 => incoming wins despite lexicographically smaller deviceId", counterWins)
    }

    @Test
    fun `auto_name HLC tie uses origin rank per ADR 0009`() {
        // auto_name group keeps origin rank: car > phone > cloud
        val carOverPhone = AnnotationConvergence.shouldReplaceWithOriginRank(
            existingHlcMillis = 5000000L,
            existingHlcCounter = 0,
            existingHlcDeviceId = "phone",
            existingOrigin = "phone",
            incomingHlcMillis = 5000000L,
            incomingHlcCounter = 0,
            incomingHlcDeviceId = "car",
            incomingOrigin = "car"
        )
        assertTrue("auto_name: car rank 2 > phone 1 => car wins", carOverPhone)
        val phoneOverCar = AnnotationConvergence.shouldReplaceWithOriginRank(
            existingHlcMillis = 5000000L,
            existingHlcCounter = 0,
            existingHlcDeviceId = "car",
            existingOrigin = "car",
            incomingHlcMillis = 5000000L,
            incomingHlcCounter = 0,
            incomingHlcDeviceId = "phone",
            incomingOrigin = "phone"
        )
        assertFalse("auto_name: phone rank 1 < car 2 => phone loses", phoneOverCar)
    }
}
