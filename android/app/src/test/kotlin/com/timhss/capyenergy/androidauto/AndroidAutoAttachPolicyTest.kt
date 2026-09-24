package com.timhss.capyenergy.androidauto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidAutoAttachPolicyTest {

    private fun inputs(
        dartActive: Boolean = true,
        activityResumed: Boolean = true,
        serviceConnected: Boolean = true,
        surfaceReady: Boolean = true,
        bufferWidth: Int = 1920,
        bufferHeight: Int = 1080,
    ) = AndroidAutoInputs(
        dartActive = dartActive,
        activityResumed = activityResumed,
        serviceConnected = serviceConnected,
        surfaceReady = surfaceReady,
        bufferWidth = bufferWidth,
        bufferHeight = bufferHeight,
    )

    private fun withFlag(inputs: AndroidAutoInputs, flag: Int, value: Boolean): AndroidAutoInputs =
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
                AndroidAutoAttachPolicy.shouldRender(withFlag(base, flag, false)),
            )
        }
    }

    // Case 2: all true with bufferWidth = 0 -> false (R7).
    @Test
    fun shouldRender_falseWhenBufferWidthIsZero() {
        assertFalse(AndroidAutoAttachPolicy.shouldRender(inputs(bufferWidth = 0)))
    }

    // Case 3: all true with bufferHeight = 0 -> false (R7).
    @Test
    fun shouldRender_falseWhenBufferHeightIsZero() {
        assertFalse(AndroidAutoAttachPolicy.shouldRender(inputs(bufferHeight = 0)))
    }

    // Case 4: negative dimensions are invalid too.
    @Test
    fun shouldRender_falseWhenBufferWidthIsNegative() {
        assertFalse(AndroidAutoAttachPolicy.shouldRender(inputs(bufferWidth = -1)))
    }

    // Case 5: all true with positive geometry.
    @Test
    fun shouldRender_trueWhenEverythingIsReady() {
        assertTrue(AndroidAutoAttachPolicy.shouldRender(inputs()))
    }

    // Case 6.
    @Test
    fun decide_takeOverWhenRenderableAndNotAttached() {
        assertEquals(
            AndroidAutoAction.TAKE_OVER,
            AndroidAutoAttachPolicy.decide(inputs(), attached = false, refreshRequested = false),
        )
    }

    // Case 7.
    @Test
    fun decide_noneWhenRenderableAndAttachedNoRefresh() {
        assertEquals(
            AndroidAutoAction.NONE,
            AndroidAutoAttachPolicy.decide(inputs(), attached = true, refreshRequested = false),
        )
    }

    // Case 8.
    @Test
    fun decide_refreshWhenRenderableAttachedAndRefreshRequested() {
        assertEquals(
            AndroidAutoAction.REFRESH,
            AndroidAutoAttachPolicy.decide(inputs(), attached = true, refreshRequested = true),
        )
    }

    // Case 9.
    @Test
    fun decide_releaseWhenNotRenderableButAttached() {
        assertEquals(
            AndroidAutoAction.RELEASE,
            AndroidAutoAttachPolicy.decide(
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
            AndroidAutoAction.NONE,
            AndroidAutoAttachPolicy.decide(
                inputs(serviceConnected = false),
                attached = false,
                refreshRequested = true,
            ),
        )
    }
}
