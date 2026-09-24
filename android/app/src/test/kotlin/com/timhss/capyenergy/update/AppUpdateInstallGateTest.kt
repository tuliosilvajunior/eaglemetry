package com.timhss.capyenergy.update

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdateInstallGateTest {
    @After
    fun tearDown() {
        AppUpdateInstallGate.forgetScheduled()
    }

    @Test
    fun `blocks a second acquire until the first releases`() {
        assertTrue(AppUpdateInstallGate.tryAcquire())
        try {
            assertFalse(AppUpdateInstallGate.tryAcquire())
        } finally {
            AppUpdateInstallGate.release()
        }

        assertTrue(AppUpdateInstallGate.tryAcquire())
        AppUpdateInstallGate.release()
    }

    @Test
    fun `reports only the version code it scheduled`() {
        assertFalse(AppUpdateInstallGate.isScheduled(42L))

        AppUpdateInstallGate.markScheduled(42L)

        assertTrue(AppUpdateInstallGate.isScheduled(42L))
        assertFalse(AppUpdateInstallGate.isScheduled(43L))
    }

    @Test
    fun `treats an unknown version code as not scheduled`() {
        AppUpdateInstallGate.markScheduled(42L)

        assertFalse(AppUpdateInstallGate.isScheduled(null))
    }

    @Test
    fun `forgets the scheduled version so a later install can retry`() {
        AppUpdateInstallGate.markScheduled(42L)

        AppUpdateInstallGate.forgetScheduled()

        assertFalse(AppUpdateInstallGate.isScheduled(42L))
    }
}
