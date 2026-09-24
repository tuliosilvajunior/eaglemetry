package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import org.junit.Assert.assertTrue
import org.junit.Test

class PositionDeadbandEvaluatorTest {

    private val evaluator = PositionDeadbandEvaluator()

    /** A first fix always earns a point. */
    private fun firstFix(
        evaluator: PositionDeadbandEvaluator = this.evaluator,
        speedKmh: Double? = null
    ): Boolean = evaluator.evaluatePosition(
        latitude = -23.5505,
        longitude = -46.6333,
        altitude = 760.0,
        speedKmh = speedKmh,
        timestampUtcMillis = 1000L
    )

    @Test
    fun gpsTupleEvaluatesAsOneTrackPoint() {
        assertTrue("first fix must earn a Track point", firstFix())

        // Move 2 meters (less than the 20 m threshold) -> no point
        // 0.000018 deg lat is ~2 meters
        val smallMove = evaluator.evaluatePosition(
            latitude = -23.550518,
            longitude = -46.6333,
            altitude = 760.0,
            timestampUtcMillis = 2000L
        )
        assertTrue("a 2 m move must not earn a Track point", !smallMove)

        // Move 25 meters (>= the 20 m threshold) -> earns a point
        // 0.000225 deg lat is ~25 meters
        val largeMove = evaluator.evaluatePosition(
            latitude = -23.550725,
            longitude = -46.6333,
            altitude = 762.0,
            timestampUtcMillis = 3000L
        )
        assertTrue("a 25 m move must earn a Track point", largeMove)
    }

    @Test
    fun speedFallingThroughStandingThresholdWritesPoint() {
        assertTrue("first fix moving must earn a Track point", firstFix(speedKmh = 40.0))

        // Small move (< 20m), still moving fast -> no point
        val stillMoving = evaluator.evaluatePosition(
            latitude = -23.550505,
            longitude = -46.6333,
            altitude = 760.0,
            speedKmh = 30.0,
            timestampUtcMillis = 2000L
        )
        assertTrue("a small move while moving must not earn a point", !stillMoving)

        // Small move (< 20m), but speed falls through the standing threshold (<= 0.5 km/h) -> point
        val stopFix = evaluator.evaluatePosition(
            latitude = -23.550510,
            longitude = -46.6333,
            altitude = 760.0,
            speedKmh = 0.3,
            timestampUtcMillis = 3000L
        )
        assertTrue("a stop must earn a Track point", stopFix)
    }

    @Test
    fun speedRisingThroughMovingThresholdWritesPoint() {
        assertTrue(
            "first fix at rest must earn a Track point",
            firstFix(speedKmh = 0.0)
        )

        // Stationary jitter (< 20m, speed 0.2 km/h <= 0.5 km/h) -> no point
        val jitter = evaluator.evaluatePosition(
            latitude = -23.550501,
            longitude = -46.6333,
            altitude = 760.0,
            speedKmh = 0.2,
            timestampUtcMillis = 2000L
        )
        assertTrue("standing jitter must not earn a point", !jitter)

        // Small move (< 20m), but speed rises through the moving threshold (>= 2.0 km/h) -> point
        val movingAgain = evaluator.evaluatePosition(
            latitude = -23.550505,
            longitude = -46.6333,
            altitude = 760.0,
            speedKmh = 3.0,
            timestampUtcMillis = 3000L
        )
        assertTrue("a move across the moving threshold must earn a point", movingAgain)
    }

    @Test
    fun creepingVehicleAroundThresholdWritesAtMostOnePointPerCrossing() {
        // 1. Start moving
        assertTrue(firstFix(speedKmh = 35.0))

        // 2. Slow down and cross the standing threshold downward (0.4 km/h <= 0.5 km/h) -> 1 point
        assertTrue(
            "a stop crossing must earn exactly one point",
            evaluator.evaluatePosition(
                latitude = -23.550502,
                longitude = -46.6333,
                altitude = 760.0,
                speedKmh = 0.4,
                timestampUtcMillis = 2000L
            )
        )

        // 3. Creep and oscillate below the moving threshold for multiple ticks (dist < 20m) -> 0 points
        val creepingSpeeds = listOf(0.1, 0.4, 0.8, 0.3, 0.9, 0.4, 0.7, 0.2, 0.0, 0.6)
        creepingSpeeds.forEachIndexed { i, speed ->
            val tick = evaluator.evaluatePosition(
                latitude = -23.550503,
                longitude = -46.6333,
                altitude = 760.0,
                speedKmh = speed,
                timestampUtcMillis = 3000L + (i * 1000L)
            )
            assertTrue("Creeping tick with speed $speed must not earn a point", !tick)
        }

        // 4. Accelerate and cross the moving threshold upward (2.5 km/h >= 2.0 km/h) -> 1 point
        assertTrue(
            "a move across the moving threshold must earn a point",
            evaluator.evaluatePosition(
                latitude = -23.550506,
                longitude = -46.6333,
                altitude = 760.0,
                speedKmh = 2.5,
                timestampUtcMillis = 15000L
            )
        )

        // 5. Fluctuate above standing threshold (dist < 20m) -> 0 points
        val cruisingSpeeds = listOf(1.5, 2.0, 1.4, 0.9, 0.7, 1.8)
        cruisingSpeeds.forEachIndexed { i, speed ->
            val tick = evaluator.evaluatePosition(
                latitude = -23.550508,
                longitude = -46.6333,
                altitude = 760.0,
                speedKmh = speed,
                timestampUtcMillis = 16000L + (i * 1000L)
            )
            assertTrue("Cruising tick with speed $speed must not earn a point", !tick)
        }

        // 6. Drop back to standing (0.2 km/h <= 0.5 km/h) -> 1 point
        assertTrue(
            "a second stop must earn a point",
            evaluator.evaluatePosition(
                latitude = -23.550510,
                longitude = -46.6333,
                altitude = 760.0,
                speedKmh = 0.2,
                timestampUtcMillis = 23000L
            )
        )
    }

    @Test
    fun withNoSpeedTheStopRuleIsOffAndTheOtherRulesDecideAlone() {
        // The bus can be silent: the property may not have arrived yet, or it
        // may be INVALID. The route must then behave exactly as it did before
        // this rule existed, not lose points and not gain them.
        assertTrue("the first fix must earn a point", firstFix())

        // A move under 20 m with no speed to judge it by is still filtered.
        val nearby = evaluator.evaluatePosition(
            latitude = -23.550510,
            longitude = -46.6333,
            altitude = 760.0,
            timestampUtcMillis = 2000L
        )
        assertTrue("a nearby fix must not earn a point", !nearby)

        // The distance rule still fires on its own.
        val farAway = evaluator.evaluatePosition(
            latitude = -23.5510,
            longitude = -46.6333,
            altitude = 760.0,
            timestampUtcMillis = 3000L
        )
        assertTrue("a far fix must earn a point", farAway)
    }

    @Test
    fun theFirstSpeedAfterASilentBusStillEarnsTheStopPoint() {
        // Points written before the bus reported a speed leave no side to
        // stand on. When the first reading arrives and the vehicle is
        // standing, the point that names where it stopped is still earned.
        assertTrue("the silent first fix must earn a point", firstFix())

        val firstSpeedStanding = evaluator.evaluatePosition(
            latitude = -23.550505,
            longitude = -46.6333,
            altitude = 760.0,
            speedKmh = 0.0,
            timestampUtcMillis = 2000L
        )
        assertTrue("the first standing speed must earn the stop point", firstSpeedStanding)

        // And the side is now held: standing again writes nothing.
        val stillStanding = evaluator.evaluatePosition(
            latitude = -23.550506,
            longitude = -46.6333,
            altitude = 760.0,
            speedKmh = 0.1,
            timestampUtcMillis = 3000L
        )
        assertTrue("standing again must not earn a point", !stillStanding)
    }

    @Test
    fun theStandingFloorIsPositiveAndBelowTheMovingFloor() {
        assertTrue(
            "the standing floor must be positive, not an equality against zero",
            GeelyProfile.POSITION_STANDING_SPEED_KMH > 0.0
        )
        assertTrue(
            "the moving floor must sit above the standing floor, or there is no band",
            GeelyProfile.POSITION_MOVING_SPEED_KMH > GeelyProfile.POSITION_STANDING_SPEED_KMH
        )
    }

    @Test
    fun aPositionMissingACoordinateIsNotWritten() {
        assertTrue("the first fix must earn a Track point", firstFix())

        // The clock passes the maximum gap, and the longitude is gone.
        val halfFix = evaluator.evaluatePosition(
            latitude = -23.5505,
            longitude = null,
            altitude = 761.0,
            timestampUtcMillis = 1000L + GeelyProfile.SAMPLE_MAX_GAP_MILLIS + 1000L
        )
        assertTrue(
            "a latitude with no longitude is not a position, and must not earn a point",
            !halfFix
        )
    }
}
