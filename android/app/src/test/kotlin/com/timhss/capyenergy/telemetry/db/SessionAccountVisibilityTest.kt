package com.timhss.capyenergy.telemetry.db

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The privacy guarantee of `gb236-p4-local-account-stamp`, pinned on the JVM.
 *
 * `listSessionsSatisfyingAccount` / `countSessionsSatisfyingAccount` build
 * their `WHERE` from [SessionAccountVisibility.ACCOUNT_PREDICATE]; this test
 * asserts both the predicate text and the equivalent pure rule. The first
 * half fails if anyone removes the `accountId IS NULL` branch — the whole
 * point is that an unowned row (a car used before pairing, or a row written
 * while unpaired) is adopted by the first account that claims the car, and a
 * stamped row is never re-stamped or shown to another account. The DAO query
 * that uses the constant is the enforcement point the device runs; the pure
 * function is the same rule runnable on the JVM.
 */
class SessionAccountVisibilityTest {

    @Test
    fun `an unowned row is adopted by the first account that claims the car`() {
        assertTrue(SessionAccountVisibility.visible(rowAccountId = null, currentAccountId = "acc-a"))
        assertTrue(SessionAccountVisibility.visible(rowAccountId = null, currentAccountId = "acc-b"))
    }

    @Test
    fun `a row stamped to the current account stays visible`() {
        assertTrue(SessionAccountVisibility.visible(rowAccountId = "acc-a", currentAccountId = "acc-a"))
    }

    @Test
    fun `a row stamped to another account is never visible`() {
        assertFalse(SessionAccountVisibility.visible(rowAccountId = "acc-a", currentAccountId = "acc-b"))
        // The same rule with no current account: a device that lost its
        // pairing must not show history that owns itself to someone else.
        assertFalse(SessionAccountVisibility.visible(rowAccountId = "acc-a", currentAccountId = null))
    }

    @Test
    fun `the DAO predicate keeps the unowned branch`() {
        // Removing the `accountId IS NULL` half re-opens the transfer leak:
        // a car used before pairing would appear to have lost its history,
        // and a stamp that was never written for the old account would leave
        // rows invisible to everyone. This is the guarantee that must fail
        // loudly if the null predicate is dropped.
        assertTrue(
            "the account predicate must retain the unowned adoption branch",
            SessionAccountVisibility.ACCOUNT_PREDICATE.contains("accountId IS NULL")
        )
        assertTrue(
            SessionAccountVisibility.ACCOUNT_PREDICATE.contains("accountId = :accountId")
        )
    }
}