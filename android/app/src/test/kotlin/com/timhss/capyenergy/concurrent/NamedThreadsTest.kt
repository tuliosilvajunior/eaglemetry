package com.timhss.capyenergy.concurrent

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NamedThreadsTest {

    @Test
    fun `a single worker carries the bare name`() {
        val executor = namedSingleThreadExecutor("frames-db")
        try {
            assertEquals("frames-db", nameOfWorker(executor))
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `a pool numbers every thread after the first`() {
        val factory = namedThreadFactory("sync-http")
        val names = (1..3).map { factory.newThread {}.name }
        assertEquals(listOf("sync-http", "sync-http-2", "sync-http-3"), names)
    }

    @Test
    fun `a name Linux would truncate is refused`() {
        // 15 characters is the kernel limit. A 16-character name would reach
        // top and /proc as a different, shorter thread, which is the exact
        // confusion this file exists to end.
        assertEquals(15, MAX_THREAD_NAME_LENGTH)
        namedThreadFactory("roadcast-watch")
        val refused = runCatching { namedThreadFactory("roadcast-watchdog") }.exceptionOrNull()
        assertTrue(refused is IllegalArgumentException)
    }

    @Test
    fun `a blank name is refused`() {
        val refused = runCatching { namedThreadFactory("  ") }.exceptionOrNull()
        assertTrue(refused is IllegalArgumentException)
    }

    private fun nameOfWorker(executor: java.util.concurrent.ExecutorService): String {
        val latch = CountDownLatch(1)
        var name = ""
        executor.execute {
            name = Thread.currentThread().name
            latch.countDown()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        return name
    }
}
