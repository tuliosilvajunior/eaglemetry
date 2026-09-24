package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Regression for a charge session that spanned a head-unit reboot.
 *
 * The captured session ran 05/08 20:54:25 → 06/08 12:13:27. A reboot at
 * 10:11:15 split it across boots 109 and 110. On resume the session replayed
 * the start timestamp it was restored with — elapsed nanos read in boot 109 —
 * and the repository stamped the *current* boot onto them. That made the start
 * and the terminal timestamp look like one boot, so the reconciler rebuilt the
 * start from their 95 s elapsed delta and reported a 15 h charge as 95 s.
 */
class ChargeSessionRebootBootCountTest {
    private companion object {
        const val BOOT_BEFORE_REBOOT = 109
        const val BOOT_AFTER_REBOOT = 110

        /** 05/08 20:54:25 — the real charge start, read during boot 109. */
        const val START_UTC_MILLIS = 1_785_974_065_930L
        const val START_ELAPSED_NANOS = 7_236_068_549_269L

        /** 06/08 12:13:27 — plug removed, read during boot 110. */
        const val TERMINAL_UTC_MILLIS = 1_786_029_207_303L
        const val TERMINAL_ELAPSED_NANOS = 7_331_498_875_274L
    }

    @Test
    fun replayedStartKeepsTheBootThatReadItsElapsedNanos() {
        val bootCount = SessionTimeReconciler.boundBootCount(
            existing = BOOT_BEFORE_REBOOT,
            existingElapsedNanos = START_ELAPSED_NANOS,
            elapsedNanos = START_ELAPSED_NANOS,
            current = BOOT_AFTER_REBOOT
        )

        assertEquals(BOOT_BEFORE_REBOOT, bootCount)
    }

    @Test
    fun freshElapsedNanosTakeTheCurrentBoot() {
        val bootCount = SessionTimeReconciler.boundBootCount(
            existing = BOOT_BEFORE_REBOOT,
            existingElapsedNanos = START_ELAPSED_NANOS,
            elapsedNanos = TERMINAL_ELAPSED_NANOS,
            current = BOOT_AFTER_REBOOT
        )

        assertEquals(BOOT_AFTER_REBOOT, bootCount)
    }

    @Test
    fun mislabelledBootCollapsesFifteenHoursIntoNinetyFiveSeconds() {
        val collapsed = SessionTimeReconciler.reconcileStartUtcMillis(
            startUtcMillis = START_UTC_MILLIS,
            startElapsedNanos = START_ELAPSED_NANOS,
            startBootCount = BOOT_AFTER_REBOOT,
            endUtcMillis = TERMINAL_UTC_MILLIS,
            endElapsedNanos = TERMINAL_ELAPSED_NANOS,
            endBootCount = BOOT_AFTER_REBOOT
        )

        // The value this session actually stored: 06/08 12:11:51.
        assertEquals(1_786_029_111_873L, collapsed)
        assertEquals(95_430L, TERMINAL_UTC_MILLIS - collapsed)
    }

    @Test
    fun honestBootCountPreservesTheFifteenHourCharge() {
        val preserved = SessionTimeReconciler.reconcileStartUtcMillis(
            startUtcMillis = START_UTC_MILLIS,
            startElapsedNanos = START_ELAPSED_NANOS,
            startBootCount = SessionTimeReconciler.boundBootCount(
                existing = BOOT_BEFORE_REBOOT,
                existingElapsedNanos = START_ELAPSED_NANOS,
                elapsedNanos = START_ELAPSED_NANOS,
                current = BOOT_AFTER_REBOOT
            ),
            endUtcMillis = TERMINAL_UTC_MILLIS,
            endElapsedNanos = TERMINAL_ELAPSED_NANOS,
            endBootCount = BOOT_AFTER_REBOOT
        )

        assertEquals(START_UTC_MILLIS, preserved)
        assertEquals(15, (TERMINAL_UTC_MILLIS - preserved) / 3_600_000L)
    }
}
