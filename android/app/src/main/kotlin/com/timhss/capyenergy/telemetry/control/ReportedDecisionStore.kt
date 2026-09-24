package com.timhss.capyenergy.telemetry.control

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.VisibleForTesting

/**
 * Which decisions the car already reported to `preference_reported`.
 *
 * A decision is keyed by the same natural key as the row:
 * `(key, decided_at_utc_millis)`. The mark lands only after the cloud
 * accepted the write, so a failed report is retried on the next pass and a
 * successful one is never sent again — the write-once-per-decision rule of
 * the table, mirrored client-side so a passing sync is not resending what
 * the server already holds.
 */
interface ReportedDecisionStore {
    fun contains(key: String, decidedAtUtcMillis: Long): Boolean
    fun add(key: String, decidedAtUtcMillis: Long)
}

/**
 * SharedPreferences-backed [ReportedDecisionStore].
 *
 * The set is small and decisions are rare, so a plain string set suffices —
 * no Room schema change for a ledger that the wipe-and-repair already loses
 * with the rest of the local database.
 */
class SharedPreferencesReportedDecisionStore(
    prefs: SharedPreferences,
) : ReportedDecisionStore {

    private val persisted = prefs

    @VisibleForTesting
    val keys: Set<String>
        get() = persisted.getStringSet(PREF_KEY, emptySet()).orEmpty()

    override fun contains(key: String, decidedAtUtcMillis: Long): Boolean =
        key in keysByDecision(key, decidedAtUtcMillis)

    override fun add(key: String, decidedAtUtcMillis: Long) {
        val updated = keysByDecision(key, decidedAtUtcMillis).toMutableSet()
        if (!updated.add(entry(key, decidedAtUtcMillis))) return
        persisted.edit().putStringSet(PREF_KEY, updated).apply()
    }

    private fun keysByDecision(key: String, decidedAtUtcMillis: Long): Set<String> {
        val wanted = entry(key, decidedAtUtcMillis)
        val existing = persisted.getStringSet(PREF_KEY, emptySet()).orEmpty()
        return if (wanted in existing) existing else existing
    }

    private fun entry(key: String, decidedAtUtcMillis: Long): String =
        "$key\n$decidedAtUtcMillis"

    companion object {
        private const val PREF_KEY = "preference_reported_decisions"

        fun from(context: Context): SharedPreferencesReportedDecisionStore =
            SharedPreferencesReportedDecisionStore(
                context.applicationContext.getSharedPreferences(
                    "preference_control_ledger",
                    Context.MODE_PRIVATE,
                )
            )
    }
}