package com.timhss.capyenergy.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.timhss.capyenergy.vehicle.VhalTestRunner

/**
 * adb-driven entry point for VHAL write experiments.
 *
 *     adb shell am broadcast -n com.timhss.capy/com.timhss.capyenergy.debug.VhalTestReceiver \
 *       --es token ex2-vhal-test --es op set --ei prop 557884292 --ei value 2
 *
 *
 * SECURITY: this receiver must be exported — `adb shell` runs as uid 2000 while
 * this app runs as uid 1000 (android.uid.system) — which puts a VHAL write path
 * behind a component any app could name. Two independent gates gate it: the
 * manifest requires `android.permission.DUMP` (held by shell, not by ordinary
 * apps) and every command must carry the shared [EXPECTED_TOKEN]. A request that
 * fails the token check is dropped silently, so probing reveals nothing.
 */
class VhalTestReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val token = intent.getStringExtra(EXTRA_TOKEN)
        if (token != EXPECTED_TOKEN) {
            Log.w(VhalTestRunner.LOG_TAG, "dropped command with missing or wrong token")
            return
        }

        val op = intent.getStringExtra(VhalTestService.EXTRA_OP)
        if (op.isNullOrBlank()) {
            Log.w(VhalTestRunner.LOG_TAG, "dropped command without op")
            return
        }

        // Forward to the service: a sweep runs for far longer than onReceive may live.
        VhalTestService.start(context.applicationContext) {
            putExtra(VhalTestService.EXTRA_OP, op)
            intent.getStringExtra(VhalTestService.EXTRA_PROP_HEX)?.let {
                putExtra(VhalTestService.EXTRA_PROP_HEX, it)
            }
            VhalTestService.FORWARDED_INT_EXTRAS.forEach { key ->
                if (intent.hasExtra(key)) putExtra(key, intent.getIntExtra(key, 0))
            }
        }
    }

    companion object {
        const val EXTRA_TOKEN = "token"

        /** Change this to invalidate every command line already in your shell history. */
        const val EXPECTED_TOKEN = "ex2-vhal-test"
    }
}
