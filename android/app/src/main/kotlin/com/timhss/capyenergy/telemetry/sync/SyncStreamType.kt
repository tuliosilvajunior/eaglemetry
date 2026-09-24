package com.timhss.capyenergy.telemetry.sync

/**
 * Supported synchronization streams between the car and companion devices.
 *
 * Matches [SyncStreamType] in packages/telemetry_core/lib/dto/sync_models.dart.
 */
enum class SyncStreamType(val wireName: String) {
    SESSIONS("sessions"),
    TELEMETRY_FRAMES("telemetryFrames"),
    BATTERY_CYCLES("batteryCycles"),
    INTERVALS("intervals"),
    EVENTS("events"),
    TRACKS("tracks"),

    /** Annotation streams, synced both directions. */
    PLACES("places"),
    PREFERENCES("preferences"),
    SESSION_COSTS("sessionCosts"),
    PREFERENCE_PROPOSALS("preferenceProposals"),
    JOURNEYS("journeys");

    companion object {
        fun fromWireName(name: String?): SyncStreamType? {
            if (name == null) return null
            return values().firstOrNull { it.wireName == name }
        }
    }
}
