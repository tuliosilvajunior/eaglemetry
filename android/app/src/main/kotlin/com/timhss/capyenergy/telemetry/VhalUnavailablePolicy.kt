package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey

import java.util.concurrent.ConcurrentHashMap

/** What to do with a callback that carries a non-available status. */
enum class UnavailableAction {
    /** The first refusal of a run. Log it and write the error sample. */
    REPORT,

    /** A repeat of a refusal already reported. It states nothing new. */
    IGNORE,

    /** The signal has refused often enough to stop asking. Unsubscribe. */
    MUTE
}

/**
 * How often a signal may answer "not available" before the app stops listening.
 *
 * A property that answers `status != AVAILABLE` on every callback is not a
 * degraded reading, it is an absent one, and it costs the whole delivery path
 * each time: an OEM framework log line per read, an adaptation, an error sample
 * and a full snapshot copy to every store listener.
 *
 * The 2026-08-17 field probe measured `ENV_OUTSIDE_TEMPERATURE` doing exactly
 * this once a second, forever, on a car where `AC_AMBIENT_TEMP` is the trusted
 * source and this property is only the fallback.
 *
 * The first refusal is still reported in full. What the app drops is the
 * repetition: the store already holds "unavailable", and saying it again a
 * thousand times does not make it more true. A muted signal is retried later,
 * because an ECU that is asleep now can publish after it wakes.
 */
class VhalUnavailablePolicy(
    private val refusalsBeforeMute: Int = DEFAULT_REFUSALS_BEFORE_MUTE
) {
    init {
        require(refusalsBeforeMute >= 1) { "A signal must be allowed at least one refusal" }
    }

    private val refusals = ConcurrentHashMap<SignalKey, Int>()

    /** A usable value arrived. The run of refusals is over. */
    fun onAvailable(signalId: SignalKey) {
        refusals.remove(signalId)
    }

    /** A refusal arrived. Says whether it is worth reporting, and when to stop. */
    fun onUnavailable(signalId: SignalKey): UnavailableAction {
        val count = (refusals[signalId] ?: 0) + 1
        refusals[signalId] = count
        return when {
            count == 1 -> UnavailableAction.REPORT
            count == refusalsBeforeMute -> UnavailableAction.MUTE
            else -> UnavailableAction.IGNORE
        }
    }

    /**
     * Forget a signal's run, so a retried subscription reports its first
     * refusal again instead of muting on the first callback.
     */
    fun reset(signalId: SignalKey) {
        refusals.remove(signalId)
    }

    fun clear() {
        refusals.clear()
    }

    companion object {
        /**
         * Ten refusals. A property that is merely warming up recovers well
         * inside that; one that is absent on this car reaches it in seconds.
         */
        const val DEFAULT_REFUSALS_BEFORE_MUTE = 10
    }
}
