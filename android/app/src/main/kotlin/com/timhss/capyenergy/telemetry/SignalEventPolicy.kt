package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.profile.VehicleProfile

/**
 * Decides which signal value changes deserve a SIGNAL_UPDATED event row.
 *
 * Continuous physical quantities jitter on nearly every poll and are already
 * captured by the frame stream, so persisting each change as an event only
 * duplicates data. Events are reserved for discrete transitions plus a few
 * sparse numeric signals where crossing a deadband is itself meaningful.
 *
 * **The judgement is here; the numbers are in the profile.** How far state of
 * charge must drift, and whether a signal is discrete, are statements about one
 * vehicle. This object keeps the rules that hold on every vehicle: a quality
 * change is always worth a row, a signal that is already broken at start must
 * say so once, and an unchanged value is never worth a row.
 *
 * The profile declares a deadband **per series**. This one reads
 * `SignalDeadbands.event`; the sample series reads its own, and a signal with
 * no event band is one the event log does not carry.
 */
class SignalEventPolicy(private val profile: VehicleProfile = GeelyProfile) {

    /**
     * The whole decision for one sample, quality included.
     *
     * A signal that is already broken when the process starts must still say so
     * once. [EventRepository] holds both the quality and the last logged value
     * per process, so the first sample after a start has neither; when that
     * sample also carries no value, `null == null` closes the value gate and the
     * absent previous quality closes the quality gate. The outside temperature
     * went to storage that way and stayed dead from 2026-08-05 to 2026-08-08
     * with not one row to show for it.
     *
     * [firstSightIsBad] can only be true once per signal per start, so a signal
     * that stays broken still writes one row and not a flood.
     */
    fun shouldLog(
        signalId: SignalKey,
        previousQuality: SignalQuality?,
        quality: SignalQuality,
        lastLoggedValue: Any?,
        newValue: Any?
    ): Boolean {
        val qualityChanged = previousQuality != null && previousQuality != quality
        val firstSightIsBad = previousQuality == null && quality != SignalQuality.MEASURED
        return qualityChanged || firstSightIsBad ||
            shouldLogValueChange(signalId, lastLoggedValue, newValue)
    }

    fun shouldLogValueChange(signalId: SignalKey, lastLoggedValue: Any?, newValue: Any?): Boolean {
        if (newValue == lastLoggedValue) return false
        val declaration = profile.declarationFor(signalId) ?: return false
        if (declaration.everyChangeIsAnEvent) return true
        val deadband = declaration.deadbands.event ?: return false
        val previous = asDouble(lastLoggedValue) ?: return true
        val next = asDouble(newValue) ?: return true
        return kotlin.math.abs(next - previous) >= deadband
    }

    private fun asDouble(value: Any?): Double? = when (value) {
        is Number -> value.toDouble()
        else -> null
    }
}
