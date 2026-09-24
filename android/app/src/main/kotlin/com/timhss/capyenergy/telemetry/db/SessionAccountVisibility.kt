package com.timhss.capyenergy.telemetry.db

/**
 * The local ownership rule for reading rows (`gb236-p4-local-account-stamp`).
 *
 * The DAO account-filter queries build their `WHERE` from [ACCOUNT_PREDICATE];
 * [visible] is the same rule as a JVM-runnable function so the privacy
 * guarantee can be pinned without an Android device. Both spell one contract:
 *
 *   a row with no account is adopted by the first account that claims the
 *   car — the exact `account_id IS NULL` predicate the cloud's claim
 *   backfill proved (PR #281/#282) — and a row that already carries an
 *   account is never shown to a different one.
 *
 * Removing the `accountId IS NULL` half of [ACCOUNT_PREDICATE] fails
 * `SessionAccountVisibilityTest` and, with it, the whole privacy guarantee.
 */
internal object SessionAccountVisibility {
    const val ACCOUNT_PREDICATE = "(accountId IS NULL OR accountId = :accountId)"

    fun visible(rowAccountId: String?, currentAccountId: String?): Boolean =
        rowAccountId == null || rowAccountId == currentAccountId
}