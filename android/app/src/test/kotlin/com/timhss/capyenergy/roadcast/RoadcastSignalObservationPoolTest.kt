package com.timhss.capyenergy.roadcast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class RoadcastSignalObservationPoolTest {
    @Test
    fun capturesOnlyObservationsMadeInsideEachWindow() {
        val pool = RoadcastSignalObservationPool()
        val fobWindow = pool.open(setOf("fob"), openedAtElapsedNanos = 100L, durationNanos = 30L)
        val batteryWindow = pool.open(setOf("voltage"), openedAtElapsedNanos = 100L, durationNanos = 30L)

        pool.observe(snapshot(110L, "fob" to sample(raw = 1L, changedAt = 99L)))
        pool.observe(snapshot(120L, "fob" to sample(raw = 0L, changedAt = 120L)))
        pool.observe(snapshot(125L, "fob" to sample(raw = 1L, changedAt = 125L)))
        pool.observe(snapshot(120L, "voltage" to sample(raw = 400L, changedAt = 120L)))

        assertEquals(1L, pool.sample(fobWindow, "fob", 125L)?.raw)
        assertEquals(listOf(0L, 1L), pool.changes(fobWindow, "fob", 125L).map { it.raw })
        assertEquals(400L, pool.sample(batteryWindow, "voltage", 120L)?.raw)
        assertNull(pool.sample(fobWindow, "voltage", 120L))
    }

    @Test
    fun assignsUniqueWindowsWhenUsedConcurrently() {
        val pool = RoadcastSignalObservationPool()
        val workers = 8
        val opensPerWorker = 1_000
        val executor = Executors.newFixedThreadPool(workers)
        val start = CountDownLatch(1)
        try {
            val futures = List(workers) {
                executor.submit(Callable {
                    start.await()
                    List(opensPerWorker) {
                        pool.open(setOf("fob"), openedAtElapsedNanos = 100L, durationNanos = 30L)
                    }
                })
            }
            start.countDown()
            val windows = futures.flatMap { it.get() }

            assertEquals(workers * opensPerWorker, windows.map { it.id }.toSet().size)
        } finally {
            executor.shutdownNow()
        }
    }

    private fun snapshot(timestampNanos: Long, vararg samples: Pair<String, RoadcastSample>) = RoadcastSnapshot(
        sampleSequence = timestampNanos,
        receivedAtElapsedNanos = timestampNanos,
        sampleAgeNanos = 0L,
        samples = mapOf(*samples),
        missingSignals = emptySet(),
    )

    private fun sample(raw: Long, changedAt: Long) = RoadcastSample(
        raw = raw,
        physical = raw.toDouble(),
        valid = true,
        calibrated = false,
        lastChangeNanos = changedAt,
    )
}
