package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SignalSpec
import com.timhss.capyenergy.profile.VehicleProfile

/**
 * The watchlist the subscription manager works from.
 *
 * It used to hold the table itself: 60 signal specifications, each naming a
 * VHAL identifier, in a file under `telemetry/`. That is a statement about one
 * vehicle, so it moved to [GeelyProfile] in layer 0, and what stays here is the
 * question "which signals does this vehicle answer on the property surface".
 *
 * The class survives the move because the subscription manager takes a policy,
 * not a profile: what it needs is the list, and a later slice may filter it —
 * by capability, by session state — without the transport learning what a
 * profile is.
 */
class TelemetryPolicy(private val profile: VehicleProfile = GeelyProfile) {
    val signalSpecs: List<SignalSpec> get() = profile.propertySignals
}
