package com.timhss.capyenergy.telemetry

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The position in the series comes from the receiver.
 *
 * This car publishes no position property. `FrameRepository` nevertheless read
 * `snapshot[SignalKey.LATITUDE]` — a key nothing ever puts in the store — while
 * the `locationProvider` that `TelemetryGraph` handed it was never called. The
 * parameter compiled, the wiring looked complete, and between the slice 4
 * install and 2026-08-20 not one recorded trip carried a route.
 *
 * A dead constructor parameter is invisible to the compiler and to every test
 * that does not run the car, which is why this is a sweep of the source. It is
 * the same failure shape as the 2026-07-29 watchlist defect that
 * `CollectionSequenceTest` exists for: everything alive, nothing connected.
 */
class PositionSourceTest {

    @Test
    fun `the frame repository reads the location provider it was given`() {
        val text = frameRepository().readText()

        assertTrue(
            "FrameRepository never calls locationProvider(). The position " +
                "cannot reach the sample series, and every trip loses its route",
            text.contains("locationProvider()")
        )
        assertTrue(
            "FrameRepository reads a position out of the signal store. Nothing " +
                "ever puts one there on this car, so the read writes no rows",
            !text.contains("snapshot[SignalKey.LATITUDE]")
        )
    }

    private fun frameRepository(): File {
        var dir = File("").absoluteFile
        while (dir.parentFile != null) {
            val candidate = File(
                dir,
                "app/src/main/kotlin/com/timhss/capyenergy/telemetry/FrameRepository.kt"
            )
            if (candidate.isFile) return candidate
            val here = File(
                dir,
                "src/main/kotlin/com/timhss/capyenergy/telemetry/FrameRepository.kt"
            )
            if (here.isFile) return here
            dir = dir.parentFile
        }
        throw IllegalStateException("Could not find FrameRepository.kt from ${File("").absolutePath}")
    }
}
