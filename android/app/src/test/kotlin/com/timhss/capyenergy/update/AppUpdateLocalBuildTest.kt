package com.timhss.capyenergy.update

import android.content.pm.PackageInfo
import com.timhss.capyenergy.update.AppUpdateManager.Companion.LOCAL_BUILD_SUFFIX
import com.timhss.capyenergy.update.AppUpdateManager.Companion.isLocalBuild
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The mark that stops a working-tree build from updating itself.
 *
 * `scripts/install.sh` stamps the suffix on the version name. A build carrying
 * it has a version code from the working tree, not the release channel, so the
 * published build almost always looks newer — and installing it replaces both
 * the build under test and, on a schema downgrade, the recorded telemetry.
 */
class AppUpdateLocalBuildTest {
    private fun installed(versionName: String?) = PackageInfo().apply {
        this.versionName = versionName
    }

    @Test
    fun `a build the install script stamped is local`() {
        assertTrue(isLocalBuild(installed("0.22.2$LOCAL_BUILD_SUFFIX")))
    }

    @Test
    fun `a published build is not local`() {
        assertFalse(isLocalBuild(installed("0.22.2")))
    }

    @Test
    fun `a version name the platform did not report is not local`() {
        // Reading it as local would switch the watchdog off for every build
        // whose name failed to load. The published build has to keep updating.
        assertFalse(isLocalBuild(installed(null)))
    }

    @Test
    fun `the suffix has to be at the end, not anywhere in the name`() {
        assertFalse(isLocalBuild(installed("0.22.2${LOCAL_BUILD_SUFFIX}build.4")))
    }
}
