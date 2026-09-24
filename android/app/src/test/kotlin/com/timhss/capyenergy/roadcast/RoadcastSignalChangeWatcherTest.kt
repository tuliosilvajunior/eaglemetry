package com.timhss.capyenergy.roadcast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class RoadcastSignalChangeWatcherTest {
    @Test
    fun completesOnlyForTheFirstValidChangeAfterItsBaseline() {
        val watcher = RoadcastSignalChangeWatcher()
        val watch = watcher.watch("fob", baselineChangeNanos = 100L, openedAtElapsedNanos = 110L)

        assertEquals(RoadcastSignalChangeWatcher.Result.Pending, watcher.poll(watch, snapshot(120L, 100L)))

        val result = watcher.poll(watch, snapshot(130L, 130L))
        assertEquals(0L, (result as RoadcastSignalChangeWatcher.Result.Changed).sample.raw)
        assertTrue(watcher.status(watch, 140L)?.active == false)
        assertEquals("CHANGED", watcher.status(watch, 140L)?.result)
    }

    @Test
    fun reportsTimeoutWhenNoNewChangeArrives() {
        val watcher = RoadcastSignalChangeWatcher(defaultTimeoutNanos = 10L)
        val watch = watcher.watch("fob", baselineChangeNanos = 100L, openedAtElapsedNanos = 110L)

        assertEquals(RoadcastSignalChangeWatcher.Result.TimedOut, watcher.poll(watch, snapshot(121L, 100L)))
    }

    @Test
    fun assignsUniqueWatchesWhenUsedConcurrently() {
        val watcher = RoadcastSignalChangeWatcher()
        val workers = 8
        val watchesPerWorker = 1_000
        val executor = Executors.newFixedThreadPool(workers)
        val start = CountDownLatch(1)
        try {
            val futures = List(workers) {
                executor.submit(Callable {
                    start.await()
                    List(watchesPerWorker) {
                        watcher.watch("fob", baselineChangeNanos = 100L, openedAtElapsedNanos = 110L)
                    }
                })
            }
            start.countDown()
            val watches = futures.flatMap { it.get() }

            assertEquals(workers * watchesPerWorker, watches.map { it.id }.toSet().size)
        } finally {
            executor.shutdownNow()
        }
    }

    private fun snapshot(receivedAt: Long, changedAt: Long) = RoadcastSnapshot(
        sampleSequence = receivedAt,
        receivedAtElapsedNanos = receivedAt,
        sampleAgeNanos = 0L,
        samples = mapOf("fob" to RoadcastSample(0L, 0.0, true, false, changedAt)),
        missingSignals = emptySet(),
    )
}
