package com.timhss.capyenergy.telemetry

import kotlin.math.max

/**
 * Hybrid Logical Clock timestamp for annotation rows.
 *
 * Mirrors `HlcTimestamp` in `packages/telemetry_core/lib/dto/sync_models.dart`
 * with identical send/receive semantics, so the two replicas advance the
 * same way. This step only stores the stamp; the wall-clock comparison still
 * decides winners (see `AnnotationConvergence.shouldReplace`). The comparison
 * switch is 6b.
 */
data class AnnotationHlc(
    val millis: Long,
    val counter: Int,
    val deviceId: String,
) : Comparable<AnnotationHlc> {
    fun send(physicalWallMillis: Long): AnnotationHlc {
        val highestMillis = max(physicalWallMillis, millis)
        val nextCounter = if (highestMillis == millis) counter + 1 else 0
        return AnnotationHlc(
            millis = highestMillis,
            counter = nextCounter,
            deviceId = deviceId,
        )
    }

    fun receive(remote: AnnotationHlc, physicalWallMillis: Long): AnnotationHlc {
        if (remote.millis - physicalWallMillis > MAX_DRIFT_MILLIS) {
            throw HlcDriftException(remote.millis, physicalWallMillis, MAX_DRIFT_MILLIS)
        }
        val highestMillis = max(physicalWallMillis, max(millis, remote.millis))
        val nextCounter = when {
            highestMillis == millis && highestMillis == remote.millis ->
                max(counter, remote.counter) + 1
            highestMillis == millis -> counter + 1
            highestMillis == remote.millis -> remote.counter + 1
            else -> 0
        }
        return AnnotationHlc(
            millis = highestMillis,
            counter = nextCounter,
            deviceId = deviceId,
        )
    }

    override fun compareTo(other: AnnotationHlc): Int {
        if (millis != other.millis) return millis.compareTo(other.millis)
        if (counter != other.counter) return counter.compareTo(other.counter)
        return deviceId.compareTo(other.deviceId)
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "millis" to millis,
        "counter" to counter,
        "deviceId" to deviceId,
    )

    companion object {
        const val MAX_DRIFT_MILLIS = 30 * 60 * 1000L

        fun fromMap(map: Map<String, Any?>?): AnnotationHlc? {
            if (map == null) return null
            val millis = (map["millis"] as? Number)?.toLong() ?: return null
            val counter = (map["counter"] as? Number)?.toInt() ?: return null
            val deviceId = map["deviceId"] as? String ?: return null
            if (deviceId.isEmpty() || millis < 0 || counter < 0) return null
            return AnnotationHlc(millis, counter, deviceId)
        }

        fun fromRow(row: Map<String, Any?>): AnnotationHlc? {
            val millis = (row["hlcMillis"] as? Number)?.toLong()
                ?: (row["hlc"] as? Map<String, Any?>)?.let { (it["millis"] as? Number)?.toLong() }
                ?: return null
            val counter = (row["hlcCounter"] as? Number)?.toInt()
                ?: (row["hlc"] as? Map<String, Any?>)?.let { (it["counter"] as? Number)?.toInt() }
                ?: 0
            val deviceId = (row["hlcDeviceId"] as? String)
                ?: (row["hlc"] as? Map<String, Any?>)?.let { it["deviceId"] as? String }
                ?: return null
            if (deviceId.isEmpty() || millis < 0 || counter < 0) return null
            return AnnotationHlc(millis, counter, deviceId)
        }

        fun compareHlc(
            m1: Long, c1: Int, d1: String,
            m2: Long, c2: Int, d2: String,
        ): Int {
            if (m1 != m2) return m1.compareTo(m2)
            if (c1 != c2) return c1.compareTo(c2)
            return d1.compareTo(d2)
        }
    }
}

class HlcDriftException(
    val remoteMillis: Long,
    val localMillis: Long,
    val maxDriftMillis: Long,
) : Exception(
    "Remote HLC $remoteMillis exceeds local $localMillis by more than $maxDriftMillis ms",
)

/**
 * Per-replica HLC clock for annotation writes.
 *
 * A local write advances via [tick] (send semantics); a received remote
 * value merges via [merge] (receive semantics). The row's stored HLC is the
 * clock's tick on local writes, or the remote's own HLC verbatim on merge.
 */
class AnnotationHlcClock(
    private val deviceId: String,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
) {
    @Volatile
    private var current: AnnotationHlc? = null

    @Synchronized
    fun tick(): AnnotationHlc = tickAt(nowMillis())

    @Synchronized
    fun tickAt(physicalWallMillis: Long): AnnotationHlc {
        val next = current?.send(physicalWallMillis)
            ?: AnnotationHlc(millis = physicalWallMillis, counter = 0, deviceId = deviceId)
        current = next
        return next
    }

    @Synchronized
    fun merge(remote: AnnotationHlc) {
        val now = nowMillis()
        val next = try {
            current?.receive(remote, now)
                ?: run {
                    // No local state yet: adopt remote then advance with local wall.
                    // Mirrors Dart's receive when current is null.
                    val highestMillis = max(now, remote.millis)
                    val nextCounter = if (highestMillis == remote.millis) remote.counter + 1 else 0
                    AnnotationHlc(highestMillis, nextCounter, deviceId)
                }
        } catch (e: HlcDriftException) {
            // Remote clock far ahead: cap to local wall + drift allowance is
            // already enforced by Dart's guard; here we just keep local time.
            // This prevents a faulty remote from pushing the clock forward
            // permanently, matching the sync cursor drift handling.
            val highestMillis = max(now, current?.millis ?: now)
            val nextCounter = (current?.counter ?: -1) + 1
            AnnotationHlc(highestMillis, nextCounter.coerceAtLeast(0), deviceId)
        }
        current = next
    }

    @Synchronized
    fun currentOrNull(): AnnotationHlc? = current

    @Synchronized
    fun reset() {
        current = null
    }

    companion object {
        /**
         * Global car clock. The car is one device, so one clock is shared
         * across all annotation repositories. Tests may reset it.
         */
        val global: AnnotationHlcClock = AnnotationHlcClock(
            deviceId = AnnotationConvergence.ORIGIN_CAR,
        )
    }
}
