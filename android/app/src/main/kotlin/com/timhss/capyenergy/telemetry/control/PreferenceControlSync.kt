package com.timhss.capyenergy.telemetry.control

import com.timhss.capyenergy.telemetry.AnnotationConvergence
import com.timhss.capyenergy.telemetry.PreferenceRepository
import com.timhss.capyenergy.telemetry.db.PreferenceProposalDao
import com.timhss.capyenergy.telemetry.db.PreferenceProposalEntity

/**
 * Result of one [PreferenceControlSync.sync] run.
 */
data class PreferenceControlSyncReport(
    /** New pending proposals surfaced from the cloud (read path). */
    val surfaced: Int = 0,
    /** Decision rows written to `preference_reported` (write path). */
    val reported: Int = 0,
) {
    val movedNothing: Boolean get() = surfaced == 0 && reported == 0
}

/**
 * The car's Lane C control-plane sync, additive beside the local mDNS
 * proposal channel.
 *
 * Two halves, both scoped by the car's device token:
 *
 * **Write path.** Every locally terminal proposal (a `decide(id, accept)`
 * already ran) that the car has not yet reported to `preference_reported`
 * is uploaded — a plain upsert keyed on
 * `(vehicle_id, key, decided_at_utc_millis)`, `merge = false`. The ledger
 * ([ReportedDecisionStore]) is updated only after the cloud accepts, so a
 * failed report is retried next pass and a successful one is never re-sent.
 * The write runs first: once a decision is reported, the read below treats
 * the desire as covered and will not surface it again.
 *
 * **Read path.** The car fetches `preference_desired` for its own vehicle
 * and surfaces each desire that has no matching decision yet — the car has
 * no report for the key, or its report predates this desire (the desire is
 * new or superseded, exactly the derivation of the `preference_control_status`
 * view). Surfacing reuses [PreferenceRepository.mergeIncomingProposal], so a
 * cloud desire enters the exact same pending-proposal table the local channel
 * writes and the settings screen already reads — unchanged UI. A desire is
 * skipped when the key already has a pending prompt or the same cloud desire
 * was already surfaced once.
 *
 * The component never decides for itself: it reports, it surfaces. The human
 * decision still runs through [PreferenceRepository.decide]. This is the
 * "never auto-apply, never merge" boundary of issue #227.
 *
 * The cloud path is inert by the same rule the rest of the car's cloud stack
 * uses (Lane A/B - "L-1"): without a paired car_token and wired Supabase
 * credentials, [PreferenceControlCloud.isConfigured] is false and a pass
 * moves nothing.
 */
class PreferenceControlSync(
    private val cloud: PreferenceControlCloud,
    private val proposalDao: PreferenceProposalDao,
    private val surfaceProposal: (Map<String, Any?>) -> Boolean,
    private val reportedStore: ReportedDecisionStore,
    private val vehicleIdProvider: () -> String?,
    private val accountIdProvider: () -> String?,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /**
     * One pass: drains unreported local decisions, then surfaces uncovered
     * cloud desires.
     *
     * @throws PreferenceControlCloudException when a cloud call fails; the
     *   caller logs and the next pass retries. A failure never marks a
     *   decision reported and never downgrades a local row.
     */
    suspend fun sync(): PreferenceControlSyncReport {
        val vehicleId = vehicleIdProvider() ?: return empty()
        val accountId = accountIdProvider() ?: return empty()
        if (!cloud.isConfigured) return empty()

        var firstFailure: PreferenceControlCloudException? = null
        val reported = drainPendingReports(vehicleId, accountId, cloudFailure = { firstFailure = it })

        val surfaced = try {
            surfaceUncoveredDesires(vehicleId, cloudFailure = { firstFailure = it })
        } catch (e: PreferenceControlCloudException) {
            firstFailure = e
            0
        }

        firstFailure?.let { throw it }
        return PreferenceControlSyncReport(surfaced = surfaced, reported = reported)
    }

    private fun empty(): PreferenceControlSyncReport = PreferenceControlSyncReport()

    private suspend fun drainPendingReports(
        vehicleId: String,
        accountId: String,
        cloudFailure: (PreferenceControlCloudException) -> Unit,
    ): Int {
        val terminal = proposalDao.all().filter {
            it.status in TERMINAL_STATUSES && it.decidedAtUtcMillis != null
        }
        val pending = terminal.filterNot { reportedStore.contains(it.key, it.decidedAtUtcMillis!!) }
        if (pending.isEmpty()) return 0

        val now = clock()
        val rows = pending.map { proposal ->
            PreferenceReportedRow(
                vehicleId = vehicleId,
                accountId = accountId,
                key = proposal.key,
                value = proposal.value,
                status = when (proposal.status) {
                    PreferenceProposalEntity.STATUS_ACCEPTED -> PreferenceReportedRow.STATUS_ACCEPTED
                    else -> PreferenceReportedRow.STATUS_REFUSED
                },
                decidedAtUtcMillis = proposal.decidedAtUtcMillis!!,
                reportedAtUtcMillis = now,
            )
        }
        try {
            cloud.report(rows)
        } catch (e: Exception) {
            cloudFailure(
                PreferenceControlCloudException(e, retryable = PreferenceControlCloudException.isRetryable(e))
            )
            return 0
        }
        pending.forEach { reportedStore.add(it.key, it.decidedAtUtcMillis!!) }
        return pending.size
    }

    private suspend fun surfaceUncoveredDesires(
        vehicleId: String,
        cloudFailure: (PreferenceControlCloudException) -> Unit,
    ): Int {
        val desired = try {
            cloud.desiredForVehicle(vehicleId)
        } catch (e: Exception) {
            cloudFailure(
                PreferenceControlCloudException(e, retryable = PreferenceControlCloudException.isRetryable(e))
            )
            return 0
        }
        val reported = try {
            cloud.reportedForVehicle(vehicleId)
        } catch (e: Exception) {
            cloudFailure(
                PreferenceControlCloudException(e, retryable = PreferenceControlCloudException.isRetryable(e))
            )
            return 0
        }

        val pendingKeys = proposalDao.byStatus(PreferenceProposalEntity.STATUS_PENDING)
            .map { it.key }
            .toSet()

        var surfaced = 0
        for (desire in desired) {
            if (desire.key !in PreferenceRepository.CONTROL_KEYS) continue
            // A decision (for this key) that is at least as new as the desire
            // already covers it; a decision older than the desire means the
            // desire is fresh or superseded. Mirrors the view's `stale` rule.
            val covered = reported.any {
                it.key == desire.key && it.decidedAtUtcMillis >= desire.proposedAtUtcMillis
            }
            if (covered) continue
            // A prompt is already open for this control; let the human finish it.
            if (desire.key in pendingKeys) continue
            // The same cloud desire surfaced once stays surfaced — never twice.
            val derivedId = "cloud:${desire.key}:${desire.proposedAtUtcMillis}"
            if (proposalDao.findById(derivedId) != null) continue

            val row = mapOf(
                "id" to derivedId,
                "key" to desire.key,
                "value" to desire.value,
                "status" to PreferenceProposalEntity.STATUS_PENDING,
                "proposedAtUtcMillis" to desire.proposedAtUtcMillis,
                "updatedAtUtcMillis" to desire.proposedAtUtcMillis,
                "origin" to AnnotationConvergence.ORIGIN_PHONE,
            )
            if (surfaceProposal(row)) surfaced++
        }
        return surfaced
    }

    companion object {
        private val TERMINAL_STATUSES = setOf(
            PreferenceProposalEntity.STATUS_ACCEPTED,
            PreferenceProposalEntity.STATUS_REFUSED,
        )
    }
}