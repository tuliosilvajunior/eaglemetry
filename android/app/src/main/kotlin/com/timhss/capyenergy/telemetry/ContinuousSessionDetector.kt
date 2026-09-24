package com.timhss.capyenergy.telemetry

import android.os.SystemClock
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.telemetry.db.SessionEntity

interface ContinuousSessionStore {
    fun latestOpenContinuousSession(): SessionEntity?

    fun createContinuousSession(startedAt: SignalTimestamp): String

    fun closeContinuousSession(id: String, endedAt: SignalTimestamp, reason: String)
}

/**
 * Opens one `CONTINUOUS` session per collector run and keeps it open for as
 * long as the collector runs, with no gate of any kind — no gear, no speed,
 * no trip, no charge. `TRIP`, `PARKED` and `CHARGE` keep recording exactly as
 * they do today; this is the fourth, ungated stream issue 199 adds beside
 * them.
 *
 * The session opens lazily, on the first frame after [enabledProvider] turns
 * true, rather than the instant collection starts: a session's `startedAt`
 * is a real signal timestamp, the same way every other detector's is, not a
 * platform-clock stamp taken before any signal has been read.
 *
 * It closes two ways. [stop] closes it explicitly when the collector stops —
 * unlike the other three detectors, whose sessions describe a state of the
 * *vehicle* and so correctly outlive a stopped collector, this one describes
 * the *collector's own uptime* and must not. Turning [enabledProvider] off
 * mid-run closes it the same way, on the next frame, so "the mode is off"
 * and "a continuous minute is being written" can never both be true.
 */
class ContinuousSessionDetector(
    private val sessionRepository: ContinuousSessionStore,
    private val enabledProvider: () -> Boolean = { false }
) : SignalStateStore.Listener {

    private var activeSessionId: String? = null
    private var sessionStartedAt: SignalTimestamp? = null
    private var restored = false

    @Synchronized
    fun activeFrameSession(): ActiveFrameSession? {
        val id = activeSessionId ?: return null
        return ActiveFrameSession(id = id, type = SESSION_TYPE)
    }

    /**
     * Closes whatever a previous run left open. Every restore closes it and
     * never adopts it: this detector's session belongs to one collector run,
     * so "since power on" always starts at this run's first frame, never at
     * a session a killed process left behind.
     *
     * [STALE_OPEN_SESSION_THRESHOLD_MILLIS] — the same 24 h the parked
     * detector uses for its own stale recovery — only decides which reason is
     * recorded, not whether the session survives: it never does.
     */
    fun restoreIfNeeded() {
        if (restored) return
        restored = true
        while (true) {
            val openSession = sessionRepository.latestOpenContinuousSession() ?: break
            val ageMillis = System.currentTimeMillis() - openSession.updatedAtUtcMillis
            val reason = if (ageMillis >= STALE_OPEN_SESSION_THRESHOLD_MILLIS) {
                "STALE_RECOVERY"
            } else {
                "COLLECTOR_RESTARTED"
            }
            sessionRepository.closeContinuousSession(
                id = openSession.id,
                endedAt = SignalTimestamp(
                    receivedAtUtcMillis = openSession.updatedAtUtcMillis,
                    receivedAtElapsedNanos = openSession.updatedAtElapsedNanos ?: 0L,
                    sourceTimestampNanos = null,
                    accuracy = TimestampAccuracy.INFERRED,
                    uncertaintyMillis = 0L
                ),
                reason = reason
            )
        }
    }

    @Synchronized
    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        if (!enabledProvider()) {
            closeSession(sample.timestamp, "MODE_DISABLED")
            return
        }
        val startedAt = sessionStartedAt
        if (startedAt == null) {
            openSession(sample.timestamp)
            return
        }
        if (exceedsRotationCeiling(startedAt, sample.timestamp)) {
            closeSession(sample.timestamp, "ROTATION_CEILING")
            openSession(sample.timestamp)
        }
    }

    /**
     * Closes the session the collector stopping, not a frame, ends.
     *
     * Called from outside any signal callback, so there is no [SignalSample]
     * to close with; a platform-clock stamp is the only "now" available, and
     * [TimestampAccuracy.INFERRED] says so.
     */
    @Synchronized
    fun stop() {
        if (activeSessionId == null) return
        closeSession(
            SignalTimestamp(
                receivedAtUtcMillis = System.currentTimeMillis(),
                receivedAtElapsedNanos = SystemClock.elapsedRealtimeNanos(),
                sourceTimestampNanos = null,
                accuracy = TimestampAccuracy.INFERRED,
                uncertaintyMillis = 0L
            ),
            "COLLECTOR_STOPPED"
        )
    }

    private fun exceedsRotationCeiling(startedAt: SignalTimestamp, now: SignalTimestamp): Boolean {
        val elapsedNanos = now.receivedAtElapsedNanos - startedAt.receivedAtElapsedNanos
        return elapsedNanos >= ROTATION_CEILING_NANOS
    }

    private fun openSession(startedAt: SignalTimestamp) {
        activeSessionId = sessionRepository.createContinuousSession(startedAt)
        sessionStartedAt = startedAt
    }

    private fun closeSession(endedAt: SignalTimestamp, reason: String) {
        val id = activeSessionId ?: return
        sessionRepository.closeContinuousSession(id, endedAt, reason)
        activeSessionId = null
        sessionStartedAt = null
    }

    companion object {
        const val SESSION_TYPE = "CONTINUOUS"
        const val STALE_OPEN_SESSION_THRESHOLD_MILLIS = 24 * 3_600 * 1_000L
        const val ROTATION_CEILING_MILLIS = 24 * 3_600 * 1_000L
        private const val ROTATION_CEILING_NANOS = ROTATION_CEILING_MILLIS * 1_000_000L
    }
}
