package com.timhss.capyenergy.service

import com.timhss.capyenergy.projection.PresenceState
import com.timhss.capyenergy.projection.ProjectionPresenceSnapshot
import com.timhss.capyenergy.service.ProjectionAutoOpenSupervisor.Companion.arrivalDestination
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The supervisor takes the display from the driver, so the edge it acts on is
 * the whole rule. `AppShellV2._arrivedTab` states the same one in Dart, and the
 * two must agree: they act on one event.
 */
class ProjectionAutoOpenSupervisorTest {

    private fun presence(
        carplay: PresenceState = PresenceState.UNKNOWN,
        androidAuto: PresenceState = PresenceState.UNKNOWN
    ) = ProjectionPresenceSnapshot(
        carplay = carplay,
        androidAuto = androidAuto,
        carplayAvailable = true,
        androidAutoAvailable = true,
        carplayEdgeAt = null,
        androidAutoEdgeAt = null
    )

    @Test
    fun `a phone that arrives opens its own tab`() {
        assertEquals(
            AutoOpenLauncher.DESTINATION_CARPLAY,
            arrivalDestination(
                presence(carplay = PresenceState.DISCONNECTED),
                presence(carplay = PresenceState.CONNECTED)
            )
        )
        assertEquals(
            AutoOpenLauncher.DESTINATION_ANDROID_AUTO,
            arrivalDestination(
                presence(androidAuto = PresenceState.DISCONNECTED),
                presence(androidAuto = PresenceState.CONNECTED)
            )
        )
    }

    @Test
    fun `a phone that was already there is not an arrival`() {
        // The first reading of a run. It describes a phone connected before
        // this app looked, at a boot or when the beta was switched on, and
        // taking the display for it would claim something just happened.
        assertNull(
            arrivalDestination(
                presence(carplay = PresenceState.UNKNOWN),
                presence(carplay = PresenceState.CONNECTED)
            )
        )
    }

    @Test
    fun `a phone that stays connected is not a second arrival`() {
        assertNull(
            arrivalDestination(
                presence(carplay = PresenceState.CONNECTED),
                presence(carplay = PresenceState.CONNECTED)
            )
        )
    }

    @Test
    fun `a phone that leaves opens nothing`() {
        assertNull(
            arrivalDestination(
                presence(androidAuto = PresenceState.CONNECTED),
                presence(androidAuto = PresenceState.DISCONNECTED)
            )
        )
    }

    @Test
    fun `CarPlay is answered first when both arrive in one reading`() {
        // One snapshot carries both protocols, so the two can step together.
        // Only one tab can be opened, and the order must be stated rather than
        // left to whichever field is read first.
        assertEquals(
            AutoOpenLauncher.DESTINATION_CARPLAY,
            arrivalDestination(
                presence(
                    carplay = PresenceState.DISCONNECTED,
                    androidAuto = PresenceState.DISCONNECTED
                ),
                presence(
                    carplay = PresenceState.CONNECTED,
                    androidAuto = PresenceState.CONNECTED
                )
            )
        )
    }
}
