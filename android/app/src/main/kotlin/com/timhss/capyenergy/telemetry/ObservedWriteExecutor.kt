package com.timhss.capyenergy.telemetry

import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** FIFO executor with low-cost persistence health metrics. */
class ObservedWriteExecutor(
    private val name: String,
    private val queueCapacity: Int = DEFAULT_QUEUE_CAPACITY
) {
    enum class OverflowPolicy { DROP_NEWEST, BLOCK }

    /**
     * Identity, not value.
     *
     * As a data class this compared equal to any other marker stamped in the same
     * nanosecond, so [ConcurrentLinkedQueue.remove] could drop a sibling's marker
     * instead of its own and leave one stranded forever, inflating
     * `oldestQueuedAgeMillis` for the life of the process.
     */
    private class QueuedTask(val queuedAtNanos: Long)

    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(queueCapacity)
    )
    private val queuedTasks = ConcurrentLinkedQueue<QueuedTask>()

    /**
     * Tracked alongside [queuedTasks] because `ConcurrentLinkedQueue.size` walks
     * the whole queue. It was being called on every accepted task, writes and
     * reads alike, just to move the high-water mark — up to a 256-element
     * traversal per frame batch on the hot path.
     */
    private val queuedDepth = AtomicInteger(0)
    private val acceptedWrites = AtomicLong(0L)
    private val committedWrites = AtomicLong(0L)
    private val failedWrites = AtomicLong(0L)
    private val droppedWrites = AtomicLong(0L)
    private val queueHighWatermark = AtomicInteger(0)
    private val lastAcceptedUtcMillis = AtomicLong(0L)
    private val lastAcceptedElapsedNanos = AtomicLong(0L)
    private val lastCommittedUtcMillis = AtomicLong(0L)
    private val lastCommittedElapsedNanos = AtomicLong(0L)
    private val lastCommitLatencyMillis = AtomicLong(0L)
    private val maxCommitLatencyMillis = AtomicLong(0L)
    private val lastErrorUtcMillis = AtomicLong(0L)
    private val lastError = AtomicReference<String?>(null)
    private val lastOperation = AtomicReference<String?>(null)

    fun executeWrite(
        operation: String,
        acceptedElapsedNanos: Long? = null,
        onFailure: (Throwable) -> Unit = {},
        overflowPolicy: OverflowPolicy = OverflowPolicy.BLOCK,
        block: () -> Unit
    ): Boolean {
        val queued = accepted(operation, acceptedElapsedNanos, isWrite = true)
        val task = Runnable {
            started(queued)
            try {
                block()
                committed(queued, acceptedElapsedNanos)
            } catch (error: Throwable) {
                failed(error)
                onFailure(error)
            }
        }
        try {
            enqueue(task, overflowPolicy)
            return true
        } catch (error: RejectedExecutionException) {
            discard(queued)
            droppedWrites.incrementAndGet()
            return false
        } catch (error: Throwable) {
            discard(queued)
            failed(error)
            onFailure(error)
            return false
        }
    }

    fun <T> call(
        operation: String,
        trackAsWrite: Boolean = false,
        acceptedElapsedNanos: Long? = null,
        block: () -> T
    ): T {
        val queued = accepted(operation, acceptedElapsedNanos, trackAsWrite)
        val task = FutureTask(Callable {
                started(queued)
                try {
                    block().also {
                        if (trackAsWrite) committed(queued, acceptedElapsedNanos)
                    }
                } catch (error: Throwable) {
                    if (trackAsWrite) failed(error)
                    throw error
                }
            })
        return try {
            enqueue(task, OverflowPolicy.BLOCK)
            task.get()
        } catch (error: Throwable) {
            discard(queued)
            throw error
        }
    }

    fun awaitIdle() {
        call(operation = "barrier") { Unit }
    }

    fun statusMap(): Map<String, Any?> {
        val nowNanos = System.nanoTime()
        val oldestQueuedAgeMillis = queuedTasks.peek()?.let {
            TimeUnit.NANOSECONDS.toMillis((nowNanos - it.queuedAtNanos).coerceAtLeast(0L))
        } ?: 0L
        return mapOf(
            "name" to name,
            "acceptedWrites" to acceptedWrites.get(),
            "committedWrites" to committedWrites.get(),
            "failedWrites" to failedWrites.get(),
            "droppedWrites" to droppedWrites.get(),
            "queueDepth" to executor.queue.size,
            "queueCapacity" to queueCapacity,
            "queueHighWatermark" to queueHighWatermark.get(),
            "writeInProgress" to (executor.activeCount > 0),
            "oldestQueuedAgeMillis" to oldestQueuedAgeMillis,
            "lastOperation" to lastOperation.get(),
            "lastAcceptedUtcMillis" to lastAcceptedUtcMillis.get().takeIf { it > 0 },
            "lastAcceptedElapsedNanos" to lastAcceptedElapsedNanos.get().takeIf { it > 0 },
            "lastCommittedUtcMillis" to lastCommittedUtcMillis.get().takeIf { it > 0 },
            "lastCommittedElapsedNanos" to lastCommittedElapsedNanos.get().takeIf { it > 0 },
            "lastCommitLatencyMillis" to lastCommitLatencyMillis.get(),
            "maxCommitLatencyMillis" to maxCommitLatencyMillis.get(),
            "lastErrorUtcMillis" to lastErrorUtcMillis.get().takeIf { it > 0 },
            "lastError" to lastError.get()
        )
    }

    fun resetMetrics() {
        acceptedWrites.set(0L)
        committedWrites.set(0L)
        failedWrites.set(0L)
        droppedWrites.set(0L)
        queueHighWatermark.set(queuedDepth.get())
        lastAcceptedUtcMillis.set(0L)
        lastAcceptedElapsedNanos.set(0L)
        lastCommittedUtcMillis.set(0L)
        lastCommittedElapsedNanos.set(0L)
        lastCommitLatencyMillis.set(0L)
        maxCommitLatencyMillis.set(0L)
        lastErrorUtcMillis.set(0L)
        lastError.set(null)
        lastOperation.set(null)
    }

    private fun accepted(
        operation: String,
        acceptedElapsedNanos: Long?,
        isWrite: Boolean
    ): QueuedTask {
        val queued = QueuedTask(System.nanoTime())
        queuedTasks.add(queued)
        queueHighWatermark.accumulateAndGet(queuedDepth.incrementAndGet(), ::maxOf)
        if (isWrite) {
            acceptedWrites.incrementAndGet()
            lastAcceptedUtcMillis.set(System.currentTimeMillis())
            acceptedElapsedNanos?.let(lastAcceptedElapsedNanos::set)
            lastOperation.set(operation)
        }
        return queued
    }

    private fun started(queued: QueuedTask) {
        discard(queued)
    }

    /**
     * Idempotent: the failure paths also call this for a marker [started] may have
     * already taken, so the depth only moves when the removal actually happened.
     */
    private fun discard(queued: QueuedTask) {
        if (queuedTasks.remove(queued)) queuedDepth.decrementAndGet()
    }

    private fun committed(queued: QueuedTask, acceptedElapsedNanos: Long?) {
        committedWrites.incrementAndGet()
        lastCommittedUtcMillis.set(System.currentTimeMillis())
        acceptedElapsedNanos?.let(lastCommittedElapsedNanos::set)
        val latency = TimeUnit.NANOSECONDS.toMillis(
            (System.nanoTime() - queued.queuedAtNanos).coerceAtLeast(0L)
        )
        lastCommitLatencyMillis.set(latency)
        maxCommitLatencyMillis.accumulateAndGet(latency, ::maxOf)
    }

    private fun failed(error: Throwable) {
        failedWrites.incrementAndGet()
        lastErrorUtcMillis.set(System.currentTimeMillis())
        lastError.set("${error.javaClass.simpleName}: ${error.message}".take(500))
    }

    private fun enqueue(task: Runnable, overflowPolicy: OverflowPolicy) {
        try {
            executor.execute(task)
        } catch (rejected: RejectedExecutionException) {
            if (overflowPolicy == OverflowPolicy.DROP_NEWEST || executor.isShutdown) {
                throw rejected
            }
            executor.queue.put(task)
        }
    }

    private companion object {
        const val DEFAULT_QUEUE_CAPACITY = 256
    }
}
