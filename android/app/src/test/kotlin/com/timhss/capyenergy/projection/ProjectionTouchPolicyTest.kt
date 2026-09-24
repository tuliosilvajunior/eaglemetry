package com.timhss.capyenergy.projection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rules of the touch path, pinned.
 *
 * Every case here is one line of the reverse-engineering doc: the OEM CarPlay
 * handler drops every action >= 3 in silence, packs one pointer, and packs its
 * coordinates as 16-bit little-endian.
 */
class ProjectionTouchPolicyTest {

    private fun carplay() = ProjectionTouchPolicy(ProjectionStack.CARPLAY)
        .apply { setBufferSize(1920, 1080) }

    private fun auto() = ProjectionTouchPolicy(ProjectionStack.ANDROID_AUTO)
        .apply { setBufferSize(1920, 1080) }

    private fun request(
        stack: ProjectionStack,
        action: Int,
        vararg pointers: ProjectionTouchPointer,
        actionIndex: Int = 0,
    ) = ProjectionTouchRequest(stack, action, actionIndex, pointers.toList())

    private fun p(id: Int, x: Double, y: Double) = ProjectionTouchPointer(id, x, y)

    private fun sent(decision: ProjectionTouchDecision): ProjectionTouchDecision.Send {
        assertTrue("expected a send, got $decision", decision is ProjectionTouchDecision.Send)
        return decision as ProjectionTouchDecision.Send
    }

    private fun dropped(decision: ProjectionTouchDecision): String {
        assertTrue("expected a drop, got $decision", decision is ProjectionTouchDecision.Drop)
        return (decision as ProjectionTouchDecision.Drop).reason
    }

    private fun down(policy: ProjectionTouchPolicy, stack: ProjectionStack, id: Int = 1) =
        policy.decide(request(stack, ProjectionTouchAction.DOWN, p(id, 10.0, 20.0)))

    // --- The buffer gate ---

    @Test
    fun `refuses every touch until the buffer size is known`() {
        val policy = ProjectionTouchPolicy(ProjectionStack.CARPLAY)
        val decision = policy.decide(
            request(ProjectionStack.CARPLAY, ProjectionTouchAction.DOWN, p(1, 5.0, 5.0)),
        )
        assertEquals(ProjectionTouchDrop.BUFFER_UNKNOWN, dropped(decision))
    }

    @Test
    fun `a zero buffer size is refused, not stored`() {
        val policy = carplay()
        policy.setBufferSize(0, 1080)
        assertEquals(
            ProjectionTouchDrop.BUFFER_UNKNOWN,
            dropped(down(policy, ProjectionStack.CARPLAY)),
        )
    }

    // --- Clamping (the 16-bit wire) ---

    @Test
    fun `a coordinate outside the buffer is clamped into it`() {
        val policy = carplay()
        val decision = sent(
            policy.decide(
                request(ProjectionStack.CARPLAY, ProjectionTouchAction.DOWN, p(1, -12.0, 4000.0)),
            ),
        )
        assertEquals(0.0, decision.pointers.first().x, 0.0)
        assertEquals(1080.0, decision.pointers.first().y, 0.0)
    }

    @Test
    fun `a coordinate that is not finite is refused rather than clamped`() {
        val policy = carplay()
        val decision = policy.decide(
            request(ProjectionStack.CARPLAY, ProjectionTouchAction.DOWN, p(1, Double.NaN, 4.0)),
        )
        assertEquals(ProjectionTouchDrop.COORD_NOT_FINITE, dropped(decision))
    }

    // --- CANCEL never reaches the wire ---

    @Test
    fun `cancel becomes an up, because the OEM drops every action above two`() {
        val policy = carplay()
        down(policy, ProjectionStack.CARPLAY)
        val decision = sent(
            policy.decide(
                request(ProjectionStack.CARPLAY, ProjectionTouchAction.CANCEL, p(1, 8.0, 9.0)),
            ),
        )
        assertEquals(ProjectionTouchAction.UP, decision.action)
        assertTrue("the cancel must end the gesture", !policy.hasLivePointers)
    }

    // --- CarPlay is one finger ---

    @Test
    fun `carplay refuses a second finger and keeps the first`() {
        val policy = carplay()
        down(policy, ProjectionStack.CARPLAY, id = 1)
        val second = policy.decide(
            request(ProjectionStack.CARPLAY, ProjectionTouchAction.DOWN, p(2, 1.0, 1.0)),
        )
        assertEquals(ProjectionTouchDrop.SECOND_POINTER, dropped(second))
        // The first finger still moves.
        sent(policy.decide(request(ProjectionStack.CARPLAY, ProjectionTouchAction.MOVE, p(1, 2.0, 2.0))))
    }

    @Test
    fun `carplay refuses a pointer action outright`() {
        val policy = carplay()
        down(policy, ProjectionStack.CARPLAY)
        val decision = policy.decide(
            request(
                ProjectionStack.CARPLAY,
                ProjectionTouchAction.POINTER_DOWN,
                p(1, 1.0, 1.0), p(2, 2.0, 2.0),
                actionIndex = 1,
            ),
        )
        assertEquals(ProjectionTouchDrop.SECOND_POINTER, dropped(decision))
    }

    @Test
    fun `carplay refuses a move for a finger that never went down`() {
        val policy = carplay()
        val decision = policy.decide(
            request(ProjectionStack.CARPLAY, ProjectionTouchAction.MOVE, p(7, 1.0, 1.0)),
        )
        assertEquals(ProjectionTouchDrop.UNKNOWN_POINTER, dropped(decision))
    }

    @Test
    fun `a refused down does not hold the single-touch slot`() {
        val policy = carplay()
        val refused = policy.decide(
            request(ProjectionStack.CARPLAY, ProjectionTouchAction.DOWN, p(1, Double.NaN, 1.0)),
        )
        assertEquals(ProjectionTouchDrop.COORD_NOT_FINITE, dropped(refused))
        sent(down(policy, ProjectionStack.CARPLAY, id = 2))
    }

    @Test
    fun `an up releases the slot for the next gesture`() {
        val policy = carplay()
        down(policy, ProjectionStack.CARPLAY, id = 1)
        sent(policy.decide(request(ProjectionStack.CARPLAY, ProjectionTouchAction.UP, p(1, 3.0, 3.0))))
        sent(down(policy, ProjectionStack.CARPLAY, id = 2))
    }

    // --- Android Auto carries every finger ---

    @Test
    fun `android auto forwards a second finger with its index`() {
        val policy = auto()
        down(policy, ProjectionStack.ANDROID_AUTO, id = 1)
        val decision = sent(
            policy.decide(
                request(
                    ProjectionStack.ANDROID_AUTO,
                    ProjectionTouchAction.POINTER_DOWN,
                    p(1, 1.0, 1.0), p(2, 2.0, 2.0),
                    actionIndex = 1,
                ),
            ),
        )
        assertEquals(2, decision.pointers.size)
        assertEquals(1, decision.actionIndex)
    }

    @Test
    fun `android auto refuses a pointer index that names no pointer`() {
        val policy = auto()
        down(policy, ProjectionStack.ANDROID_AUTO, id = 1)
        val decision = policy.decide(
            request(
                ProjectionStack.ANDROID_AUTO,
                ProjectionTouchAction.POINTER_DOWN,
                p(1, 1.0, 1.0),
                actionIndex = 3,
            ),
        )
        assertEquals(ProjectionTouchDrop.UNKNOWN_POINTER, dropped(decision))
    }

    @Test
    fun `android auto clamps every pointer, not only the acting one`() {
        val policy = auto()
        down(policy, ProjectionStack.ANDROID_AUTO, id = 1)
        val decision = sent(
            policy.decide(
                request(
                    ProjectionStack.ANDROID_AUTO,
                    ProjectionTouchAction.POINTER_DOWN,
                    p(1, -5.0, -5.0), p(2, 9999.0, 9999.0),
                    actionIndex = 1,
                ),
            ),
        )
        assertEquals(0.0, decision.pointers[0].x, 0.0)
        assertEquals(1920.0, decision.pointers[1].x, 0.0)
        assertEquals(1080.0, decision.pointers[1].y, 0.0)
    }

    @Test
    fun `android auto refuses a move with no finger down`() {
        val policy = auto()
        val decision = policy.decide(
            request(ProjectionStack.ANDROID_AUTO, ProjectionTouchAction.MOVE, p(1, 1.0, 1.0)),
        )
        assertEquals(ProjectionTouchDrop.UNKNOWN_POINTER, dropped(decision))
    }

    // --- The abandoned gesture ---

    @Test
    fun `an abandoned gesture releases with an up`() {
        val policy = carplay()
        down(policy, ProjectionStack.CARPLAY, id = 4)
        val release = policy.releaseGesture()
        assertEquals(ProjectionTouchAction.UP, release?.action)
        assertEquals(4, release?.pointers?.first()?.id)
        assertTrue(!policy.hasLivePointers)
    }

    @Test
    fun `nothing is released when nothing is down`() {
        assertNull(carplay().releaseGesture())
    }

    @Test
    fun `a new buffer size ends the gesture it can no longer describe`() {
        val policy = carplay()
        down(policy, ProjectionStack.CARPLAY)
        policy.setBufferSize(0, 0)
        assertTrue(!policy.hasLivePointers)
    }

    // --- Calibration ---

    @Test
    fun `the default correction changes nothing`() {
        val policy = carplay()
        val decision = sent(
            policy.decide(
                request(ProjectionStack.CARPLAY, ProjectionTouchAction.DOWN, p(1, 640.0, 360.0)),
            ),
        )
        assertEquals(640.0, decision.pointers.first().x, 0.0)
        assertEquals(360.0, decision.pointers.first().y, 0.0)
    }

    @Test
    fun `an offset moves the point by that many buffer pixels`() {
        val policy = auto()
        policy.calibration = ProjectionTouchCalibration.of(1.0, 30.0, 1.0, -120.0)
        val decision = sent(
            policy.decide(
                request(
                    ProjectionStack.ANDROID_AUTO,
                    ProjectionTouchAction.DOWN,
                    p(1, 640.0, 360.0),
                ),
            ),
        )
        assertEquals(670.0, decision.pointers.first().x, 0.0)
        assertEquals(240.0, decision.pointers.first().y, 0.0)
    }

    @Test
    fun `scale turns about the centre, so the centre does not move`() {
        val policy = auto()
        policy.calibration = ProjectionTouchCalibration.of(1.5, 0.0, 1.5, 0.0)
        val centre = sent(
            policy.decide(
                request(
                    ProjectionStack.ANDROID_AUTO,
                    ProjectionTouchAction.DOWN,
                    p(1, 960.0, 540.0),
                ),
            ),
        )
        assertEquals(960.0, centre.pointers.first().x, 0.0)
        assertEquals(540.0, centre.pointers.first().y, 0.0)
    }

    @Test
    fun `scale grows the distance from the centre`() {
        val policy = auto()
        policy.calibration = ProjectionTouchCalibration.of(1.5, 0.0, 1.0, 0.0)
        val decision = sent(
            policy.decide(
                request(
                    ProjectionStack.ANDROID_AUTO,
                    ProjectionTouchAction.DOWN,
                    p(1, 1160.0, 540.0),
                ),
            ),
        )
        // 200 px right of the centre becomes 300.
        assertEquals(1260.0, decision.pointers.first().x, 0.0)
    }

    @Test
    fun `a correction that leaves the buffer is clamped, not wrapped`() {
        val policy = auto()
        policy.calibration = ProjectionTouchCalibration.of(1.0, -500.0, 1.0, 900.0)
        val decision = sent(
            policy.decide(
                request(
                    ProjectionStack.ANDROID_AUTO,
                    ProjectionTouchAction.DOWN,
                    p(1, 100.0, 900.0),
                ),
            ),
        )
        assertEquals(0.0, decision.pointers.first().x, 0.0)
        assertEquals(1080.0, decision.pointers.first().y, 0.0)
    }

    @Test
    fun `a scale outside the allowed range is brought back into it`() {
        assertEquals(
            ProjectionTouchCalibration.MAX_SCALE,
            ProjectionTouchCalibration.of(9.0, 0.0, 1.0, 0.0).scaleX,
            0.0,
        )
        assertEquals(
            ProjectionTouchCalibration.MIN_SCALE,
            ProjectionTouchCalibration.of(1.0, 0.0, 0.01, 0.0).scaleY,
            0.0,
        )
    }

    @Test
    fun `a value that is not a number is refused, and the identity used`() {
        // An infinite offset would move every touch onto the same edge, and a
        // NaN scale would make every coordinate NaN — which the policy would
        // then refuse as not finite, so every touch would stop.
        val calibration = ProjectionTouchCalibration.of(
            Double.NaN,
            Double.POSITIVE_INFINITY,
            1.0,
            0.0,
        )
        assertEquals(1.0, calibration.scaleX, 0.0)
        assertEquals(0.0, calibration.offsetX, 0.0)
    }

    @Test
    fun `the default correction is per stack, and Android Auto starts shifted up`() {
        // Measured on the car: Android Auto lands one keyboard row low, at
        // every card size. CarPlay lands correctly and must not be moved.
        assertEquals(
            -80.0,
            ProjectionTouchCalibration.defaultFor(ProjectionStack.ANDROID_AUTO).offsetY,
            0.0,
        )
        assertEquals(
            ProjectionTouchCalibration.identity,
            ProjectionTouchCalibration.defaultFor(ProjectionStack.CARPLAY),
        )
    }

    // --- Shape of the request ---

    @Test
    fun `a request with no pointer is refused`() {
        val policy = carplay()
        val decision = policy.decide(
            ProjectionTouchRequest(ProjectionStack.CARPLAY, ProjectionTouchAction.DOWN, 0, emptyList()),
        )
        assertEquals(ProjectionTouchDrop.NO_POINTERS, dropped(decision))
    }

    @Test
    fun `an action this path does not carry is refused`() {
        val policy = carplay()
        val decision = policy.decide(
            request(ProjectionStack.CARPLAY, 9, p(1, 1.0, 1.0)),
        )
        assertEquals(ProjectionTouchDrop.ACTION_UNSUPPORTED, dropped(decision))
    }
}
