package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionAggregateSampleRow
import com.timhss.capyenergy.telemetry.db.SessionEntity
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntervalFixtureTest {
    private val cases: JSONArray = loadCases()

    @Test
    fun `the fixture carries all expected interval test cases`() {
        assertEquals(5, cases.length())
    }

    @Test
    fun `every interval fixture case folds to the expected rollup`() {
        val tolerance = fixture().getDouble("toleranceWh")

        for (index in 0 until cases.length()) {
            val testCase = cases.getJSONObject(index)
            val name = testCase.getString("name")
            val expected = testCase.getJSONObject("expected")

            val intervals = intervalsOf(testCase)
            val rollup = intervals.rollup()

            assertEquals("$name: tractionWh", expected.getDouble("tractionWh"), rollup.tractionWh, tolerance)
            assertEquals("$name: regeneratedWh", expected.getDouble("regeneratedWh"), rollup.regeneratedWh, tolerance)
            assertEquals("$name: auxiliaryWh", expected.getDouble("auxiliaryWh"), rollup.auxiliaryWh, tolerance)
            assertEquals("$name: climateWh", expected.getDouble("climateWh"), rollup.climateWh, tolerance)
            assertEquals("$name: deliveredWh", expected.optDouble("deliveredWh", 0.0), rollup.deliveredWh, tolerance)
            assertEquals("$name: netPackWh", expected.getDouble("netPackWh"), rollup.netPackWh, tolerance)
            assertEquals("$name: integratedSeconds", expected.getDouble("integratedSeconds"), rollup.integratedSeconds, tolerance)
            assertEquals("$name: distanceKm", expected.getDouble("distanceKm"), rollup.distanceKm, tolerance)

            assertCloseOrNull("$name: efficiencyWhPerKm", expected.optDoubleOrNull("efficiencyWhPerKm"), rollup.efficiencyWhPerKm, tolerance)
            assertCloseOrNull("$name: kmPerKwh", expected.optDoubleOrNull("kmPerKwh"), rollup.kmPerKwh, tolerance)
            assertCloseOrNull("$name: regenerationRatio", expected.optDoubleOrNull("regenerationRatio"), rollup.regenerationRatio, tolerance)
        }
    }

    @Test
    fun `a trip session total equals the sum of its minutes`() {
        val samples = (1L..600L).map { second ->
            val driveKw = if (second in 200L..280L) -18.0 else 24.0
            sample(
                second = second,
                voltageV = 400.0,
                currentA = driveKw * 1_000.0 / 400.0 + 5.0,
                driveKw = driveKw
            )
        }

        val session = TripPowerAccumulator().also { samples.forEach(it::add) }.result()!!
        val minutes = EnergyBucketAccumulator().also { samples.forEach(it::add) }
            .result()
            .map { it.toEntity("trip-invariant", updatedAtUtcMillis = 0L) }

        assertTrue("the series must span more than one minute", minutes.size > 1)
        val folded = minutes.rollup()

        assertEquals(session.tractionWh, folded.tractionWh, 1e-6)
        assertEquals(session.regeneratedWh, folded.regeneratedWh, 1e-6)
        assertEquals(session.auxiliaryWh, folded.auxiliaryWh, 1e-6)
        assertEquals(session.packWh, folded.netPackWh, 1e-6)
        assertEquals(session.integratedSeconds, folded.integratedSeconds, 1e-6)
    }

    @Test
    fun `a charge session delivered total equals the sum of its minutes`() {
        val samples = (1L..600L).map { second ->
            sample(
                second = second,
                voltageV = 400.0,
                currentA = -17.5, // 7 kW charging (-7000 W)
                driveKw = 0.0
            )
        }

        val accumulator = EnergyBucketAccumulator(deliveredOnly = true).also { samples.forEach(it::add) }
        val minutes = accumulator.result().map { it.toEntity("charge-invariant", updatedAtUtcMillis = 0L) }
        val folded = minutes.rollup()

        val expectedDeliveredWh = 7000.0 * (599.0 / 3600.0)
        assertEquals(expectedDeliveredWh, folded.deliveredWh, 1.0)
    }

    private fun sample(
        second: Long,
        voltageV: Double,
        currentA: Double,
        driveKw: Double
    ) = SessionAggregateSampleRow(
        elapsedRealtimeNanos = second * 1_000_000_000L,
        wallTimeUtcMillis = 1_750_000_000_000L + second * 1_000L,
        speedKmh = null,
        socPercent = null,
        odometerKm = null,
        voltageV = null,
        currentA = null,
        powerKw = null,
        freshnessMask = 0,
        canDrivePowerKw = driveKw.toFloat(),
        canPackVoltageV = voltageV.toFloat(),
        canPackCurrentA = currentA.toFloat()
    )

    private fun intervalsOf(testCase: JSONObject): List<IntervalEntity> {
        val array = testCase.getJSONArray("intervals")
        return (0 until array.length()).map { i ->
            val obj = array.getJSONObject(i)
            IntervalEntity(
                sessionId = obj.getString("sessionId"),
                startUtcMillis = obj.getLong("startUtcMillis"),
                tractionWh = obj.getDouble("tractionWh"),
                regenWh = obj.getDouble("regeneratedWh"),
                auxiliaryWh = obj.getDouble("auxiliaryWh"),
                climateWh = obj.getDouble("climateWh"),
                deliveredWh = obj.optDouble("deliveredWh", 0.0),
                distanceKm = obj.getDouble("speedDistanceKm"),
                coveredSeconds = obj.getDouble("integratedSeconds"),
                climateCoveredSeconds = obj.getDouble("climateIntegratedSeconds"),
                startSoc = obj.optDoubleOrNull("startSoc"),
                endSoc = obj.optDoubleOrNull("endSoc"),
                updatedAtUtcMillis = obj.getLong("startUtcMillis") + 60000L
            )
        }
    }

    private fun assertCloseOrNull(label: String, expected: Double?, actual: Double?, tolerance: Double) {
        if (expected == null) {
            assertNull("$label must be null", actual)
        } else {
            assertNotNull("$label must not be null", actual)
            assertEquals(label, expected, actual!!, tolerance)
        }
    }

    private fun JSONObject.optDoubleOrNull(name: String): Double? {
        if (isNull(name)) return null
        return getDouble(name)
    }

    private fun fixture(): JSONObject {
        val testdataRoot = System.getProperty("geely.testdata")
        val userDir = System.getProperty("user.dir") ?: "."
        val candidates = listOfNotNull(
            testdataRoot?.let { File(it, "interval_cases.json") },
            File(userDir, "testdata/interval_cases.json"),
            File(userDir, "../testdata/interval_cases.json"),
            File(userDir, "src/test/resources/interval_cases.json"),
            File(userDir, "app/src/test/resources/interval_cases.json")
        )
        val file = candidates.firstOrNull { it.isFile }
        val content = if (file != null) {
            file.readText(Charsets.UTF_8)
        } else {
            val stream = javaClass.classLoader?.getResourceAsStream("interval_cases.json")
            checkNotNull(stream) {
                "interval_cases.json fixture not found in candidates ${candidates.map { it.absolutePath }}"
            }.bufferedReader(Charsets.UTF_8).use { it.readText() }
        }
        return JSONObject(content)
    }

    private fun loadCases(): JSONArray = fixture().getJSONArray("cases")
}
