package com.timhss.capyenergy.telemetry

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ObservedWriteExecutorTest {
    @Test
    fun `reports backlog and commit latency without changing fifo order`() {
        val executor = ObservedWriteExecutor("test")
        val firstStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val order = mutableListOf<Int>()

        executor.executeWrite("first", acceptedElapsedNanos = 10L) {
            firstStarted.countDown()
            releaseFirst.await(2, TimeUnit.SECONDS)
            synchronized(order) { order.add(1) }
        }
        assertTrue(firstStarted.await(2, TimeUnit.SECONDS))
        executor.executeWrite("second", acceptedElapsedNanos = 20L) {
            synchronized(order) { order.add(2) }
        }

        assertEquals(1, executor.statusMap()["queueDepth"])
        assertTrue((executor.statusMap()["queueHighWatermark"] as Int) >= 1)
        releaseFirst.countDown()
        executor.awaitIdle()

        assertEquals(listOf(1, 2), order)
        assertEquals(2L, executor.statusMap()["acceptedWrites"])
        assertEquals(2L, executor.statusMap()["committedWrites"])
        assertEquals(0L, executor.statusMap()["failedWrites"])
        assertEquals(20L, executor.statusMap()["lastCommittedElapsedNanos"])
    }

    /**
     * The shape retention now uses: one chunk per queue slot rather than a whole
     * sweep on the caller's thread. What matters is that a live write accepted
     * while a chunk is running goes in *between* chunks, so it waits for one chunk
     * and not for the whole run.
     */
    @Test
    fun `chunked maintenance work lets a live write in between chunks`() {
        val executor = ObservedWriteExecutor("test")
        val order = mutableListOf<String>()
        val firstChunkRunning = CountDownLatch(1)
        val liveWriteAccepted = CountDownLatch(1)

        val maintenance = Executors.newSingleThreadExecutor()
        val run = maintenance.submit {
            repeat(3) { chunk ->
                executor.call("delete_chunk", trackAsWrite = true) {
                    synchronized(order) { order.add("chunk$chunk") }
                    if (chunk == 0) {
                        firstChunkRunning.countDown()
                        // Hold the first chunk only until the live write is queued.
                        liveWriteAccepted.await(2, TimeUnit.SECONDS)
                    }
                }
            }
        }

        assertTrue(firstChunkRunning.await(2, TimeUnit.SECONDS))
        executor.executeWrite("insert_frame_batch") {
            synchronized(order) { order.add("frames") }
        }
        liveWriteAccepted.countDown()

        run.get(2, TimeUnit.SECONDS)
        executor.awaitIdle()
        assertEquals(listOf("chunk0", "frames", "chunk1", "chunk2"), order)
        maintenance.shutdownNow()
    }

    @Test
    fun `records asynchronous write failure and remains usable`() {
        val executor = ObservedWriteExecutor("test")
        executor.executeWrite("broken") { throw IOException("disk full") }
        executor.awaitIdle()

        assertEquals(1L, executor.statusMap()["failedWrites"])
        assertNotNull(executor.statusMap()["lastErrorUtcMillis"])
        assertTrue(executor.statusMap()["lastError"].toString().contains("disk full"))

        executor.executeWrite("recovery") { }
        executor.awaitIdle()
        assertEquals(1L, executor.statusMap()["committedWrites"])
    }

    @Test
    fun `bounded queue drops only writes using drop policy`() {
        val executor = ObservedWriteExecutor("test", queueCapacity = 1)
        val firstStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        executor.executeWrite("running") {
            firstStarted.countDown()
            releaseFirst.await(2, TimeUnit.SECONDS)
        }
        assertTrue(firstStarted.await(2, TimeUnit.SECONDS))
        assertTrue(executor.executeWrite("queued") { })

        val accepted = executor.executeWrite(
            operation = "overflow",
            overflowPolicy = ObservedWriteExecutor.OverflowPolicy.DROP_NEWEST
        ) { }

        assertFalse(accepted)
        assertEquals(1L, executor.statusMap()["droppedWrites"])
        assertEquals(1, executor.statusMap()["queueCapacity"])
        releaseFirst.countDown()
        executor.awaitIdle()
    }

    @Test
    fun `critical write waits for bounded capacity instead of dropping`() {
        val executor = ObservedWriteExecutor("test", queueCapacity = 1)
        val firstStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        executor.executeWrite("running") {
            firstStarted.countDown()
            releaseFirst.await(2, TimeUnit.SECONDS)
        }
        assertTrue(firstStarted.await(2, TimeUnit.SECONDS))
        executor.executeWrite("queued") { }

        val caller = Executors.newSingleThreadExecutor()
        val critical = caller.submit<Boolean> {
            executor.executeWrite(
                operation = "critical",
                overflowPolicy = ObservedWriteExecutor.OverflowPolicy.BLOCK
            ) { }
        }
        Thread.sleep(25L)
        assertFalse(critical.isDone)

        releaseFirst.countDown()
        assertTrue(critical.get(2, TimeUnit.SECONDS))
        executor.awaitIdle()
        assertEquals(0L, executor.statusMap()["droppedWrites"])
        caller.shutdownNow()
    }
}
