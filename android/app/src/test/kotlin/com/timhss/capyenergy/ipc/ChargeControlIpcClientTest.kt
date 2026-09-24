package com.timhss.capyenergy.ipc

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import com.timhss.capyenergy.telemetry.FakeSettingsContext
import com.timhss.capyenergy.telemetry.TelemetrySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChargeControlIpcClientTest {

    private class TestContext : FakeSettingsContext() {
        var registerCalled = false
        var sendBroadcastCalled = false
        var lastIntent: Intent? = null
        var lastPermission: String? = null

        override fun registerReceiver(
            receiver: BroadcastReceiver?,
            filter: IntentFilter?,
            broadcastPermission: String?,
            scheduler: android.os.Handler?
        ): Intent? {
            registerCalled = true
            return null
        }

        override fun registerReceiver(receiver: BroadcastReceiver?, filter: IntentFilter?): Intent? {
            registerCalled = true
            return null
        }

        override fun unregisterReceiver(receiver: BroadcastReceiver?) {
            registerCalled = false
        }

        override fun sendBroadcast(intent: Intent?) {
            sendBroadcastCalled = true
            lastIntent = intent
        }

        override fun sendBroadcast(intent: Intent?, receiverPermission: String?) {
            sendBroadcastCalled = true
            lastIntent = intent
            lastPermission = receiverPermission
        }
    }

    @Test
    fun sendsSetChargeLimitBroadcast() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(true)
        val client = ChargeControlIpcClient(context, settings)

        client.setTargetSoc(85)

        assertEquals(85, settings.chargeTargetSocPercent())
        assertTrue(context.sendBroadcastCalled)
        assertEquals(ChargeControlIpcClient.PERMISSION_CHARGE_CONTROL, context.lastPermission)
    }

    @Test
    fun sendsQueryStateBroadcastOnStart() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(true)
        val client = ChargeControlIpcClient(context, settings)

        client.start()

        assertTrue(context.registerCalled)
        assertTrue(context.sendBroadcastCalled)
        assertEquals(ChargeControlIpcClient.PERMISSION_CHARGE_CONTROL, context.lastPermission)
    }

    @Test
    fun clampsTargetSocBetween50And100() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(true)
        val client = ChargeControlIpcClient(context, settings)

        client.setTargetSoc(30)
        assertEquals(50, settings.chargeTargetSocPercent())

        client.setTargetSoc(120)
        assertEquals(100, settings.chargeTargetSocPercent())
    }

    /**
     * Sending is not confirming. The screen must keep showing what the car
     * last read back until Geely Charge Control answers, or a control that
     * failed still looks like it worked.
     */
    @Test
    fun sendsSetAmperageBroadcastWithoutClaimingTheCarAccepted() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(true)
        val client = ChargeControlIpcClient(context, settings)

        client.setAmperage(8)

        assertTrue(context.sendBroadcastCalled)
        assertNull("no read-back yet, so no amperage to show", client.getState().amps)
        assertEquals(ChargeControlIpcClient.PERMISSION_CHARGE_CONTROL, context.lastPermission)
    }

    @Test
    fun sendsSetForceChargingBroadcastWithoutClaimingTheCarAccepted() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(true)
        val client = ChargeControlIpcClient(context, settings)

        client.setForceCharging(true)

        assertTrue(context.sendBroadcastCalled)
        assertFalse("the mode is on only once the car releases the switches", client.getState().forceCharging)
        assertEquals(ChargeControlIpcClient.PERMISSION_CHARGE_CONTROL, context.lastPermission)
    }

    /** The regression: a refused reply must not become the shown state. */
    @Test
    fun aRefusedReplyLeavesTheShownStateAlone() {
        val confirmed = ChargeControlIpcState()
            .merge(ChargeControlReply(success = true, amps = 6, minAmps = 5, maxAmps = 32))
        assertEquals(6, confirmed.amps)

        val afterFailure = confirmed.merge(
            ChargeControlReply(
                success = false,
                // The old contract echoed the requested value back here.
                amps = 8,
                error = "Sem conexão com o veículo"
            )
        )

        assertEquals("the last confirmed reading stands", 6, afterFailure.amps)
        assertFalse(afterFailure.lastCommandOk)
        assertEquals("Sem conexão com o veículo", afterFailure.lastError)
    }

    /** A reply that omits a value leaves that value untouched. */
    @Test
    fun anAbsentAmperageDoesNotWipeTheLastReading() {
        val confirmed = ChargeControlIpcState().merge(ChargeControlReply(success = true, amps = 6))
        val afterQuery = confirmed.merge(ChargeControlReply(success = true, targetSoc = 90))

        assertEquals(6, afterQuery.amps)
        assertEquals(90, afterQuery.targetSoc)
    }

    /** A force-charging mode the car did not confirm is never shown as on. */
    @Test
    fun forceChargingIsOnlyShownWhenTheReplyConfirmsIt() {
        val refused = ChargeControlIpcState().merge(
            ChargeControlReply(success = false, forceCharging = true, error = "Sem conexão com o veículo")
        )
        assertFalse(refused.forceCharging)

        val confirmedOn = ChargeControlIpcState().merge(
            ChargeControlReply(success = true, forceCharging = true)
        )
        assertTrue(confirmedOn.forceCharging)
    }

    /** A target outside the limiter's range is not a target. */
    @Test
    fun anOutOfRangeTargetIsIgnored() {
        val state = ChargeControlIpcState(targetSoc = 80)
        assertEquals(80, state.merge(ChargeControlReply(success = true, targetSoc = 20)).targetSoc)
        assertEquals(90, state.merge(ChargeControlReply(success = true, targetSoc = 90)).targetSoc)
    }

    @Test
    fun sendsStopChargingBroadcast() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(true)
        val client = ChargeControlIpcClient(context, settings)

        client.stopCharging()

        assertTrue(context.sendBroadcastCalled)
        assertEquals(ChargeControlIpcClient.PERMISSION_CHARGE_CONTROL, context.lastPermission)
    }

    // --- The switch ---------------------------------------------------------
    //
    // While external charge control is off, Capy Energy is a telemetry
    // analyser and nothing else. It neither speaks to Geely Charge Control nor
    // listens to it.

    @Test
    fun aCommandIsNotSentWhileExternalChargeControlIsOff() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(false)
        val client = ChargeControlIpcClient(context, settings)

        client.setAmperage(8)
        client.setForceCharging(true)
        client.stopCharging()
        client.queryState()

        assertFalse("the switch is off, so nothing may reach the control app", context.sendBroadcastCalled)
    }

    @Test
    fun startDoesNotRegisterWhileExternalChargeControlIsOff() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(false)
        val client = ChargeControlIpcClient(context, settings)

        client.start()

        assertFalse(context.registerCalled)
        assertFalse(context.sendBroadcastCalled)
    }

    @Test
    fun turningTheSwitchOffUnregistersAndDropsTheReadings() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(true)
        val client = ChargeControlIpcClient(context, settings)
        client.start()
        assertTrue(context.registerCalled)

        settings.setExternalChargeControlEnabled(false)
        client.syncToSetting()

        assertFalse("the link is closed", context.registerCalled)
        assertNull("a reading with no source is not a reading", client.getState().amps)
    }

    @Test
    fun turningTheSwitchBackOnOpensTheLinkAgain() {
        val context = TestContext()
        val settings = TelemetrySettings(context)
        settings.setExternalChargeControlEnabled(false)
        val client = ChargeControlIpcClient(context, settings)
        client.syncToSetting()
        assertFalse(context.registerCalled)

        settings.setExternalChargeControlEnabled(true)
        client.syncToSetting()

        assertTrue(context.registerCalled)
        assertTrue(context.sendBroadcastCalled)
    }
}
