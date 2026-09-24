package com.timhss.capyenergy.telemetry

/**
 * Everything collection start and stop touches, named one call at a time.
 *
 * The interface exists so the order can be tested. It is not an abstraction over
 * the collaborators — [TelemetryRuntime] implements it by calling them directly.
 */
internal interface CollectionParticipants {
    /**
     * Whether collection is running.
     *
     * The sequence reads and writes it rather than keeping a second flag,
     * because the collaborators built before the sequence already read this one.
     */
    var collectionRunning: Boolean

    /** Stamps the run's start on the elapsed-realtime axis. */
    fun markCollectionStarted()

    /** Clears that stamp so a restart cannot read the previous run's value. */
    fun markCollectionStopped()

    fun startRangeRefresh()
    fun stopRangeRefresh()

    fun startVhalSubscriptions()
    fun stopVhalSubscriptions()

    /**
     * Opens the Roadcast connection and its poll loop.
     *
     * A subscription alone only registers a watchlist, so this and
     * [startRoadcastTripMetrics] are always a pair.
     */
    fun startRoadcastRepository()
    fun stopRoadcastRepository()

    fun startRoadcastTripMetrics()
    fun stopRoadcastTripMetrics()

    fun startParkedSessionDetector()
    fun stopParkedSessionDetector()

    /**
     * The `CONTINUOUS` session describes the collector's own uptime, not a
     * state of the vehicle, so — unlike the parked/trip/charge sessions —
     * it must not outlive a stopped collector. [stopContinuousSessionDetector]
     * closes it; the start hook opens nothing itself, since the session opens
     * lazily on the first frame after collection resumes.
     */
    fun startContinuousSessionDetector()
    fun stopContinuousSessionDetector()

    fun gpsEnabled(): Boolean
    fun startLocation()
    fun stopLocation()

    fun startCollectorTick()
    fun stopCollectorTick()

    /** Aggregate backfill, retention and the database health read. */
    fun runStartupMaintenance()

    /** Installs and starts the daemon if it is not already up. */
    fun ensureRoadcastDaemon()


    /** Starts the car-side BLE GATT server and advertiser for live telemetry streaming. */
    fun startBleServer()

    /** Stops the car-side BLE GATT server and advertiser. */
    fun stopBleServer()

    /** Returns the media keyserver to the state the car expects. */
    fun restoreKeyserver()
}

/**
 * The start and stop order for telemetry collection.
 *
 * This is a separate object because the order is the part that broke. Between
 * 2026-07-29 and 2026-08-02 `start()` registered the Roadcast watchlist without
 * opening the repository that drives the poll loop, so the trip-metrics monitor
 * waited forever and every CAN column of every persisted frame stayed null. The
 * code read as if it worked. `CollectionSequenceTest` now states the pairing as
 * an assertion instead of as a comment.
 *
 * The idempotence guard lives here too, because "already started" is part of the
 * order: a guard in a different object could be satisfied without the sequence
 * running, or the reverse.
 */
internal class CollectionSequence(private val participants: CollectionParticipants) {
    val running: Boolean
        get() = participants.collectionRunning

    fun start() {
        if (participants.collectionRunning) return
        participants.collectionRunning = true
        participants.markCollectionStarted()
        participants.startRangeRefresh()
        participants.startVhalSubscriptions()
        participants.startRoadcastRepository()
        participants.startRoadcastTripMetrics()
        participants.startParkedSessionDetector()
        participants.startContinuousSessionDetector()
        if (participants.gpsEnabled()) {
            participants.startLocation()
        }
        participants.startCollectorTick()
        participants.runStartupMaintenance()
        participants.ensureRoadcastDaemon()
        participants.startBleServer()
    }

    fun stop() {
        if (!participants.collectionRunning) return
        participants.collectionRunning = false
        participants.markCollectionStopped()
        participants.stopBleServer()
        participants.stopRangeRefresh()
        participants.stopCollectorTick()
        participants.stopVhalSubscriptions()
        participants.stopRoadcastTripMetrics()
        participants.stopParkedSessionDetector()
        participants.stopContinuousSessionDetector()
        participants.restoreKeyserver()
        participants.stopLocation()
        // Disconnect the Kotlin client without stopping the shared daemon.
        participants.stopRoadcastRepository()
    }
}
