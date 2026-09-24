package com.timhss.capyenergy.telemetry

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin half of the shared annotation-convergence fixture.
 *
 * The same cases run against `annotationShouldReplace` in Dart
 * (`test/annotation_convergence_test.dart` and
 * `apps/companion/test/annotation_convergence_fixture_test.dart`), so a rule
 * that moved in one language fails the other suite.
 *
 * Additional tests in this file cover the three step-6c invariants:
 * clock-skew (via the shared fixture), late-arrival, and permutation.
 * The permutation test is regression scaffolding only — the investigation
 * proved it is a tautology against this LWW rule and cannot find a bug.
 * It locks the invariant that any order converges to the same winner.
 */
class AnnotationConvergenceTest {

    @Test
    fun fixtureCasesMatch() {
        val cases = fixture().getJSONArray("cases")
        assert(cases.length() > 0) { "the fixture must hold cases" }
        for (i in 0 until cases.length()) {
            val input = cases.getJSONObject(i)
            val name = input.getString("name")
            val existing = input.getJSONObject("existing")
            val incoming = input.getJSONObject("incoming")
            val expectedWinner = input.getString("winner")

            fun hlcMillis(obj: JSONObject): Long =
                if (obj.has("hlcMillis")) obj.getLong("hlcMillis")
                else if (obj.has("hlc") && obj.getJSONObject("hlc").has("millis")) obj.getJSONObject("hlc").getLong("millis")
                else obj.getLong("updatedAtUtcMillis")

            fun hlcCounter(obj: JSONObject): Int =
                if (obj.has("hlcCounter")) obj.getInt("hlcCounter")
                else if (obj.has("hlc") && obj.getJSONObject("hlc").has("counter")) obj.getJSONObject("hlc").getInt("counter")
                else 0

            fun hlcDeviceId(obj: JSONObject): String =
                if (obj.has("hlcDeviceId")) obj.getString("hlcDeviceId")
                else if (obj.has("hlc") && obj.getJSONObject("hlc").has("deviceId")) obj.getJSONObject("hlc").getString("deviceId")
                else obj.optString("origin", "")

            val replace = AnnotationConvergence.shouldReplace(
                existingHlcMillis = hlcMillis(existing),
                existingHlcCounter = hlcCounter(existing),
                existingHlcDeviceId = hlcDeviceId(existing),
                existingOrigin = existing.optString("origin").ifEmpty { null },
                incomingHlcMillis = hlcMillis(incoming),
                incomingHlcCounter = hlcCounter(incoming),
                incomingHlcDeviceId = hlcDeviceId(incoming),
                incomingOrigin = incoming.optString("origin").ifEmpty { null }
            )

            val actualWinner = if (replace) "incoming" else "existing"
            assertEquals("$name: $expectedWinner expected", expectedWinner, actualWinner)
        }
    }

    @Test
    fun lateArrival_threeWeekOfflineStaleLoses() {
        // Simulate a device offline for three weeks (21 days = 1_814_400_000 ms).
        // A phone made intervening edits; the car reconnects with a stale row.
        // The stale edit must NOT overwrite the newer winning edit, whichever
        // arrival order the merge sees it in.
        val threeWeeksMs = 21L * 24 * 3600 * 1000
        val staleMillis = 1_708_185_600_000L // arbitrary base stale
        val freshMillis = staleMillis + threeWeeksMs + 5_000L
        val staleHlc = AnnotationHlc(millis = staleMillis, counter = 0, deviceId = "car")
        val freshHlc = AnnotationHlc(millis = freshMillis, counter = 5, deviceId = "phone")

        // Stale arriving second loses (existing = fresh, incoming = stale)
        assertFalse(
            "stale car edit arriving late must not overwrite fresh phone edit",
            AnnotationConvergence.shouldReplace(
                existingHlc = freshHlc, existingOrigin = "phone",
                incomingHlc = staleHlc, incomingOrigin = "car"
            )
        )
        // Fresh arriving second wins (existing = stale, incoming = fresh)
        assertTrue(
            "fresh phone edit must win over three-week stale car row",
            AnnotationConvergence.shouldReplace(
                existingHlc = staleHlc, existingOrigin = "car",
                incomingHlc = freshHlc, incomingOrigin = "phone"
            )
        )
        // Also verify via millis/counter/deviceId overload
        assertFalse(
            AnnotationConvergence.shouldReplace(
                existingHlcMillis = freshMillis, existingHlcCounter = 5, existingHlcDeviceId = "phone", existingOrigin = "phone",
                incomingHlcMillis = staleMillis, incomingHlcCounter = 0, incomingHlcDeviceId = "car", incomingOrigin = "car"
            )
        )
    }

    @Test
    fun permutation_shuffledOrdersConverge_regressionScaffoldingOnly() {
        // Regression scaffolding only: LWW over a deterministic total order
        // (HLC millis -> counter -> deviceId, plus ADR 0009 auto_name variant
        // with originRank) is tautologically convergent. Locked so a future
        // regression to the total-order property would be caught.
        data class Row(val id: String, val hlc: AnnotationHlc, val origin: String?, val value: String)

        val rows = listOf(
            Row("p1", AnnotationHlc(1000L, 0, "car"), "car", "a"),
            Row("p1", AnnotationHlc(2000L, 0, "phone"), "phone", "b"),
            Row("p1", AnnotationHlc(2000L, 1, "phone"), "phone", "c"),
            Row("p1", AnnotationHlc(3000L, 0, "car"), "car", "d")
        )
        // The expected winner is the maximal HLC (3000,0,car) i.e. "d"
        val expectedWinner = "d"

        fun applyInOrder(order: List<Row>): String? {
            var store: Row? = null
            for (w in order) {
                val existing = store
                if (existing == null) {
                    store = w
                } else if (AnnotationConvergence.shouldReplace(
                        existingHlc = existing.hlc, existingOrigin = existing.origin,
                        incomingHlc = w.hlc, incomingOrigin = w.origin
                    )
                ) {
                    store = w
                }
            }
            return store?.value
        }

        // Exhaustively check all 24 permutations of 4 writes.
        val perms = permutations(rows)
        assertEquals(24, perms.size)
        for (perm in perms) {
            assertEquals("every permutation must converge to $expectedWinner", expectedWinner, applyInOrder(perm))
        }

        // Also check with deviceId tie-break permutations (H-1: origin rank removed, deviceId lexicographic decides).
        val tieRows = listOf(
            Row("p1", AnnotationHlc(5000L, 0, "phone"), "phone", "phone"),
            Row("p1", AnnotationHlc(5000L, 0, "car"), "car", "car"),
            Row("p1", AnnotationHlc(5000L, 0, "cloud"), "cloud", "cloud")
        )
        val tiePerms = permutations(tieRows)
        for (perm in tiePerms) {
            // "phone" > "cloud" > "car" lexicographically, so winner must be "phone" after H-1
            assertEquals("tie-break must converge to phone (lexicographically max deviceId)", "phone", applyInOrder(perm))
        }

        // ADR 0009: auto_name keeps origin-rank tie-break (car > phone > cloud)
        val autoNameTieRows = listOf(
            Row("p1", AnnotationHlc(5000L, 0, "phone"), "phone", "phone"),
            Row("p1", AnnotationHlc(5000L, 0, "car"), "car", "car"),
            Row("p1", AnnotationHlc(5000L, 0, "cloud"), "cloud", "cloud")
        )
        fun applyAutoNameInOrder(order: List<Row>): String? {
            var store: Row? = null
            for (w in order) {
                val existing = store
                if (existing == null) {
                    store = w
                } else if (AnnotationConvergence.shouldReplaceWithOriginRank(
                        existingHlc = existing.hlc, existingOrigin = existing.origin,
                        incomingHlc = w.hlc, incomingOrigin = w.origin
                    )
                ) {
                    store = w
                }
            }
            return store?.value
        }
        val autoPerms = permutations(autoNameTieRows)
        for (perm in autoPerms) {
            assertEquals("auto_name tie-break must converge to car (origin rank)", "car", applyAutoNameInOrder(perm))
        }
    }

    private fun <T> permutations(list: List<T>): List<List<T>> {
        if (list.size <= 1) return listOf(list)
        val result = mutableListOf<List<T>>()
        for (i in list.indices) {
            val head = list[i]
            val tail = list.filterIndexed { idx, _ -> idx != i }
            for (perm in permutations(tail)) {
                result.add(listOf(head) + perm)
            }
        }
        return result
    }

    private fun fixture(): JSONObject {
        val testdataRoot = System.getProperty("geely.testdata")
        val userDir = System.getProperty("user.dir") ?: "."
        val candidates = listOfNotNull(
            testdataRoot?.let { File(it, "annotation_convergence_cases.json") },
            File(userDir, "testdata/annotation_convergence_cases.json"),
            File(userDir, "../testdata/annotation_convergence_cases.json"),
            File(userDir, "src/test/resources/annotation_convergence_cases.json"),
            File(userDir, "app/src/test/resources/annotation_convergence_cases.json")
        )
        val file = candidates.firstOrNull { it.isFile }
        val content = if (file != null) {
            file.readText(Charsets.UTF_8)
        } else {
            val stream = javaClass.classLoader?.getResourceAsStream("annotation_convergence_cases.json")
            checkNotNull(stream) {
                "annotation_convergence_cases.json fixture not found in candidates ${candidates.map { it.absolutePath }}"
            }.bufferedReader(Charsets.UTF_8).use { it.readText() }
        }
        return JSONObject(content)
    }
}