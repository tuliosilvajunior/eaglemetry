package com.timhss.capyenergy.concurrent

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every thread name in the app fits in what Linux keeps.
 *
 * `namedThreadFactory` refuses a name longer than [MAX_THREAD_NAME_LENGTH]
 * rather than trimming it, which is the right choice — a trimmed name reads as
 * another thread's in the one tool this exists for. The consequence is that a
 * name one character too long is a **crash**, and the crash lands wherever the
 * pool happens to be built.
 *
 * On 2026-08-20 that was `MainActivity.onCreate`: `session-costs-db` is 16
 * characters, `SessionCostRepository` is built by `TelemetryGraph`, and the car
 * app could not start at all. Nothing caught it earlier because a JVM unit test
 * builds a repository, not the graph, and the graph needs a device.
 *
 * So the check is a sweep of the source. It costs nothing, it needs no device,
 * and it fails on the line that is wrong rather than at the next launch.
 */
class ThreadNameLengthTest {

    private val call = Regex(
        "named(?:SingleThreadExecutor|SingleThreadScheduledExecutor|" +
            "FixedThreadPool|ThreadFactory)\\(\\s*\"([^\"]+)\""
    )

    @Test
    fun `no thread name is longer than Linux keeps`() {
        val offenders = mutableListOf<String>()
        var found = 0
        File(sourceRoot(), "main/kotlin").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .forEach { file ->
                call.findAll(file.readText()).forEach { match ->
                    val name = match.groupValues[1]
                    found += 1
                    if (name.length > MAX_THREAD_NAME_LENGTH) {
                        offenders += "${file.name}: '$name' is ${name.length}"
                    }
                }
            }

        // A sweep that matched nothing would pass forever while proving
        // nothing, which is how a renamed helper switches a test off.
        assertTrue("The sweep found no thread names at all", found > 10)
        assertTrue(
            "A thread name longer than $MAX_THREAD_NAME_LENGTH characters " +
                "crashes wherever the pool is built: $offenders",
            offenders.isEmpty()
        )
    }

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
