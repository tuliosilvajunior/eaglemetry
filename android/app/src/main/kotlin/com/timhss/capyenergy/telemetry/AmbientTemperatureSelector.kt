package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.profile.VehicleProfile

/**
 * The outside temperature, from whichever source the vehicle trusts most.
 *
 * The **order** is a statement about the vehicle and lives in the profile
 * (`VehicleProfile.trustOrder`). What stays here is the rule that applies to
 * any vehicle: take the first source that measured something, and accept a
 * fallback only while it is still fresh.
 *
 * Freshness is asked of the fallback alone. The preferred source is the one the
 * vehicle publishes continuously; a fallback is by definition the one that may
 * have stopped, and a stale fallback reports the weather of half an hour ago as
 * the weather now.
 */
internal fun selectedAmbientTemperatureC(
    snapshot: Map<SignalKey, SignalSample>,
    timestamp: SignalTimestamp? = null,
    profile: VehicleProfile = GeelyProfile
): Float? {
    val order = profile.trustOrder(SignalKey.AMBIENT_AIR_TEMPERATURE)
    order.forEachIndexed { index, key ->
        val sample = snapshot[key]?.takeIf { it.quality == SignalQuality.MEASURED }
        if (sample != null) {
            val isFallback = index > 0
            if (!isFallback) return sample.floatValue()
            if (timestamp == null || sample.isFreshAt(timestamp)) return sample.floatValue()
            return null
        }
    }
    return null
}

private fun SignalSample.isFreshAt(timestamp: SignalTimestamp): Boolean =
    timestamp.receivedAtElapsedNanos - this.timestamp.receivedAtElapsedNanos <= AMBIENT_FALLBACK_FRESH_NANOS

private const val AMBIENT_FALLBACK_FRESH_NANOS = 30_000_000_000L
