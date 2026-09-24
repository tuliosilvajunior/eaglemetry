package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The gate that decides which account stamps a local row.
 *
 * Every writer and every reader routes through [AccountIdProvider.of]: the
 * session/interval/track/event/cycle repositories on the way in, and the
 * session list on the way out. So this small object carries the whole privacy
 * contract's authority, and these four rules are the ones that matter:
 *
 *  - only an approved pairing names an account (a registered-but-unclaimed
 *    car, an unpaired car and a revoked car all write unowned rows — the
 *    cloud's claim adopts them later);
 *  - the cloud gate participates (a build with the cloud off performs
 *    exactly as before).
 */
class AccountIdProviderTest {

    @Test
    fun `approved pairing names the account`() {
        assertEquals(
            "acc-a",
            AccountIdProvider.of(
                cloudSyncEnabled = true,
                pairingStatus = TelemetrySettings.PAIRING_STATUS_APPROVED,
                accountId = "acc-a"
            )
        )
    }

    @Test
    fun `registered but unclaimed car writes unowned`() {
        assertNull(
            AccountIdProvider.of(
                cloudSyncEnabled = true,
                pairingStatus = TelemetrySettings.PAIRING_STATUS_REGISTERED,
                accountId = "acc-a"
            )
        )
    }

    @Test
    fun `unpaired and revoked cars write unowned`() {
        assertNull(
            AccountIdProvider.of(
                cloudSyncEnabled = true,
                pairingStatus = TelemetrySettings.PAIRING_STATUS_UNPAIRED,
                accountId = "acc-a"
            )
        )
        assertNull(
            AccountIdProvider.of(
                cloudSyncEnabled = true,
                pairingStatus = TelemetrySettings.PAIRING_STATUS_REVOKED,
                accountId = "acc-a"
            )
        )
    }

    @Test
    fun `cloud gate off behaves exactly as before`() {
        assertNull(
            AccountIdProvider.of(
                cloudSyncEnabled = false,
                pairingStatus = TelemetrySettings.PAIRING_STATUS_APPROVED,
                accountId = "acc-a"
            )
        )
    }
}