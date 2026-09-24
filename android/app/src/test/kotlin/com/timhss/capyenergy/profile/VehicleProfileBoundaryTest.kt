package com.timhss.capyenergy.profile

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Nothing above layer 0 may name a vehicle.
 *
 * A VHAL identifier, a CAN signal name or a vendor constant is a statement about
 * one car. Spread over the collection layer, it is what made a second vehicle a
 * seven-file edit. The profile is where
 * they moved to, and this test is what keeps them there: a constant pulled back
 * out of the profile fails here rather than at the next port.
 *
 * **The exemptions below are not leniency.** Each names a place whose job is to
 * speak the vehicle's own vocabulary, and the reason travels with it. A sweep
 * without them could never go green, and a sweep that could never go green
 * would be switched off.
 */
class VehicleProfileBoundaryTest {

    /**
     * The directories the boundary covers.
     *
     * `vehicle/` and `roadcast/` are absent on purpose: they are the transports,
     * and reaching an address is what a transport is for.
     */
    private val sweptDirectories = listOf(
        "main/kotlin/com/timhss/capyenergy/telemetry",
        "main/kotlin/com/timhss/capyenergy/service",
        "main/kotlin/com/timhss/capyenergy/helpers"
    )

    /**
     * Files inside a swept directory that may still name the vehicle, each with
     * the reason it may.
     */
    private val exemptions = mapOf(
        "telemetry/EcarxSignalProvider.kt" to
            "The wrapper transport. It reaches the vendor adapter by class name " +
            "and resolves a logical id there; naming the wrapper is its job.",
        "telemetry/db/TelemetryFrameEntity.kt" to
            "A frozen on-disk format. Its column names are the row the sync " +
            "carries, so a rename orphans what a phone already stored.",
        "telemetry/db/TelemetryDatabase.kt" to
            "Migration SQL. It records what shipped; history cannot be rewritten. " +
            "The v16 migration also keeps its own frozen copy of the pack " +
            "figures it ran with, because a migration must stay reproducible " +
            "and must not follow a later correction to them.",
    )

    /**
     * What a vehicle name looks like in code.
     *
     * The patterns match **code identifiers**, never prose: a doc comment may
     * name the bus signal a canonical key replaced, and forbidding that would
     * delete the explanation of why the key exists.
     */
    private val vehicleNamePatterns = listOf(
        // A property catalogue reference: GeelyProperties.EdEvBatteryPercentage.
        Regex("""\bGeelyProperties\s*\."""),
        // A raw VHAL address written as a hex literal: 0x2140A377. The all-zero
        // word is excluded: it is the placeholder a synthetic sample carries
        // where a real one would carry an address, and it names nothing.
        Regex("""\b0x(?!0{8}\b)[0-9a-fA-F]{8}\b"""),
        // A CAN signal name in a string literal: "VCU_DrvPwrAct", "BMSH_BattCurr".
        Regex(""""(?:VCU|BMSH|ESC|OBC|AC|BCM|IPK|ACU|PEPS|GCU|IPU|DCHA)_[A-Za-z0-9_]+""""),
        // A pack figure written out instead of read from the profile.
        //
        // This pattern exists because the first version of this sweep missed
        // exactly that case: `VehicleBatterySpec` kept its own copy of the
        // default capacity and the accepted band after `GeelyProfile.battery`
        // already declared them, and three files under `telemetry/` read the
        // copy. The sweep passed, because a Kotlin object holding a vehicle
        // number looks nothing like a property address.
        Regex("""\b39_?600(?:\.0)?\b"""),
        Regex("""\b200_?000(?:\.0)?\b""")
    )

    @Test
    fun `no file above layer 0 names a vehicle`() {
        val offences = mutableListOf<String>()

        sourceRoot().walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { file -> sweptDirectories.any { file.path.contains(it) } }
            .filter { relativePath(it) !in exemptions }
            .forEach { file ->
                file.readLines().forEachIndexed { index, line ->
                    val code = line.substringBefore("//").trim()
                    if (code.startsWith("*")) return@forEachIndexed
                    vehicleNamePatterns.forEach { pattern ->
                        if (pattern.containsMatchIn(code)) {
                            offences += "${relativePath(file)}:${index + 1}: $code"
                        }
                    }
                }
            }

        if (offences.isNotEmpty()) {
            fail(
                "These files name a vehicle above layer 0. Move the constant into " +
                    "GeelyProfile / GeelyProperties, or add the file to the " +
                    "exemption list in this test with the reason it belongs " +
                    "there:\n" + offences.joinToString("\n")
            )
        }
    }

    @Test
    fun `the sweep reads real files`() {
        // Guards the walk itself. A wrong root, a moved package or a broken
        // filter would make the test above pass by reading nothing, which is
        // the one failure a sweep cannot report on its own.
        val swept = sourceRoot().walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .count { file -> sweptDirectories.any { file.path.contains(it) } }
        assertTrue("The sweep found $swept files; it should find dozens", swept > 30)
    }

    @Test
    fun `every exempt file exists`() {
        // An exemption for a file that has been deleted or renamed is a hole in
        // the boundary that nothing would report.
        exemptions.keys.forEach { path ->
            val file = File(sourceRoot(), "main/kotlin/com/timhss/capyenergy/$path")
            assertTrue("Exempt file no longer exists: $path", file.isFile)
        }
    }

    @Test
    fun `the profile is where the vehicle names live`() {
        val profileText = File(sourceRoot(), "main/kotlin/com/timhss/capyenergy/profile")
            .walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .joinToString("\n") { it.readText() }
        // If these are absent from layer 0, they were not moved — they were lost.
        assertTrue("0x2140A377" in profileText || "0x2140a377" in profileText)
        assertTrue("\"VCU_DrvPwrAct\"" in profileText)
        assertTrue("\"BMSH_BattCurr\"" in profileText)
        assertTrue("39_600" in profileText)
        assertTrue("200_000" in profileText)
    }

    private fun relativePath(file: File): String =
        file.path.substringAfter("com/timhss/capyenergy/")

    private fun sourceRoot(): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(dir, "app/src")
            if (candidate.isDirectory) return candidate
            val here = File(dir, "src")
            if (here.isDirectory && File(here, "main/kotlin").isDirectory) return here
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find app/src from ${File("").absolutePath}")
    }
}
