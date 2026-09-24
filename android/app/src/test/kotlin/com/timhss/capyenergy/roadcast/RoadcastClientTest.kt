package com.timhss.capyenergy.roadcast

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoadcastClientTest {
    @Test
    fun schemaFlagsComeFromRoadcastMetadata() {
        val entry = RoadcastSchemaEntry(
            stableId = 1,
            index = 0,
            invalidSignalIndex = null,
            canId = 0x315,
            kind = 2,
            source = 1,
            width = 12,
            flags = 0x02,
            scale = 0.1,
            offset = -204.8,
            name = "VCU_DrvPwrAct",
            unit = "kW"
        )

        assertTrue(entry.calibrated)
        assertFalse(entry.signed)
    }
}
