package com.timhss.capyenergy.telemetry

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin half of the shared preference-lane classification fixture.
 *
 * The same catalogue runs against `kPreferenceLane` in Dart
 * (`test/preference_lane_classification_test.dart` and
 * `apps/companion/test/preference_lane_classification_test.dart`), so a key
 * classified one way in one language fails this suite, and a key registered
 * in only one registry is caught by the fixture's exact-equality assertion.
 *
 * The rule being pinned — issue #227, Lane C: if it changes what the car does
 * or records, it is control; if it only changes what a screen shows, it is
 * annotation.
 */
class PreferenceLaneClassificationTest {

    @Test
    fun `registry matches the shared fixture exactly`() {
        val lanes = fixture().getJSONObject("lanes")
        val expected = HashMap<String, String>()
        for (key in lanes.keys()) expected[key] = lanes.getString(key)

        assertEquals("every kitchen-sink fixture key is registered", expected.keys, PreferenceRepository.PREFERENCE_LANE.keys)
        for ((key, classification) in expected) {
            assertEquals(
                "$key must classify as $classification in Kotlin",
                classification.toLane(),
                PreferenceRepository.PREFERENCE_LANE[key]
            )
        }
    }

    @Test
    fun `classification honors the mechanical rule`() {
        // The only keys that change what the car records.
        assertEquals(
            setOf("pack_capacity_wh", "default_charge_cost_per_kwh"),
            PreferenceRepository.CONTROL_KEYS
        )
        // A registry with no control keys would be suspicious; the fixture
        // asserted exact equality, this is the guard that the derived set and
        // the map did not drift apart.
        assertEquals(
            PreferenceRepository.PREFERENCE_LANE.filterValues { it == PreferenceLane.CONTROL }.keys.toSet(),
            PreferenceRepository.CONTROL_KEYS
        )
    }

    @Test
    fun `the annotation channel never carries control keys`() {
        // The synced-keys whitelist is the lane B channel; every key on it
        // must classify as annotation, or a control write could reach the car
        // through the annotation merge path.
        assertTrue(
            PreferenceRepository.SYNCED_KEYS.keys.all { PreferenceRepository.PREFERENCE_LANE[it] == PreferenceLane.ANNOTATION }
        )
    }

    private fun String.toLane(): PreferenceLane = when (this) {
        "annotation" -> PreferenceLane.ANNOTATION
        "control" -> PreferenceLane.CONTROL
        else -> error("unknown lane in fixture: $this")
    }

    private fun fixture(): JSONObject {
        val testdataRoot = System.getProperty("geely.testdata")
        val userDir = System.getProperty("user.dir") ?: "."
        val candidates = listOfNotNull(
            testdataRoot?.let { File(it, "preference_lanes.json") },
            File(userDir, "testdata/preference_lanes.json"),
            File(userDir, "../testdata/preference_lanes.json"),
            File(userDir, "src/test/resources/preference_lanes.json"),
            File(userDir, "app/src/test/resources/preference_lanes.json")
        )
        val file = candidates.firstOrNull { it.isFile }
        val content = if (file != null) {
            file.readText(Charsets.UTF_8)
        } else {
            val stream = javaClass.classLoader?.getResourceAsStream("preference_lanes.json")
            checkNotNull(stream) {
                "preference_lanes.json fixture not found in candidates ${candidates.map { it.absolutePath }}"
            }.bufferedReader(Charsets.UTF_8).use { it.readText() }
        }
        return JSONObject(content)
    }
}