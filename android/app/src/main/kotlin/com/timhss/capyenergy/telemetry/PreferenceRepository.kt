package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.telemetry.db.PreferenceDao
import com.timhss.capyenergy.telemetry.db.PreferenceEntity
import com.timhss.capyenergy.telemetry.db.PreferenceProposalDao
import com.timhss.capyenergy.telemetry.db.PreferenceProposalEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.util.UUID
import java.util.concurrent.Callable

/**
 * Issue #227, Lane C: the control/annotation boundary.
 *
 * Membership is mechanical: if it changes what the car does or records, it is
 * control; if it only changes what a screen shows, it is annotation. A control
 * key is the phone's to propose and the car's alone to write; an annotation key
 * is carried by the lane B channel.
 */
enum class PreferenceLane { ANNOTATION, CONTROL }

/**
 * Synced preferences and the proposal channel, on the annotation side.
 *
 * The scopes and their rules come from the plan's table: account-scope keys
 * sync both directions; vehicle-scope keys sync both directions with the car
 * as the authority; the control keys (see [PreferenceRepository.CONTROL_KEYS])
 * change what the car **records** and the phone reaches them only by proposing.
 * A vehicle command is not a preference and never lands here.
 */
class PreferenceRepository(
    context: Context,
    private val clock: () -> Long = System::currentTimeMillis,
    private val annotationChanges: AnnotationChangeBroadcaster? = null,
    private val onProposalAccepted: (key: String, value: String?) -> Boolean = { _, _ -> false },
    private val hlcClock: AnnotationHlcClock = AnnotationHlcClock.global,
    private val accountIdProvider: () -> String? = { null },
) {
    companion object {
        const val SCOPE_ACCOUNT = "account"
        const val SCOPE_VEHICLE = "vehicle"
        const val SCOPE_DEVICE = "device"

        /** Keys both sides write, with their scope. Every key here is lane B. */
        val SYNCED_KEYS: Map<String, String> = mapOf(
            "theme_id" to SCOPE_ACCOUNT,
            "theme_mode" to SCOPE_ACCOUNT,
            "efficiency_unit" to SCOPE_ACCOUNT,
            "charge_cost_currency" to SCOPE_VEHICLE
        )

        /**
         * The control/annotation classification of every known preference key —
         * issue #227, Lane C. The rule:
         *
         *   "if it changes what the car does or records, it is control;
         *    if it only changes what a screen shows, it is annotation."
         *
         * This is the Kotlin half of the one catalogue; the Dart half is
         * `kPreferenceLane` in `packages/telemetry_core`, and the shared
         * fixture `testdata/preference_lanes.json` pins the two against each
         * other so a key registered on one side alone fails a suite. Add a new
         * key here (a one-line addition) and on the Dart side and in the
         * fixture; every code path reads [CONTROL_KEYS] from this map.
         */
        val PREFERENCE_LANE: Map<String, PreferenceLane> = mapOf(
            "theme_id" to PreferenceLane.ANNOTATION,
            "theme_mode" to PreferenceLane.ANNOTATION,
            "efficiency_unit" to PreferenceLane.ANNOTATION,
            "charge_cost_currency" to PreferenceLane.ANNOTATION,
            "places.nominatimOptIn" to PreferenceLane.ANNOTATION,
            "reduce_motion" to PreferenceLane.ANNOTATION,
            "pack_capacity_wh" to PreferenceLane.CONTROL,
            "default_charge_cost_per_kwh" to PreferenceLane.CONTROL
        )

        /** The control keys — what the phone may propose and never write. */
        val CONTROL_KEYS: Set<String> = PREFERENCE_LANE
            .filterValues { it == PreferenceLane.CONTROL }
            .keys
            .toSet()

        val SYNCABLE_SCOPES: Set<String> = setOf(SCOPE_ACCOUNT, SCOPE_VEHICLE)
    }

    /**
     * The car's write path for a proposal the owner accepted. Set by the
     * runtime after construction, because the repository cannot reach it:
     * for `pack_capacity_wh` this is the settings write that refolds every
     * battery cycle from zero, exactly once, when a person confirmed it.
     */
    @Volatile
    private var proposalAcceptedHandler: (key: String, value: String?) -> Boolean =
        onProposalAccepted

    fun setProposalAcceptedHandler(handler: (key: String, value: String?) -> Boolean) {
        proposalAcceptedHandler = handler
    }

    private val database = TelemetryDatabase.get(context.applicationContext)
    private val preferenceDao: PreferenceDao = database.preferenceDao()
    private val proposalDao: PreferenceProposalDao = database.preferenceProposalDao()
    private val dbExecutor = namedSingleThreadExecutor("preferences-db")

    // --- Preference rows -----------------------------------------------------
    /** The car's own edit. Only synced keys may be written this way. */
    fun saveFromCar(scope: String, key: String, value: String?): PreferenceEntity? {
        if (SYNCED_KEYS[key] != scope) return null
        val now = clock()
        val hlc = hlcClock.tickAt(now)
        val row = PreferenceEntity(
            scope = scope,
            key = key,
            value = value,
            updatedAtUtcMillis = now,
            origin = AnnotationConvergence.ORIGIN_CAR,
            deletedAtUtcMillis = null,
            hlcMillis = hlc.millis,
            hlcCounter = hlc.counter,
            hlcDeviceId = hlc.deviceId,
            accountId = accountIdProvider(),
        )
        dbExecutor.submit<Unit> {
            preferenceDao.upsert(row)
            annotationChanges?.preferencesChanged()
        }.get()
        return row
    }
    /**
     * One row from the annotation channel. Account and vehicle scopes only:
     * a device preference never crosses the channel. Unknown keys are stored
     * and relayed as they arrive: a phone newer than this car may name a key
     * this car does not draw, and dropping it would destroy the choice of
     * the side that can. Returns true when this replica's row moved.
     */
    fun mergeIncoming(row: Map<String, Any?>): Boolean {
        val scope = (row["scope"] as? String)?.trim() ?: return false
        val key = (row["key"] as? String)?.trim() ?: return false
        if (scope !in SYNCABLE_SCOPES || key.isEmpty()) return false
        val updatedAtUtcMillis = AnnotationConvergence.updatedAtUtcMillis(row) ?: return false
        val origin = AnnotationConvergence.origin(row) ?: AnnotationConvergence.ORIGIN_PHONE
        val incomingHlc = AnnotationHlc.fromRow(row)
            ?: AnnotationHlc(millis = updatedAtUtcMillis, counter = 0, deviceId = origin)

        return dbExecutor.submit(Callable {
            hlcClock.merge(incomingHlc)
            val existing = preferenceDao.findById(scope, key)
            if (existing != null && !AnnotationConvergence.shouldReplace(
                    existingHlc = AnnotationHlc(
                        millis = existing.hlcMillis,
                        counter = existing.hlcCounter,
                        deviceId = existing.hlcDeviceId,
                    ),
                    existingOrigin = existing.origin,
                    incomingHlc = incomingHlc,
                    incomingOrigin = origin
                )
            ) {
                return@Callable false
            }
            preferenceDao.upsert(
                PreferenceEntity(
                    scope = scope,
                    key = key,
                    value = row["value"] as? String,
                    updatedAtUtcMillis = updatedAtUtcMillis,
                    origin = origin,
                    deletedAtUtcMillis = (row["deletedAtUtcMillis"] as? Number)?.toLong(),
                    hlcMillis = incomingHlc.millis,
                    hlcCounter = incomingHlc.counter,
                    hlcDeviceId = incomingHlc.deviceId,
                    // Born under the pairing active when the row lands, like
                    // every other local write.
                    accountId = accountIdProvider()
                )
            )
            annotationChanges?.preferencesChanged()
            true
        }).get()
    }

    fun activeRows(): List<PreferenceEntity> =
        dbExecutor.submit(Callable { preferenceDao.active() }).get()

    fun findByKey(scope: String, key: String): PreferenceEntity? =
        dbExecutor.submit(Callable { preferenceDao.findById(scope, key) }).get()

    fun syncPage(afterUpdatedAtUtcMillis: Long, afterScope: String, afterKey: String, limit: Int): List<PreferenceEntity> =
        dbExecutor.submit(
            Callable { preferenceDao.syncPage(afterUpdatedAtUtcMillis, afterScope, afterKey, limit) }
        ).get()

    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterScope: String, afterKey: String): Long =
        dbExecutor.submit(
            Callable { preferenceDao.syncPendingCount(afterUpdatedAtUtcMillis, afterScope, afterKey) }
        ).get()

    // --- Proposals -------------------------------------------------------------

    /** The pending proposals the car's settings show as prompts. */
    fun pendingProposals(): List<PreferenceProposalEntity> =
        dbExecutor.submit(
            Callable { proposalDao.byStatus(PreferenceProposalEntity.STATUS_PENDING) }
        ).get()

    fun proposalById(id: String): PreferenceProposalEntity? =
        dbExecutor.submit(Callable { proposalDao.findById(id) }).get()

    /**
     * A proposal from the annotation channel. Only the control keys (see
     * [CONTROL_KEYS]) are proposals; anything else is refused rather than
     * stored, because an inert proposal for a key the phone writes directly
     * would surface as a prompt that should never have been one.
     */
    fun mergeIncomingProposal(row: Map<String, Any?>): Boolean {
        val id = (row["id"] as? String)?.takeIf { it.isNotBlank() } ?: return false
        val key = (row["key"] as? String)?.trim() ?: return false
        if (key !in CONTROL_KEYS) return false
        val proposedAtUtcMillis = (row["proposedAtUtcMillis"] as? Number)?.toLong() ?: return false
        val updatedAtUtcMillis = AnnotationConvergence.updatedAtUtcMillis(row) ?: return false
        val origin = AnnotationConvergence.origin(row) ?: AnnotationConvergence.ORIGIN_PHONE
        val incomingHlc = AnnotationHlc.fromRow(row)
            ?: AnnotationHlc(millis = updatedAtUtcMillis, counter = 0, deviceId = origin)
        val status = normalizeStatus(row["status"] as? String)

        return dbExecutor.submit(Callable {
            hlcClock.merge(incomingHlc)
            val existing = proposalDao.findById(id)
            if (existing != null && !AnnotationConvergence.shouldReplace(
                    existingHlc = AnnotationHlc(
                        millis = existing.hlcMillis,
                        counter = existing.hlcCounter,
                        deviceId = existing.hlcDeviceId,
                    ),
                    existingOrigin = existing.origin,
                    incomingHlc = incomingHlc,
                    incomingOrigin = origin
                )
            ) {
                return@Callable false
            }
            proposalDao.upsert(
                PreferenceProposalEntity(
                    id = id,
                    key = key,
                    value = row["value"] as? String,
                    status = status,
                    proposedAtUtcMillis = proposedAtUtcMillis,
                    decidedAtUtcMillis = (row["decidedAtUtcMillis"] as? Number)?.toLong(),
                    updatedAtUtcMillis = updatedAtUtcMillis,
                    origin = origin,
                    hlcMillis = incomingHlc.millis,
                    hlcCounter = incomingHlc.counter,
                    hlcDeviceId = incomingHlc.deviceId,
                    // The proposal was surfaced under the current pairing, so
                    // it is born owned by that account — the same rule as a
                    // car-side proposal, so no local write is ever unowned.
                    accountId = accountIdProvider()
                )
            )
            annotationChanges?.proposalsChanged()
            true
        }).get()
    }
    /**
     * The phone proposes. The car UI can too, which is how a person hands a
     * number to the car without finding the setting; the acceptance below
     * treats both the same.
     */
    fun propose(key: String, value: String?): PreferenceProposalEntity? {
        if (key !in CONTROL_KEYS) return null
        val now = clock()
        val hlc = hlcClock.tickAt(now)
        val row = PreferenceProposalEntity(
            id = UUID.randomUUID().toString(),
            key = key,
            value = value?.trim()?.takeIf { it.isNotEmpty() },
            status = PreferenceProposalEntity.STATUS_PENDING,
            proposedAtUtcMillis = now,
            decidedAtUtcMillis = null,
            updatedAtUtcMillis = now,
            origin = AnnotationConvergence.ORIGIN_CAR,
            hlcMillis = hlc.millis,
            hlcCounter = hlc.counter,
            hlcDeviceId = hlc.deviceId,
            accountId = accountIdProvider(),
        )
        dbExecutor.submit<Unit> {
            proposalDao.upsert(row)
            annotationChanges?.proposalsChanged()
        }.get()
        return row
    }

    /**
     * The car decides. Acceptance runs the normal write path through
     * [proposalAcceptedHandler]; a write that cannot run turns the
     * acceptance into a refusal. Refusal discards, and the discard syncs
     * back, so the prompt does not resurface.
     */
    fun decide(id: String, accept: Boolean): PreferenceProposalEntity? {
        require(id.isNotBlank()) { "decide requires a proposal id" }
        return dbExecutor.submit(Callable {
            val existing = proposalDao.findById(id) ?: return@Callable null
            if (existing.status != PreferenceProposalEntity.STATUS_PENDING) return@Callable existing

            val now = clock()
            val hlc = hlcClock.tickAt(now)
            val accepted = accept && proposalAcceptedHandler(existing.key, existing.value)
            val decided = existing.copy(
                status = if (accepted) {
                    PreferenceProposalEntity.STATUS_ACCEPTED
                } else {
                    PreferenceProposalEntity.STATUS_REFUSED
                },
                decidedAtUtcMillis = now,
                updatedAtUtcMillis = now,
                origin = AnnotationConvergence.ORIGIN_CAR,
                hlcMillis = hlc.millis,
                hlcCounter = hlc.counter,
                hlcDeviceId = hlc.deviceId
            )
            proposalDao.upsert(decided)
            annotationChanges?.proposalsChanged()
            decided
        }).get()
    }

    fun proposalSyncPage(afterUpdatedAtUtcMillis: Long, afterId: String, limit: Int): List<PreferenceProposalEntity> =
        dbExecutor.submit(
            Callable { proposalDao.syncPage(afterUpdatedAtUtcMillis, afterId, limit) }
        ).get()

    fun proposalSyncPendingCount(afterUpdatedAtUtcMillis: Long, afterId: String): Long =
        dbExecutor.submit(
            Callable { proposalDao.syncPendingCount(afterUpdatedAtUtcMillis, afterId) }
        ).get()

    private fun normalizeStatus(raw: String?): String = when (raw?.uppercase()) {
        PreferenceProposalEntity.STATUS_ACCEPTED -> PreferenceProposalEntity.STATUS_ACCEPTED
        PreferenceProposalEntity.STATUS_REFUSED -> PreferenceProposalEntity.STATUS_REFUSED
        else -> PreferenceProposalEntity.STATUS_PENDING
    }
}
