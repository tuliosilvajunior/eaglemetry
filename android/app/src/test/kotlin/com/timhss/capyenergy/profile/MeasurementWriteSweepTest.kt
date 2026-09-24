package com.timhss.capyenergy.profile

import java.io.File
import org.junit.Assert.fail
import org.junit.Test

/**
 * A measurement table has no write path outside ingestion.
 *
 * A charge's price is an annotation since slice 6: a person states what they
 * paid, it is edited from the phone as well, and it syncs both directions.
 * The write surface is the `session_costs` table and nothing else — the
 * `session` cost columns are dead, the wire and the export read the
 * annotation, and this sweep proves no code writes the measurement row's
 * dead columns any more.
 *
 * The sweep is written from the case that actually shipped: the former block
 * of DAO methods that updated `session` in place (`updateCost`,
 * `applyCostToUnpriced`, `oldestUnpricedClosedStart`,
 * `latestPricedCompletedBefore`). Slice 6 deleted them, so their names must
 * not resurface anywhere in the collection or bridge layers. That is the
 * riddle the boundary is about: a price is not a session field, so no code
 * may ever reach for it as one again.
 */
class MeasurementWriteSweepTest {

    private val sweptDirectories = listOf(
        "main/kotlin/com/timhss/capyenergy/telemetry",
        "main/kotlin/com/timhss/capyenergy/service",
        "main/kotlin/com/timhss/capyenergy/helpers",
        "main/kotlin/com/timhss/capyenergy/bridge"
    )

    /**
     * The removed write surface. A sweep against these names is the sweep
     * that proves the move: they are the exact identifiers slice 6 deleted,
     * so a resurrection fails here rather than at the next pricing screen.
     *
     * `oldestUnpricedClosedStart` is deliberately absent. It moved, not
     * died: the annotation side reads it from `session_costs` to say which
     * charges are unpriced, and a read of the annotation table is exactly
     * the boundary this test exists to keep.
     */
    private val removedMeasurementWriters = listOf(
        "updateCost",
        "applyCostToUnpriced",
        "latestPricedCompletedBefore"
    )

    @Test
    fun theRemovedSessionCostWritersAreGone() {
        val violations = mutableListOf<String>()
        val sourceRoot = repoRoot()
            .resolve("android/app/src/main/kotlin/com/timhss/capyenergy")
        for (directory in sweptDirectories) {
            val root = sourceRoot.resolve(directory.substringAfterLast("capyenergy/"))
            if (!root.isDirectory) continue
            root.walkTopDown().filter { it.extension == "kt" }.forEach { file ->
                val source = file.readText()
                for (writer in removedMeasurementWriters) {
                    if (source.contains(writer)) {
                        violations += "${file.name} names $writer"
                    }
                }
            }
        }
        if (violations.isNotEmpty()) {
            fail(
                "A session cost write got back into the collection layer:\n" +
                    violations.joinToString("\n") +
                    "\nA charge is priced in its own annotation row " +
                    "(session_costs/SessionCostRepository); nothing else may " +
                    "reach the cost."
            )
        }
    }

    /** The repository root, from whichever directory Gradle runs the suite at. */
    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        while (dir.parentFile != null) {
            if (dir.resolve("android").isDirectory) return dir
            dir = dir.parentFile
        }
        return dir
    }
}