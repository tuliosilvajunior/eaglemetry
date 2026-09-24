package com.timhss.capyenergy.carplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CarplayAttachPolicyTest {

    private fun inputs(
        dartActive: Boolean = true,
        activityResumed: Boolean = true,
        serviceConnected: Boolean = true,
        surfaceReady: Boolean = true,
        bufferWidth: Int = 1920,
        bufferHeight: Int = 1080,
    ) = CarplayInputs(
        dartActive = dartActive,
        activityResumed = activityResumed,
        serviceConnected = serviceConnected,
        surfaceReady = surfaceReady,
        bufferWidth = bufferWidth,
        bufferHeight = bufferHeight,
    )

    private fun withFlag(inputs: CarplayInputs, flag: Int, value: Boolean): CarplayInputs =
        when (flag) {
            0 -> inputs.copy(dartActive = value)
            1 -> inputs.copy(activityResumed = value)
            2 -> inputs.copy(serviceConnected = value)
            3 -> inputs.copy(surfaceReady = value)
            else -> throw IllegalArgumentException("flag $flag")
        }

    // Case 1: each of the 5 booleans false in turn, others true.
    @Test
    fun shouldRender_falseWhenAnyBooleanFlagIsFalse() {
        val base = inputs()
        for (flag in 0..3) {
            assertFalse(
                "shouldRender with flag $flag false",
                CarplayAttachPolicy.shouldRender(withFlag(base, flag, false)),
            )
        }
    }

    // Case 2: all true with bufferWidth = 0 -> false (R7).
    @Test
    fun shouldRender_falseWhenBufferWidthIsZero() {
        assertFalse(CarplayAttachPolicy.shouldRender(inputs(bufferWidth = 0)))
    }

    // Case 3: all true with bufferHeight = 0 -> false (R7).
    @Test
    fun shouldRender_falseWhenBufferHeightIsZero() {
        assertFalse(CarplayAttachPolicy.shouldRender(inputs(bufferHeight = 0)))
    }

    // Case 4: negative dimensions are invalid too.
    @Test
    fun shouldRender_falseWhenBufferWidthIsNegative() {
        assertFalse(CarplayAttachPolicy.shouldRender(inputs(bufferWidth = -1)))
    }

    // Case 5: all true with positive geometry.
    @Test
    fun shouldRender_trueWhenEverythingIsReady() {
        assertTrue(CarplayAttachPolicy.shouldRender(inputs()))
    }

    // Case 6.
    @Test
    fun decide_takeOverWhenRenderableAndNotAttached() {
        assertEquals(
            CarplayAction.TAKE_OVER,
            CarplayAttachPolicy.decide(inputs(), attached = false, refreshRequested = false),
        )
    }

    // Case 7.
    @Test
    fun decide_noneWhenRenderableAndAttachedNoRefresh() {
        assertEquals(
            CarplayAction.NONE,
            CarplayAttachPolicy.decide(inputs(), attached = true, refreshRequested = false),
        )
    }

    // Case 8.
    @Test
    fun decide_refreshWhenRenderableAttachedAndRefreshRequested() {
        assertEquals(
            CarplayAction.REFRESH,
            CarplayAttachPolicy.decide(inputs(), attached = true, refreshRequested = true),
        )
    }

    // Case 9.
    @Test
    fun decide_releaseWhenNotRenderableButAttached() {
        assertEquals(
            CarplayAction.RELEASE,
            CarplayAttachPolicy.decide(
                inputs(activityResumed = false),
                attached = true,
                refreshRequested = false,
            ),
        )
    }

    // Case 10: a refresh request must never attach when not renderable.
    @Test
    fun decide_noneWhenNotRenderableEvenWithRefresh() {
        assertEquals(
            CarplayAction.NONE,
            CarplayAttachPolicy.decide(
                inputs(serviceConnected = false),
                attached = false,
                refreshRequested = true,
            ),
        )
    }
}
