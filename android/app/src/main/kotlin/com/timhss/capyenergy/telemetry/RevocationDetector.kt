package com.timhss.capyenergy.telemetry

import android.util.Log
import com.timhss.capyenergy.telemetry.sync.CloudSink
import com.timhss.capyenergy.telemetry.sync.HttpCloudSinkException

/**
 * Phase 4 revocation detection and cutover signal driver (issue #236 P4-T1 / P4-T3).
 *
 * When an upload fails permanently with an RLS (Row Level Security) denial,
 * this driver transitions the pairing status to `revoked` and clears the
 * cutover flag on `phone_cutover_readiness`.
 *
 * It is a separate collaborator from [TelemetryRuntime] so its decision surface
 * is unit-testable in pure JVM without Room or Android system services:
 * - 403 / 401 with RLS body flips pairingStatus to `revoked`.
 * - Deployment-gap 403 without RLS body does not flip to `revoked`.
 * - Cutover readiness is written when active and cleared on revoke.
 */
internal class RevocationDetector(
    private val settings: TelemetrySettings,
    private val vehicleIdProvider: () -> String,
    private val cloudSinkProvider: () -> CloudSink,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {

    /**
     * Checks whether an upload failure is an RLS (Row Level Security) denial.
     *
     * Permanent 401/403 status codes from PostgREST when an RLS policy rejects
     * access contain text such as "violates row-level security", "row-level security",
     * "permission denied", or Postgres error code "42501".
     *
     * A deployment gap 403 (gateway, reverse proxy, cloudflare) without RLS
     * text must NOT be treated as RLS revocation.
     */
    fun isRlsDenial(error: Throwable): Boolean {
        var statusCode: Int? = null
        var cur: Throwable? = error
        while (cur != null) {
            if (cur is HttpCloudSinkException) {
                statusCode = cur.statusCode
                break
            }
            cur = cur.cause
        }
        val isAuthStatus = if (statusCode != null) {
            statusCode == 401 || statusCode == 403
        } else {
            var found = false
            var c: Throwable? = error
            while (c != null) {
                val msg = (c.message ?: "").lowercase()
                if (msg.contains("401") || msg.contains("403")) {
                    found = true
                    break
                }
                c = c.cause
            }
            found
        }
        if (!isAuthStatus) return false

        var c: Throwable? = error
        while (c != null) {
            val msg = (c.message ?: "").lowercase()
            if (msg.contains("row-level security") ||
                msg.contains("violates row-level security") ||
                msg.contains("42501") ||
                msg.contains("permission denied")
            ) {
                return true
            }
            c = c.cause
        }
        return false
    }

    /**
     * Handles a non-retryable upload failure. If the car holds a token and the
     * failure was an RLS denial, marks the credential as revoked.
     */
    fun handlePermanentUploadFailure(error: Throwable) {
        if (settings.carToken() != null && isRlsDenial(error)) {
            Log.w(TAG, "Cloud upload RLS denial detected while holding token; marking revoked", error)
            onRevoked()
        }
    }

    fun onRevoked() {
        // Best-effort attempt to clear cutover readiness on the cloud. If the
        // token is already rejected by RLS, this update fails safely without
        // throwing. The primary defense against stale readiness is the
        // companion's active-vehicle pairing check.
        runCatching {
            kotlinx.coroutines.runBlocking {
                updateCutoverReadiness(active = false)
            }
        }
        settings.markRevoked()
    }

    suspend fun updateCutoverReadiness(active: Boolean) {
        val accountId = settings.accountId() ?: return
        val vehicleId = vehicleIdProvider()
        if (vehicleId.isBlank() || vehicleId == "unassigned") return
        val row = mapOf(
            "account_id" to accountId,
            "vehicle_id" to vehicleId,
            "car_direct_upload_active" to active,
            "updated_at_utc_millis" to nowMillis()
        )
        try {
            cloudSinkProvider().upsert(
                table = "phone_cutover_readiness",
                rows = listOf(row),
                conflictColumns = listOf("account_id", "vehicle_id"),
                merge = true
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update cutover readiness car_direct_upload_active=$active", e)
        }
    }

    companion object {
        private const val TAG = "RevocationDetector"
    }
}
