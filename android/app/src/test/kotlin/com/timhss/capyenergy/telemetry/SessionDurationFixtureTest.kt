package com.timhss.capyenergy.telemetry

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Drives the Kotlin half of the canonical session duration from the shared
 * fixture.
 *
 * `test/session_duration_fixture_test.dart` drives the Dart half from the same
 * file. The expected values were derived by hand from the rule, so a failure
 * here is a statement about the rule rather than about which language moved
 * first.
 *
 * The rule exists twice because the duration is derived and never stored. This
 * side derives it in the repository that answers Flutter; the phone has to
 * derive it from the synced row, which carries the endpoints alone and is why
 * every drive read as `--` there until it did.
 *
 * The fixture path arrives as the `geely.testdata` system property, set in
 * `android/app/build.gradle.kts`.
 */
class SessionDurationFixtureTest {

    @Test
    fun `the fixture carries every case the Dart side expects`() {
        assertEquals(8, loadCases().length())
    }

    @Test
    fun `every case reconciles to the duration the fixture states`() {
        val cases = loadCases()
        for (i in 0 until cases.length()) {
            val testCase = cases.getJSONObject(i)
            val name = testCase.getString("name")
            val actual = SessionTimeReconciler.canonicalDurationMillis(
                startUtcMillis = testCase.getLong("startUtcMillis"),
                startElapsedNanos = testCase.getLong("startElapsedNanos"),
                startBootCount = testCase.optIntOrNull("startBootCount"),
                endUtcMillis = testCase.getLong("endUtcMillis"),
                endElapsedNanos = testCase.getLong("endElapsedNanos"),
                endBootCount = testCase.optIntOrNull("endBootCount"),
                maxWallDurationMillis = testCase.getLong("maxWallDurationMillis")
            )
            val expected = testCase.optLongOrNull("expected")
            assertEquals("$name: ${testCase.getString("why")}", expected, actual)
        }
    }

    private fun JSONObject.optIntOrNull(key: String): Int? =
        if (!has(key) || isNull(key)) null else getInt(key)

    private fun JSONObject.optLongOrNull(key: String): Long? =
        if (!has(key) || isNull(key)) null else getLong(key)

    private fun loadCases(): JSONArray = fixture().getJSONArray("cases")

    private fun fixture(): JSONObject {
        val root = requireNotNull(System.getProperty("geely.testdata")) {
            "geely.testdata is unset; see the Test task in android/app/build.gradle.kts"
        }
        val file = File(root, FIXTURE_NAME)
        require(file.isFile) { "The shared fixture is missing at ${file.absolutePath}" }
        return JSONObject(file.readText())
    }

    private companion object {
        const val FIXTURE_NAME = "session_duration_cases.json"
    }
}
