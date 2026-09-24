package com.timhss.capyenergy.telemetry


/**
 * The one authority for "which account is writing right now", for the local
 * ownership stamp (`gb236-p4-local-account-stamp`).
 *
 * It is the same rule the cloud uploaders already use: the account is the
 * pairing credential, and only an `approved` pairing names one. A
 * registered-but-unclaimed car, an unpaired car and a revoked car all answer
 * null, exactly like `TelemetryCloudUploader`'s `accountIdProvider` — so a
 * row written while the car is not claimed is born null and stays unowned
 * until the cloud's own claim adopts it. This provider never reads the cloud
 * and never decides ownership: the stamp it feeds is a default-guard, and
 * the stamping code re-stamps nothing (see `MIGRATION_44_45`).
 */
object AccountIdProvider {
    fun of(
        cloudSyncEnabled: Boolean,
        pairingStatus: String,
        accountId: String?,
    ): String? =
        if (cloudSyncEnabled && pairingStatus == TelemetrySettings.PAIRING_STATUS_APPROVED) {
            accountId?.takeIf { it.isNotBlank() }
        } else {
            null
        }
}