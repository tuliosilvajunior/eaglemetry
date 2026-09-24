package com.timhss.capyenergy.ifw

import android.content.Context
import android.util.Log
import com.timhss.capyenergy.roadcast.LocalAdbShell
import java.io.File

/**
 * Writes the Intent Firewall rules that suppress the factory auto-open screens.
 *
 * The framework reads `/data/system/ifw` at boot and on change, and it blocks
 * the matched intent before the app sees it. That is why this suppresses the
 * screen without stopping the OEM services: charging still reports to the
 * cluster, and a projected phone still plays audio and takes calls.
 *
 * `internal`, like the shell it writes through: this is not part of the app's
 * public surface, and the module is the boundary.
 */
internal class IntentFirewallManager(
    private val context: Context,
    private val localAdb: LocalAdbShell = LocalAdbShell()
) {
    companion object {
        private const val TAG = "IntentFirewallManager"
        const val IFW_DIR = "/data/system/ifw"
        const val AUTOENERGY_RULE_FILE = "$IFW_DIR/ifw_block_autoenergy.xml"
        const val PROJECTION_RULE_FILE = "$IFW_DIR/ifw_block_projection.xml"

        /**
         * The action, and **not** the component.
         *
         * The firewall combines `<intent-filter>` and `<component-filter>` with
         * OR: `checkIntent` collects the rules that match the intent, then adds
         * the rules that match the resolved component. A rule that names
         * `EnergyActivity` therefore blocks every start of that activity,
         * including the `MAIN` intent of the launcher, which takes the factory
         * app away from the user completely.
         *
         * The action alone is exactly the automatic trigger. `EnergyService`
         * starts the screen with an implicit intent that carries only this
         * action, and the launcher does not use it.
         */
        val AUTOENERGY_RULE_XML = """
            <rules>
                <activity block="true" log="true">
                    <intent-filter>
                        <action name="com.flyme.auto.energy.ENERGY" />
                    </intent-filter>
                </activity>
            </rules>
        """.trimIndent()

        internal fun installRuleCommand(stagingPath: String, targetPath: String): String {
            val quotedStaging = shellSingleQuote(stagingPath)
            val quotedTarget = shellSingleQuote(targetPath)
            return "mkdir -p $IFW_DIR && " +
                    "cp '$quotedStaging' '$quotedTarget' && " +
                    "chmod 644 '$quotedTarget' && " +
                    "chown system:system '$quotedTarget' && " +
                    "echo IFW_RULE_INSTALLED"
        }

        internal fun removeRuleCommand(targetPath: String): String {
            val quotedTarget = shellSingleQuote(targetPath)
            return "rm -f '$quotedTarget' && echo IFW_RULE_REMOVED"
        }

        internal fun cleanProjectionRulesCommand(): String {
            return removeRuleCommand(PROJECTION_RULE_FILE)
        }

        private fun shellSingleQuote(value: String): String =
            value.replace("'", "'\"'\"'")
    }

    fun setBlockAutoEnergy(enabled: Boolean): Boolean {
        return if (enabled) {
            writeRule(AUTOENERGY_RULE_FILE, AUTOENERGY_RULE_XML)
        } else {
            removeRule(AUTOENERGY_RULE_FILE)
        }
    }

    /**
     * Cleans up any projection firewall rules (CarPlay / Android Auto) from the device IFW.
     * Does not touch Auto Energy rules.
     */
    fun cleanProjectionRules(): Boolean {
        return removeRule(PROJECTION_RULE_FILE)
    }

    fun syncAll(blockAutoEnergy: Boolean) {
        try {
            setBlockAutoEnergy(blockAutoEnergy)
            cleanProjectionRules()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to sync IFW rules", e)
        }
    }

    private fun writeRule(targetPath: String, xmlContent: String): Boolean {
        val stagingFile = File(context.cacheDir, "ifw_staging_${System.currentTimeMillis()}.xml")
        return try {
            stagingFile.writeText(xmlContent, Charsets.UTF_8)
            val output = localAdb.execute(installRuleCommand(stagingFile.absolutePath, targetPath))
            val success = output.contains("IFW_RULE_INSTALLED")
            if (!success) {
                Log.w(TAG, "IFW write returned unexpected output: $output")
            }
            success
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write IFW rule: $targetPath", e)
            false
        } finally {
            stagingFile.delete()
        }
    }

    private fun removeRule(targetPath: String): Boolean {
        return try {
            val output = localAdb.execute(removeRuleCommand(targetPath))
            val success = output.contains("IFW_RULE_REMOVED")
            if (!success) {
                Log.w(TAG, "IFW remove returned unexpected output: $output")
            }
            success
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove IFW rule: $targetPath", e)
            false
        }
    }
}
