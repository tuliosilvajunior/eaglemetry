package com.timhss.capyenergy.vehicle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class VhalTestCommandTest {
    @Test
    fun `parses a set command with defaults`() {
        val command = VhalTestCommand.parse(
            VhalTestRequest(op = "set", propertyId = TURNING_DIRECTION_TYPE, value = 2)
        )

        assertEquals(
            VhalTestCommand.Set(TURNING_DIRECTION_TYPE, VhalTestCommand.DEFAULT_AREA_ID, 2),
            command
        )
    }

    @Test
    fun `accepts a hex property id because the catalogues are written in hex`() {
        val command = VhalTestCommand.parse(
            VhalTestRequest(op = "get", propertyIdHex = "0x2140a384")
        )

        assertEquals(
            VhalTestCommand.Get(TURNING_DIRECTION_TYPE, VhalTestCommand.DEFAULT_AREA_ID),
            command
        )
    }

    @Test
    fun `prefers an explicit decimal id over the hex form`() {
        val command = VhalTestCommand.parse(
            VhalTestRequest(op = "get", propertyId = 7, propertyIdHex = "0x2140a384")
        )

        assertEquals(VhalTestCommand.Get(7, VhalTestCommand.DEFAULT_AREA_ID), command)
    }

    @Test
    fun `parses a sweep with the default hold time`() {
        val command = VhalTestCommand.parse(
            VhalTestRequest(op = "sweep", propertyId = TURNING_DIRECTION_TYPE, from = 0, to = 8)
        )

        assertEquals(
            VhalTestCommand.Sweep(
                propertyId = TURNING_DIRECTION_TYPE,
                areaId = VhalTestCommand.DEFAULT_AREA_ID,
                from = 0,
                to = 8,
                delayMillis = VhalTestCommand.DEFAULT_DELAY_MILLIS,
            ),
            command
        )
    }

    @Test
    fun `parses ping and stop without a property`() {
        assertEquals(VhalTestCommand.Ping, VhalTestCommand.parse(VhalTestRequest(op = " PING ")))
        assertEquals(VhalTestCommand.Stop, VhalTestCommand.parse(VhalTestRequest(op = "stop")))
    }

    @Test
    fun `rejects a malformed command before any vehicle write`() {
        val rejected = listOf(
            VhalTestRequest(op = null),
            VhalTestRequest(op = "  "),
            VhalTestRequest(op = "launch"),
            VhalTestRequest(op = "get"),
            VhalTestRequest(op = "set", propertyId = TURNING_DIRECTION_TYPE),
            VhalTestRequest(op = "sweep", propertyId = TURNING_DIRECTION_TYPE, from = 0),
            VhalTestRequest(op = "sweep", propertyId = TURNING_DIRECTION_TYPE, from = 5, to = 1),
            VhalTestRequest(op = "get", propertyIdHex = "nothex"),
            VhalTestRequest(op = "get", propertyIdHex = "0x0"),
        )

        rejected.forEach { request ->
            assertThrows(request.toString(), IllegalArgumentException::class.java) {
                VhalTestCommand.parse(request)
            }
        }
    }

    @Test
    fun `caps sweep length so a typo cannot walk thousands of values onto the bus`() {
        val tooLong = VhalTestRequest(
            op = "sweep",
            propertyId = TURNING_DIRECTION_TYPE,
            from = 0,
            to = VhalTestCommand.MAX_SWEEP_STEPS,
        )

        assertThrows(IllegalArgumentException::class.java) { VhalTestCommand.parse(tooLong) }
    }

    @Test
    fun `caps the hold time so a sweep cannot stall the queue`() {
        val tooSlow = VhalTestRequest(
            op = "sweep",
            propertyId = TURNING_DIRECTION_TYPE,
            from = 0,
            to = 1,
            delayMillis = (VhalTestCommand.MAX_DELAY_MILLIS + 1).toInt(),
        )

        assertThrows(IllegalArgumentException::class.java) { VhalTestCommand.parse(tooSlow) }
    }

    private companion object {
        /** TURNINGDIRECTIONTYPE, 0x2140A384, routed to CAN frame 0x2A9. */
        const val TURNING_DIRECTION_TYPE = 557884292
    }
}
