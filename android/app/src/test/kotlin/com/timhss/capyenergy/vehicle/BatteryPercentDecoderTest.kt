package com.timhss.capyenergy.vehicle

import com.timhss.capyenergy.profile.GeelyProfile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BatteryPercentDecoderTest {

    private val configuredCapacityWh = GeelyProfile.battery.defaultCapacityWh.toFloat()

    @Test
    fun `prefers the vendor percentage over every fallback`() {
        val percent = decodeBatteryPercent(
            oemPercent = 62f,
            batteryLevel = 19_800f,
            packCapacityWh = configuredCapacityWh
        )
        assertEquals(62f, percent!!, 0.001f)
    }

    @Test
    fun `reads a level under 100 as a percentage already`() {
        val percent = decodeBatteryPercent(
            oemPercent = null,
            batteryLevel = 44f,
            packCapacityWh = configuredCapacityWh
        )
        assertEquals(44f, percent!!, 0.001f)
    }

    @Test
    fun `divides an absolute level by the configured capacity`() {
        val percent = decodeBatteryPercent(
            oemPercent = null,
            batteryLevel = 19_800f,
            packCapacityWh = 39_600f
        )
        assertEquals(50f, percent!!, 0.001f)
    }

    /**
     * The defect this route used to have: the car answers
     * `INFO_EV_BATTERY_CAPACITY` with 150 000 Wh, and a full pack divided by it
     * read 26 %. The property is no longer read, so the reading follows the
     * pack the reader stated.
     */
    @Test
    fun `follows the stated pack, whatever the car says`() {
        val percent = decodeBatteryPercent(
            oemPercent = null,
            batteryLevel = 39_600f,
            packCapacityWh = 39_600f
        )
        assertEquals(100f, percent!!, 0.001f)

        // A bigger pack, stated by the reader of another car.
        val bigger = decodeBatteryPercent(
            oemPercent = null,
            batteryLevel = 39_600f,
            packCapacityWh = 79_200f
        )
        assertEquals(50f, bigger!!, 0.001f)
    }

    @Test
    fun `answers nothing when no property could be read`() {
        assertNull(decodeBatteryPercent(null, null, configuredCapacityWh))
        assertNull(decodeBatteryPercent(null, Float.NaN, configuredCapacityWh))
    }

    @Test
    fun `answers nothing when the capacity cannot divide`() {
        assertNull(decodeBatteryPercent(null, 19_800f, 0f))
        assertNull(decodeBatteryPercent(null, 19_800f, Float.NaN))
    }

    @Test
    fun `never leaves the zero to one hundred range`() {
        val over = decodeBatteryPercent(null, 60_000f, 39_600f)
        assertEquals(100f, over!!, 0.001f)

        val negative = decodeBatteryPercent(-5f, -5f, configuredCapacityWh)
        assertNull(negative)
    }
}
