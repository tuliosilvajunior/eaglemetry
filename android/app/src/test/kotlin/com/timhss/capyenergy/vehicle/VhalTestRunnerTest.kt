package com.timhss.capyenergy.vehicle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VhalTestRunnerTest {
    @Test
    fun `set reports the value held before the write`() {
        val access = FakeAccess(initial = mutableMapOf(PROP to 4))
        val runner = runnerFor(access)

        val summary = runner.run(VhalTestCommand.Set(PROP, AREA, 7))

        assertEquals(listOf(7), access.writes)
        assertTrue(summary, summary.contains("result=OK"))
        assertTrue(summary, summary.contains("before=4"))
        assertTrue(summary, summary.contains("readback=7"))
    }

    @Test
    fun `set reports FAIL without inventing a readback`() {
        val access = FakeAccess(initial = mutableMapOf(PROP to 4), failWrites = true)
        val runner = runnerFor(access)

        val summary = runner.run(VhalTestCommand.Set(PROP, AREA, 7))

        assertTrue(summary, summary.contains("result=FAIL"))
        assertTrue(summary, summary.contains("readback=4"))
    }

    @Test
    fun `sweep walks the range in order and restores the original value`() {
        val access = FakeAccess(initial = mutableMapOf(PROP to 3))
        val runner = runnerFor(access)

        runner.run(VhalTestCommand.Sweep(PROP, AREA, from = 0, to = 2, delayMillis = 2_500L))

        assertEquals(listOf(0, 1, 2, 3), access.writes)
        assertEquals(3, access.readIntProperty(PROP, AREA))
    }

    @Test
    fun `sweep restores the original even when every step fails`() {
        val access = FakeAccess(initial = mutableMapOf(PROP to 3), failWrites = true)
        val runner = runnerFor(access)

        val summary = runner.run(
            VhalTestCommand.Sweep(PROP, AREA, from = 0, to = 2, delayMillis = 0L)
        )

        assertEquals(listOf(0, 1, 2, 3), access.writes)
        assertTrue(summary, summary.contains("applied=0/3"))
    }

    @Test
    fun `sweep skips restore when the original value could not be read`() {
        val access = FakeAccess(initial = mutableMapOf(), readable = false)
        val runner = runnerFor(access)

        val summary = runner.run(
            VhalTestCommand.Sweep(PROP, AREA, from = 0, to = 1, delayMillis = 0L)
        )

        assertEquals(listOf(0, 1), access.writes)
        assertTrue(summary, summary.contains("restore=SKIPPED"))
    }

    @Test
    fun `sweep honours the requested hold time between values`() {
        val access = FakeAccess(initial = mutableMapOf(PROP to 0))
        val slept = mutableListOf<Long>()
        val runner = VhalTestRunner(access, log = {}, sleeper = { slept += it })

        runner.run(VhalTestCommand.Sweep(PROP, AREA, from = 1, to = 3, delayMillis = 2_500L))

        assertEquals(listOf(2_500L, 2_500L, 2_500L), slept)
    }

    @Test
    fun `ping surfaces an unusable CarPropertyManager instead of failing silently`() {
        val unavailable = runnerFor(FakeAccess(initial = mutableMapOf(), readable = false))
        val ready = runnerFor(FakeAccess(initial = mutableMapOf(VhalTestRunner.PING_PROPERTY_ID to 4)))

        assertTrue(unavailable.run(VhalTestCommand.Ping).contains("carPropertyManager=UNAVAILABLE"))
        assertTrue(ready.run(VhalTestCommand.Ping).contains("carPropertyManager=READY"))
    }

    @Test
    fun `every command emits its summary through the log sink`() {
        val lines = mutableListOf<String>()
        val access = FakeAccess(initial = mutableMapOf(PROP to 1))
        val runner = VhalTestRunner(access, log = { lines += it }, sleeper = {})

        runner.run(VhalTestCommand.Get(PROP, AREA))
        runner.run(VhalTestCommand.Set(PROP, AREA, 2))

        assertEquals(2, lines.size)
        assertTrue(lines[0], lines[0].startsWith("cmd=get"))
        assertTrue(lines[1], lines[1].startsWith("cmd=set"))
    }

    private fun runnerFor(access: FakeAccess) =
        VhalTestRunner(access, log = {}, sleeper = {})

    private class FakeAccess(
        initial: MutableMap<Int, Int>,
        private val failWrites: Boolean = false,
        private val readable: Boolean = true,
    ) : VehiclePropertyAccess {
        val writes = mutableListOf<Int>()
        private val store = initial

        override fun readIntProperty(propertyId: Int, areaId: Int): Int? =
            if (readable) store[propertyId] else null

        override fun setIntProperty(propertyId: Int, areaId: Int, value: Int): Boolean {
            writes += value
            if (failWrites) return false
            store[propertyId] = value
            return true
        }
    }

    private companion object {
        const val PROP = 557884292
        const val AREA = 0
    }
}
