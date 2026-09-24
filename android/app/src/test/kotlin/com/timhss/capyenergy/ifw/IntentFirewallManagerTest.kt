package com.timhss.capyenergy.ifw

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rules are installed through a root shell, so the command and the XML are
 * what decide whether the block works on the car. Both are pure strings, and
 * both are pinned here rather than being read from a log after a reboot.
 */
class IntentFirewallManagerTest {

    @Test
    fun `install command writes the rule where the framework reads it`() {
        val command = IntentFirewallManager.installRuleCommand(
            "/data/data/com.timhss.capy/cache/staging.xml",
            "${IntentFirewallManager.IFW_DIR}/rule.xml"
        )

        assertTrue(command.contains("mkdir -p /data/system/ifw"))
        // 644 and system:system are required by the framework: it ignores a
        // file it cannot read, and it does so silently.
        assertTrue(command.contains("chmod 644 '/data/system/ifw/rule.xml'"))
        assertTrue(command.contains("chown system:system '/data/system/ifw/rule.xml'"))
        // The marker is how a shell that printed an error is told from one that
        // worked; the shell reports no exit status back to the app.
        assertTrue(command.endsWith("echo IFW_RULE_INSTALLED"))
    }

    @Test
    fun `a quote in a path cannot end the quoted argument`() {
        val command = IntentFirewallManager.installRuleCommand(
            "/cache/it's.xml",
            "/data/system/ifw/rule.xml"
        )

        assertTrue(command.contains("""cp '/cache/it'"'"'s.xml'"""))
    }

    @Test
    fun `remove command deletes the rule and reports it`() {
        assertEquals(
            "rm -f '/data/system/ifw/rule.xml' && echo IFW_RULE_REMOVED",
            IntentFirewallManager.removeRuleCommand("/data/system/ifw/rule.xml")
        )
    }

    @Test
    fun `the AutoEnergy rule blocks the popup and not the launcher`() {
        val xml = IntentFirewallManager.AUTOENERGY_RULE_XML

        assertTrue(xml.contains("""<activity block="true""""))
        assertTrue(xml.contains("""<action name="com.flyme.auto.energy.ENERGY" />"""))
        // No component filter, and this is the whole point of the rule. The
        // firewall combines the two filters with OR, so a rule that names
        // EnergyActivity blocks the launcher as well, and the user then has no
        // way at all to open the factory app.
        assertTrue(!xml.contains("component-filter"))
        assertTrue(!xml.contains("android.intent.action.MAIN"))
    }

    @Test
    fun `clean projection rules command removes the projection rule file`() {
        val command = IntentFirewallManager.cleanProjectionRulesCommand()
        assertEquals(
            "rm -f '${IntentFirewallManager.PROJECTION_RULE_FILE}' && echo IFW_RULE_REMOVED",
            command
        )
    }
}
