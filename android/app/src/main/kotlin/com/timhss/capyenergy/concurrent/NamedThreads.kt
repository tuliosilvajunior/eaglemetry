package com.timhss.capyenergy.concurrent

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/**
 * Executors that say what they are.
 *
 * The default `Executors` factory names a thread `pool-N-thread-M`, where N is
 * the order in which the pool was built in the process. That number is the only
 * identity the thread has in `top -H`, in `/proc/<tid>/comm`, and in a crash
 * trace. It moves whenever construction order moves, so a CPU measurement can
 * name a thread only by guessing which of the twenty-odd pools was the
 * fourteenth to exist.
 *
 * The 2026-08-17 field probe is the case: `pool-7-thread-1` burned 13 s of CPU
 * at startup and `pool-14-thread-1` held a third of a core with the car parked,
 * and neither could be attributed from the log alone.
 *
 * Linux truncates a thread name to 15 characters, so keep a name short. It is
 * checked, not trimmed: a name that would be cut is a name that reads as
 * another thread's in the very tool this exists for.
 */
const val MAX_THREAD_NAME_LENGTH = 15

/**
 * A factory that names its threads `<name>` when the pool holds one thread and
 * `<name>-<n>` when it holds several.
 */
fun namedThreadFactory(name: String): ThreadFactory {
    require(name.isNotBlank()) { "A thread name cannot be blank" }
    require(name.length <= MAX_THREAD_NAME_LENGTH) {
        "Thread name '$name' is ${name.length} characters; Linux truncates at $MAX_THREAD_NAME_LENGTH"
    }
    val counter = AtomicInteger(0)
    return ThreadFactory { runnable ->
        val index = counter.incrementAndGet()
        val threadName = if (index == 1) name else "$name-$index"
        Thread(runnable, threadName)
    }
}

/** One named worker. */
fun namedSingleThreadExecutor(name: String): ExecutorService =
    Executors.newSingleThreadExecutor(namedThreadFactory(name))

/** One named worker that also runs delayed and repeating work. */
fun namedSingleThreadScheduledExecutor(name: String): ScheduledExecutorService =
    Executors.newSingleThreadScheduledExecutor(namedThreadFactory(name))

/**
 * A fixed pool of named workers. The second thread onward carries a suffix, so
 * `sync-http`, `sync-http-2`, `sync-http-3` are one pool rather than three
 * strangers. Allow for the suffix when choosing the name.
 */
fun namedFixedThreadPool(name: String, threads: Int): ExecutorService =
    Executors.newFixedThreadPool(threads, namedThreadFactory(name))
