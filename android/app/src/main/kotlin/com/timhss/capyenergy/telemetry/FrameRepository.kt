package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.GeelyProfile
import com.timhss.capyenergy.profile.SessionKind
import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.profile.SignalNature
import com.timhss.capyenergy.profile.VehicleProfile

import android.content.Context
import android.util.Log
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.concurrent.namedSingleThreadScheduledExecutor
import com.timhss.capyenergy.telemetry.db.CanStreamSample
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.util.concurrent.Callable
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

data class ActiveFrameSession(
    val id: String,
    val type: String
)

private val POSITION_KEYS = setOf(
    SignalKey.LATITUDE.name,
    SignalKey.LONGITUDE.name,
    SignalKey.ALTITUDE.name,
    SignalKey.GPS_ACCURACY.name
)

class FrameRepository(
    context: Context,
    private val activeSessionProvider: () -> ActiveFrameSession?,
    private val parkedSessionProvider: () -> ActiveFrameSession? = { null },
    private val continuousSessionProvider: () -> ActiveFrameSession? = { null },
    private val locationProvider: () -> LocationSnapshot?,
    private val roadcastTripMetricsProvider: () -> RoadcastTripMetrics? = { null },
    private val capacityWhProvider: () -> Double? = { null },
    private val chargerReadingGuard: ChargerReadingGuard = ChargerReadingGuard(),
    private val dcChargePowerGuard: SignalFreezeGuard =
        SignalFreezeGuard(SignalKey.EV_DC_CHARGE_POWER),
    private val profile: VehicleProfile = GeelyProfile,
    private val activeAccountIdProvider: () -> String? = { null },
) : SignalStateStore.Listener {
    private val appContext = context.applicationContext
    private val database = TelemetryDatabase.get(appContext)
    /**
     * Read once — the counter cannot change without this process being killed.
     * Only open sessions consult it; a closed session carries its own endpoints.
     */
    private val bootCount: Int? by lazy { SessionTimeline.currentBootCount(appContext) }

    private val sessionDao = database.sessionDao()
    private val intervalDao = database.intervalDao()
    private val costDao = database.sessionCostDao()
    private val eventDao = database.telemetryEventDao()
    private val positionEvaluator = PositionDeadbandEvaluator()
    private val trackDao = database.trackDao()

    /**
     * The drive of the open session, in memory, written on the minute tick.
     *
     * Held here rather than in the evaluator because it belongs to the session
     * and not to the deadband: the evaluator decides which fixes earn a row,
     * the recorder keeps the ones it accepted. See issue 178.
     */
    private val trackRecorder = TrackRecorder()

    private val writeExecutor = TelemetryWriteCoordinator.executor
    private val batchScheduler = namedSingleThreadScheduledExecutor("frames-flush")
    private val batchLock = Any()
    private val droppedFrames = AtomicLong(0L)
    private val frameBatches = AtomicLong(0L)
    private val largestBatch = AtomicLong(0L)

    /**
     * Detail/history reads, off the frame-write thread.
     *
     * Frame inserts must stay ordered, so they keep [writeExecutor] to themselves.
     * A detail read has no ordering requirement, and letting a multi-thousand
     * row scan sit in front of live persistence delayed the very frames the
     * screen was about to show.
     */
    private val readExecutor = namedSingleThreadExecutor("frames-db")
    private val frameWrites = AtomicLong(0L)
    private val cadence = FrameCadence()

    /**
     * In-memory minute buckets for the trip in progress, so the energy chart's
     * open bar can be polled without re-sweeping the session.
     *
     * Fed by [foldCanSample] off the Roadcast stream, not by the frames this
     * class persists. See [com.timhss.capyenergy.telemetry.db.CanStreamSample]
     * for why the 1 Hz row rate is the wrong rate for this particular integral.
     */
    private val liveEnergyBuckets = LiveEnergyBucketMonitors.trip(
        retainBuckets = ENERGY_FLUSH_WINDOW_MINUTES,
        bootCountProvider = { bootCount }
    )

    /**
     * The same integral, cut ten seconds wide, for the efficiency card.
     *
     * Efficiency is distance over energy, and both terms have to come from one
     * interval. The minute is too coarse to watch: a driver reads this card to
     * see what the last few seconds of throttle cost, and fifteen bars cannot
     * show that. Six of these sum back to exactly one of the minutes above, so
     * the finer read is a different cut of the same arithmetic, not a second
     * estimate of the same driving.
     *
     * Nothing here is written. The stored series stays the minute, and this
     * window dies with the trip.
     */
    private val liveEfficiencyBuckets = LiveEnergyBucketMonitors.efficiency(
        windowMinutes = EFFICIENCY_WINDOW_BUCKETS,
        bucketMillis = EFFICIENCY_BUCKET_MILLIS
    )

    private val liveParkedEnergyBuckets = LiveEnergyBucketMonitors.parked(
        retainBuckets = ENERGY_FLUSH_WINDOW_MINUTES,
        bootCountProvider = { bootCount }
    )

    /**
     * One minute of energy for every minute the `CONTINUOUS` session is open,
     * gated on nothing. Fed from the same frame as the other three, so a
     * minute inside a trip exists twice: once here and once under the trip.
     * See issue 199.
     */
    private val liveContinuousEnergyBuckets = LiveEnergyBucketMonitors.continuous(
        retainBuckets = ENERGY_FLUSH_WINDOW_MINUTES,
        bootCountProvider = { bootCount }
    )

    /**
     * The stored minutes of a charge: the delivered integral, and the climate
     * draw beside it.
     *
     * `deliveredOnly` is the charge mode, not a narrower `climateOnly`. It folds
     * both terms, because a charge's `interval` row is one row — keyed by
     * `(sessionId, startUtcMillis)` — and two monitors cannot each own part of
     * it. It was built `climateOnly` until 2026-08-20, so `deliveredWh` was
     * never accumulated and every charge stored zero delivered energy while the
     * frames carried a real 2 kW. Nothing caught it: `IntervalFixtureTest` built
     * the accumulator directly with `deliveredOnly = true` and so proved the
     * fold while stepping over the wiring that feeds it.
     */
    private val liveChargeEnergyBuckets = LiveEnergyBucketMonitors.charge(
        retainBuckets = ENERGY_FLUSH_WINDOW_MINUTES,
        bootCountProvider = { bootCount }
    )

    /**
     * The same climate integral, cut ten seconds wide, for the charge warning.
     *
     * The warning compares the climate draw against the charge rate, so its
     * value has to follow the driver's hand on the climate control. Read over
     * the minute monitor above, it answered with a three-minute mean: the
     * warning arrived minutes after the compressor started and stayed for
     * minutes after it stopped, which is the whole window's width showing
     * through as lag.
     *
     * Six of these sum back to exactly one stored minute, so this is a finer
     * cut of the same arithmetic and not a second estimate. Nothing here is
     * written; the minute monitor above stays the only source the database
     * sees.
     */
    private val liveChargeClimateBuckets = LiveEnergyBucketMonitors.chargeClimate(
        windowMinutes = CHARGE_CLIMATE_WINDOW_BUCKETS,
        bucketMillis = CHARGE_CLIMATE_BUCKET_MILLIS
    )

    /**
     * The driver's inputs over the second a frame covers, not at one instant.
     *
     * Frames are written once a second out of a 60 Hz stream, so a point sample
     * answers "what was the pedal doing at the tick", which is not the question
     * either of these columns is read for. A brake tap is often shorter than the
     * gap between frames, and point sampling drops it entirely along with every
     * edge; a pedal position at one instant is not the second's demand.
     *
     * Only the two inputs are folded here. The signals stored as a value beside
     * its raw count are deliberately left as point samples — see
     * [DriverInputWindow].
     */
    private val driverInputs = DriverInputWindow()

    /**
     * The state of charge and the odometer, held between the snapshot tick that
     * measures them and the bus-rate frame that carries them.
     *
     * Both expire after one bucket. See [HeldVehicleReadings] for why the
     * odometer moved here, and issue 188 for what it was doing before.
     */
    private val heldReadings = HeldVehicleReadings()

    /**
     * Last speed the VHAL published, carried into the CAN-rate samples.
     *
     * The bus signal `ESC_VehicleSpeed` used to feed this. It was withdrawn on
     * 2026-08-07: it stops arriving for whole trips at a time — every bucket of
     * the 07/08 drives recorded zero distance while the odometer moved 6.7 km —
     * and even on its good days the `ESC_VehicleSpeedInvalid` gate rejected
     * about half the samples. A distance term that vanishes without warning is
     * worse than a slower one, because the card cannot tell it from a car that
     * did not move: both read as a standstill. `VEHICLE_SPEED` is the same
     * source `telemetry_frames.speedKmh` already persists, so the buckets and
     * the frames now agree on how far the car went.
     *
     * The stamps travel with the value. At 5 Hz into a 60 Hz fold, the reading
     * would otherwise be integrated twelve times — see [CanPowerSample].
     */
    @Volatile
    private var lastVehicleSpeed: VhalSpeedReading? = null

    @Volatile
    private var lastEnergyFlushUtcMillis = 0L

    /**
     * Folds one CAN reading into the trip in progress.
     *
     * Called on the Roadcast monitor's own thread at bus rate. Only trip
     * sessions accumulate; [LiveEnergyBucketMonitor] resets itself on anything
     * else, which is what stops a charge from being counted as drive energy.
     *
     * The source-age gate is the one [buildFrame] applies. It has to be repeated
     * here rather than left to the accumulator's gap rule: a silent bus does not
     * stop the poll, so the daemon would keep handing back its last values and
     * the integral would read a plateau of stale power as real consumption.
     */
    fun foldCanSample(metrics: RoadcastTripMetrics) {
        if (metrics.sourceAgeNanos !in 0..FRESH_CAN_NANOS) return
        val session = activeSessionProvider()
        val parkedSession = parkedSessionProvider()
        val continuousSession = continuousSessionProvider()
        val now = System.currentTimeMillis()

        val tripId = session?.takeIf { it.type == LiveEnergyBucketMonitor.TRIP_SESSION_TYPE }?.id
        val chargeId = session?.takeIf { it.type == LiveEnergyBucketMonitor.CHARGE_SESSION_TYPE }?.id
        val parkedId = parkedSession?.id
        val continuousId = continuousSession?.id

        if ((liveEnergyBuckets.currentSessionId() != null && liveEnergyBuckets.currentSessionId() != tripId) ||
            (liveParkedEnergyBuckets.currentSessionId() != null && liveParkedEnergyBuckets.currentSessionId() != parkedId) ||
            (liveChargeEnergyBuckets.currentSessionId() != null && liveChargeEnergyBuckets.currentSessionId() != chargeId) ||
            (liveContinuousEnergyBuckets.currentSessionId() != null && liveContinuousEnergyBuckets.currentSessionId() != continuousId)
        ) {
            flushEnergyBuckets(now)
        }

        // Only a trip carries these columns, so only a trip fills the window.
        // A charge or a parked poll would otherwise leave a stale press behind
        // for the next trip's first frame to drain.
        val trip = session?.takeIf { it.type == LiveEnergyBucketMonitor.TRIP_SESSION_TYPE }
        if (trip != null) driverInputs.observe(metrics) else driverInputs.reset()

        val frame = composeCanStreamSample(
            metrics = metrics,
            speed = lastVehicleSpeed,
            held = heldReadings,
            nowUtcMillis = now
        )
        liveEnergyBuckets.onFrame(session?.id, session?.type, frame)
        // Same frame into both cuts, so the two can never see different driving.
        liveEfficiencyBuckets.onFrame(session?.id, session?.type, frame)
        // A parked car can be plugged in at the same time, so its own accumulator
        // needs the same charging flag CONTINUOUS gets below. See issue 199/211.
        liveParkedEnergyBuckets.onFrame(
            parkedSession?.id,
            parkedSession?.type,
            frame,
            isCharging = chargeId != null
        )
        liveChargeEnergyBuckets.onFrame(session?.id, session?.type, frame)
        liveChargeClimateBuckets.onFrame(session?.id, session?.type, frame)
        // Same frame again: duplication with the trip/parked/charge monitors
        // above is accepted, per issue 199 — this stream never depends on
        // their boundaries. `chargeId` is the same authoritative signal already
        // used above to route frames to the charge monitor, so a downhill
        // regen cannot be mistaken for a charger here. See issue 199/211.
        liveContinuousEnergyBuckets.onFrame(
            continuousSession?.id,
            continuousSession?.type,
            frame,
            isCharging = chargeId != null
        )

        if (now - lastEnergyFlushUtcMillis >= ENERGY_FLUSH_INTERVAL_MILLIS) {
            flushEnergyBuckets(now)
        }
    }

    /**
     * Writes the minutes the monitor is holding.
     *
     * Only the monitor's own window is written, which is the open minute and the
     * couple behind it — everything earlier was written by a previous flush and
     * can no longer change. The primary key is `(sessionId, startUtcMillis)` and
     * the insert replaces, so re-writing the open minute as it fills is the
     * intended path rather than a duplicate.
     *
     * Flushing on an interval bounds what a kill loses to
     * [ENERGY_FLUSH_INTERVAL_MILLIS] of the trip in progress. Closed minutes of
     * a finished trip are already durable.
     */
    /**
     * Points the recorder at [id], once.
     *
     * Two reads happen here and nowhere else: the session, for the instant `t`
     * counts from, and the stored row, so a process that restarts mid-drive
     * keeps the route it had already written instead of rewriting the row with
     * only what it has seen since. It returns immediately once the recorder
     * already holds this session.
     */
    private fun beginTrack(id: String) {
        if (trackRecorder.currentSessionId() == id) return
        val row = sessionDao.findById(id) ?: return
        trackRecorder.begin(
            id = id,
            startWallMillis = row.startedAtUtcMillis,
            seed = trackDao.forSession(id)
        )
    }

    /**
     * Rewrites the open session's route, raw.
     *
     * Rides the same tick that writes the minute buckets, so what a power cut
     * costs the route is what it costs the energy series: the minute in
     * progress. The points are stored raw and simplified once at close —
     * Douglas-Peucker is not incremental, so a path simplified section by
     * section is not the path simplified whole. See issue 178.
     *
     * Only the open session is written: a tick that fired between the close
     * and the next session's first fix would otherwise put the raw points back
     * over the simplified row. [TrackRecorder.rawRowWhileOpen] holds that rule.
     */
    private fun flushTrack(now: Long) {

        val row = trackRecorder.rawRowWhileOpen(activeSessionProvider()?.id, now) ?: return
        // The route of the open session belongs to the account the session
        // belongs to. A row with no account yet is adopted by the current
        // pairing; a row that already carries one is never re-stamped (the
        // same `account_id IS NULL` rule the cloud's claim backfill uses).
        // The recorder seeds from the stored row at begin(), so a route that
        // is already owned keeps its owner.
        val stamped = if (row.accountId == null) {
            activeAccountIdProvider()?.let { row.copy(accountId = it) } ?: row
        } else {
            row
        }
        writeExecutor.executeWrite(
            operation = "upsert_track",
            overflowPolicy = ObservedWriteExecutor.OverflowPolicy.DROP_NEWEST,
            onFailure = { Log.w(TAG, "Failed to persist track", it) }
        ) {
            trackDao.upsert(stamped)
        }
    }


    private fun flushEnergyBuckets(now: Long) {
        lastEnergyFlushUtcMillis = now
        val snapshots = listOfNotNull(
            liveEnergyBuckets.snapshot(ENERGY_FLUSH_WINDOW_MINUTES),
            liveParkedEnergyBuckets.snapshot(ENERGY_FLUSH_WINDOW_MINUTES),
            liveChargeEnergyBuckets.snapshot(ENERGY_FLUSH_WINDOW_MINUTES),
            liveContinuousEnergyBuckets.snapshot(ENERGY_FLUSH_WINDOW_MINUTES)
        )
        // Before the early return: a drive with no closed bucket in the
        // monitor's window still has a route to keep.
        flushTrack(now)
        val rows = snapshots.flatMap { snapshot ->
            snapshot.buckets.map {
                // The minute bucket is born inside the open session, so it is
                // born owned by the same account the session carried when the
                // bucket was written. No later pass stamps these rows — the
                // birth point carries the owner forward on every rewrite.
                it.toEntity(snapshot.sessionId, now, activeAccountIdProvider())
            }
        }
        if (rows.isEmpty()) return
        // DROP_NEWEST: a dropped flush costs nothing, because the minutes it
        // carried are still in memory and the next flush rewrites them. Blocking
        // the Roadcast thread to insist on this write would cost a gap in the
        // integral itself, which is the one thing that cannot be recovered.
        writeExecutor.executeWrite(
            operation = "upsert_energy_buckets",
            overflowPolicy = ObservedWriteExecutor.OverflowPolicy.DROP_NEWEST,
            onFailure = { Log.w(TAG, "Failed to persist energy buckets", it) }
        ) {
            intervalDao.upsertAll(rows)
        }
    }

    /** Null when no trip is running: there is nothing live to show. */
    fun liveEnergySeries(): LiveEnergyBuckets? = liveEnergyBuckets.snapshot()

    /** The ten-second window behind the efficiency card. Memory only. */
    fun liveEfficiencySeries(): LiveEnergyBuckets? = liveEfficiencyBuckets.snapshot()

    /**
     * The open charge's last minute of climate, ten seconds at a time. Memory
     * only.
     *
     * Climate is the only term this monitor integrates, so a caller reads
     * `climateWh` and must not read a zero `tractionWh` here as a measurement.
     */
    fun liveChargeEnergySeries(): LiveEnergyBuckets? = liveChargeClimateBuckets.snapshot()

    /**
     * The continuous session's newest minutes. Memory only.
     *
     * Null with the mode off, or the instant between a rotation's close and its
     * reopen — never a car that stopped being awake. See issue 199.
     */
    fun liveContinuousEnergySeries(): LiveEnergyBuckets? =
        liveContinuousEnergyBuckets.snapshot()

    /** The width the efficiency card is cut to, for an empty answer. */
    fun efficiencyBucketMillis(): Long = EFFICIENCY_BUCKET_MILLIS

    override fun onSignalUpdated(sample: SignalSample, snapshot: Map<SignalKey, SignalSample>) {
        captureVehicleSpeed(snapshot)
        val session = activeSessionProvider() ?: return
        val timestamp = sample.timestamp

        if (sample.signalId.name !in POSITION_KEYS) {
            val numVal = sample.numericDoubleValue()
            heldReadings.observeOne(
                key = sample.signalId,
                value = numVal,
                elapsedNanos = timestamp.receivedAtElapsedNanos
            )
        }
    }

    fun persistActiveSnapshot(timestamp: SignalTimestamp, snapshot: Map<SignalKey, SignalSample>) {
        if (snapshot.isEmpty()) return
        heldReadings.observe(snapshot, timestamp.receivedAtElapsedNanos)
        val session = activeSessionProvider() ?: return

        val fix = locationProvider()
        val busSpeedKmh = snapshot[SignalKey.VEHICLE_SPEED]
            ?.let { carPropertyVehicleSpeedKmh(it) }
            ?.toDouble()
        if (fix != null) {
            val shouldTrack = positionEvaluator.evaluatePosition(
                latitude = fix.latitude,
                longitude = fix.longitude,
                altitude = fix.altitudeM,
                speedKmh = busSpeedKmh,
                timestampUtcMillis = timestamp.receivedAtUtcMillis
            )
            if (shouldTrack) {
                beginTrack(session.id)
                trackRecorder.add(
                    id = session.id,
                    wallMillis = timestamp.receivedAtUtcMillis,
                    latitude = fix.latitude,
                    longitude = fix.longitude,
                    altitudeM = fix.altitudeM,
                    speedKmh = busSpeedKmh
                )
            }
        }
    }

    /**
     * Keeps the newest `VEHICLE_SPEED` for [foldCanSample].
     */
    private fun captureVehicleSpeed(snapshot: Map<SignalKey, SignalSample>) {
        val sample = snapshot[SignalKey.VEHICLE_SPEED] ?: return
        val speed = carPropertyVehicleSpeedKmh(sample) ?: return
        val nanos = sample.timestamp.receivedAtElapsedNanos
        val wallMillis = sample.timestamp.receivedAtUtcMillis
        if (nanos <= 0L || wallMillis <= 0L) return
        if (nanos <= (lastVehicleSpeed?.elapsedRealtimeNanos ?: 0L)) return
        lastVehicleSpeed = VhalSpeedReading(
            speedKmh = speed,
            elapsedRealtimeNanos = nanos,
            wallTimeUtcMillis = wallMillis
        )
    }

    private fun chargeStabilityPowerKw(
        snapshot: Map<SignalKey, SignalSample>,
        timestamp: SignalTimestamp
    ): Float? {
        dcChargePowerKw(snapshot, timestamp)?.let { return it }
        return chargerReadings(snapshot, timestamp)?.inputPowerKw
    }

    private fun dcChargePowerKw(
        snapshot: Map<SignalKey, SignalSample>,
        timestamp: SignalTimestamp
    ): Float? {
        if (freshFloat(snapshot, SignalKey.EV_DC_CHARGE_POWER, timestamp) == null) return null
        val reading = dcChargePowerGuard.read(snapshot, timestamp.receivedAtElapsedNanos)
        return (reading as? SignalFreezeGuard.Result.Measuring)?.value
    }

    private fun chargerReadings(
        snapshot: Map<SignalKey, SignalSample>,
        timestamp: SignalTimestamp
    ): ChargerReadingGuard.ChargerReadings? {
        if (freshFloat(snapshot, SignalKey.HV_BATTERY_VOLTAGE, timestamp) == null) return null
        if (freshFloat(snapshot, SignalKey.HV_BATTERY_CURRENT, timestamp) == null) return null
        return chargerReadingGuard.readings(snapshot, timestamp.receivedAtElapsedNanos)
    }

    fun statusMap(): Map<String, Any?> = mapOf(
        "frameWritesThisRun" to frameWrites.get(),
        "bufferedFrames" to 0,
        "droppedFramesThisRun" to droppedFrames.get(),
        "frameBatchesThisRun" to frameBatches.get(),
        "largestFrameBatchThisRun" to largestBatch.get()
    )

    fun resetInMemory() {
        heldReadings.reset()
        frameWrites.set(0L)
        droppedFrames.set(0L)
        frameBatches.set(0L)
        largestBatch.set(0L)
        cadence.reset()
    }

    /** Waits until every sample accepted before this call has reached Room. */
    fun awaitPendingWrites() {
        try {
            writeExecutor.awaitIdle()
        } catch (e: Exception) {
            throw IllegalStateException("Failed while waiting for pending sample writes", e)
        }
    }

    /**
     * Per-minute energy series over a stretch of clock rather than one session.
     *
     * Backs the chart's wider windows, where the point is the last few hours of
     * driving whatever sessions those fell in. Trips are found through the
     * indexed session window and swept one at a time, so this needs no index on
     * frame wall time and no interval is ever integrated across the gap between
     * two trips. Charge sessions are left out: energy taken *in* is a different
     * question with its own screen.
     *
     * The window start is floored to a bucket boundary, so the first bar is a
     * whole minute on the clock like every other one.
     */
    fun energySeriesInWindow(
        startUtcMillis: Long,
        endUtcMillis: Long
    ): WindowEnergySeries {
        val windowStart = EnergyBucketAccumulator.alignToBucket(startUtcMillis)
        return try {
            readExecutor.submit(Callable {
                val trips = sessionDao.inWindow("TRIP", windowStart, endUtcMillis)
                val measured = intervalDao
                    .sessionsWithBuckets(trips.map { it.id })
                    .toSet()
                // One query for every trip that has stored minutes; only the
                // trips that predate the table are swept frame by frame.
                val storedSeries = if (measured.isEmpty()) {
                    emptyList()
                } else {
                    listOf(
                        intervalDao.forSessionsInWindow(
                            sessionIds = measured.toList(),
                            startUtcMillis = windowStart,
                            endUtcMillis = endUtcMillis
                        ).map { it.toEnergyBucket() }
                    )
                }
                val resampled = trips.filterNot { it.id in measured }
                val buckets = EnergyBucketAccumulator.combine(storedSeries)
                    .filter { it.startUtcMillis in windowStart until endUtcMillis }
                val lastPricedCharge = costDao.latestPricedBefore(endUtcMillis)
                WindowEnergySeries(
                    startUtcMillis = windowStart,
                    endUtcMillis = endUtcMillis,
                    bucketMillis = EnergyBucket.BUCKET_MILLIS,
                    sessionCount = trips.size,
                    resampledSessionCount = resampled.size,
                    buckets = buckets,
                    lastChargeCostPerKwh = lastPricedCharge?.costPerKwh,
                    lastChargeCostCurrency = lastPricedCharge?.costCurrency
                )
            }).get()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to build energy buckets for window", e)
            WindowEnergySeries(
                startUtcMillis = windowStart,
                endUtcMillis = endUtcMillis,
                bucketMillis = EnergyBucket.BUCKET_MILLIS,
                sessionCount = 0,
                resampledSessionCount = 0,
                buckets = emptyList(),
                lastChargeCostPerKwh = null,
                lastChargeCostCurrency = null
            )
        }
    }

    /**
     * The same window, over parked sessions instead of trips.
     *
     * There is no frame-sweep fallback here, and there must not be one. A trip
     * can predate the bucket table, so [energySeriesInWindow] rebuilds those
     * from stored frames; a parked session cannot, because the detector and the
     * table arrived together. More to the point, raw frames stay suppressed
     * while parked, so there are no frames to sweep — a fallback would answer
     * "nothing was drawn" for a window that simply has no rows, which is the
     * one thing this series must never say.
     */
    fun parkedEnergySeriesInWindow(
        startUtcMillis: Long,
        endUtcMillis: Long
    ): WindowEnergySeries {
        val windowStart = EnergyBucketAccumulator.alignToBucket(startUtcMillis)
        return try {
            readExecutor.submit(Callable {
                val parked = sessionDao.inWindow("PARKED", windowStart, endUtcMillis)
                val measured = intervalDao
                    .sessionsWithBuckets(parked.map { it.id })
                val buckets = if (measured.isEmpty()) {
                    emptyList()
                } else {
                    EnergyBucketAccumulator.combine(
                        listOf(
                            intervalDao.forSessionsInWindow(
                                sessionIds = measured,
                                startUtcMillis = windowStart,
                                endUtcMillis = endUtcMillis
                            ).map { it.toEnergyBucket() }
                        )
                    ).filter { it.startUtcMillis in windowStart until endUtcMillis }
                }
                val lastPricedCharge = costDao.latestPricedBefore(endUtcMillis)
                WindowEnergySeries(
                    startUtcMillis = windowStart,
                    endUtcMillis = endUtcMillis,
                    bucketMillis = EnergyBucket.BUCKET_MILLIS,
                    sessionCount = parked.size,
                    // Nothing is ever resampled on this path, so the caller is
                    // told the auxiliary column is a CAN-rate measurement.
                    resampledSessionCount = 0,
                    buckets = buckets,
                    lastChargeCostPerKwh = lastPricedCharge?.costPerKwh,
                    lastChargeCostCurrency = lastPricedCharge?.costCurrency
                )
            }).get()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to build parked energy buckets for window", e)
            WindowEnergySeries(
                startUtcMillis = windowStart,
                endUtcMillis = endUtcMillis,
                bucketMillis = EnergyBucket.BUCKET_MILLIS,
                sessionCount = 0,
                resampledSessionCount = 0,
                buckets = emptyList(),
                lastChargeCostPerKwh = null,
                lastChargeCostCurrency = null
            )
        }
    }

    /**
     * When this session met its charge limit, as offsets on the series axis.
     *
     * Read from `CHARGE_LIMIT_REACHED` rather than from the session row: the
     * event log is append-only, so it recorded these instants even for sessions
     * whose stored timestamps were later rewritten. There can be several — the
     * soft switch does not survive an ignition cycle, so a car left plugged in
     * tops up and is cut again each time it wakes.
     */
    private fun chargeTargetMarkers(
        charge: SessionEntity?,
        firstWallUtcMillis: Long?
    ): Map<String, Any?> {
        if (charge == null || firstWallUtcMillis == null) {
            return mapOf("targetReachedAtUtcMillis" to emptyList<Long>())
        }
        val until = charge.plugDisconnectedAtUtcMillis ?: charge.endedAtUtcMillis ?: charge.updatedAtUtcMillis
        val reached = eventDao.byTypeInWindow(
            TelemetryEventType.CHARGE_LIMIT_REACHED.name,
            charge.startedAtUtcMillis,
            until
        ).map { it.occurredAtUtcMillis }
        return mapOf(
            "targetReachedAtUtcMillis" to reached,
            "firstFrameWallUtcMillis" to firstWallUtcMillis
        )
    }

    /**
     * What the climate package drew from the pack while this charge ran.
     */
    private fun chargeClimateEnergy(sessionId: String): Map<String, Any?> {
        val intervals = intervalDao.forSession(sessionId)
        val seconds = intervals.sumOf { it.climateCoveredSeconds }.takeIf { it > 0.0 }
        val wh = intervals.sumOf { it.climateWh }.takeIf { it.isFinite() }
        if (seconds == null || wh == null) {
            return mapOf(
                "climateEnergyKwh" to null,
                "climateIntegratedSeconds" to null
            )
        }
        return mapOf(
            "climateEnergyKwh" to wh / 1_000.0,
            "climateIntegratedSeconds" to seconds
        )
    }



    /**
     * The trip's energy for a read path.
     *
     * A stored rollup answers without touching frames.
     */
    private fun tripEnergySourcesFor(
        sessionId: String,
        trip: SessionEntity?,
        capacityWh: Double?
    ): TripEnergySources {
        if (trip != null && trip.rollupTractionWh != null) {
            val integral = trip.tripPowerIntegral()
            val agrees = when (trip.socAgreesWithIntegral) {
                "agrees" -> true
                "contradicts" -> false
                else -> null
            }
            return TripEnergySources(
                integral = integral,
                agreesWithSoc = agrees
            )
        }
        return TripEnergySources(
            integral = null,
            agreesWithSoc = null
        )
    }



    private data class TripEnergySources(
        val integral: TripPowerIntegral?,
        val agreesWithSoc: Boolean?
    ) {
        /** The trip's energy: the integral, read in kWh. */
        val energy: TripEnergyBreakdown? get() = integral?.toBreakdown()
    }

    /**
     * Shared trip math for the detail and live-energy paths. Session-row values
     * (SOC endpoints, odometer, pack capacity captured at trip creation) are
     * authoritative; frame-derived values fill the gaps for open sessions and
     * legacy rows.
     */
    private fun tripEnergyStats(
        trip: SessionEntity?,
        capacityWh: Double?,
        speedDistanceKm: Double?,
        averageSpeedKmh: Double?,
        frameOdometerDistanceKm: Double?,
        energySources: TripEnergySources
    ): TripEnergyStats {
        val sessionOdometerDistance = trip?.let { session ->
            val start = session.startOdometerKm ?: return@let null
            val end = session.endOdometerKm ?: return@let null
            (end - start).toDouble().takeIf { it >= 0.0 }
        }
        val odometerDistance = sessionOdometerDistance ?: frameOdometerDistanceKm
        // Prefer odometer for efficiency: speed estimate can drift.
        val efficiencyDistance = odometerDistance?.takeIf { it >= 0.01 } ?: speedDistanceKm
        val energy = energySources.energy
        val integral = energySources.integral
        val measuredDistance = efficiencyDistance?.takeIf { it >= 0.01 }
        return TripEnergyStats(
            speedDistanceKm = speedDistanceKm,
            averageSpeedKmh = averageSpeedKmh,
            odometerDistanceKm = odometerDistance,
            capacityWh = capacityWh,
            energy = energy,
            efficiencyWhPerKm = energy?.let {
                TelemetryEnergy.efficiencyWhPerKm(it, efficiencyDistance)
            },
            efficiencyKmPerKwh = energy?.let {
                TelemetryEnergy.kmPerKwh(it, efficiencyDistance)
            },
            measuredIntegral = integral,
            measuredAgreesWithSoc = energySources.agreesWithSoc,
            measuredDistanceKm = measuredDistance
        )
    }

    private data class TripEnergyStats(
        val speedDistanceKm: Double?,
        val averageSpeedKmh: Double?,
        val odometerDistanceKm: Double?,
        val capacityWh: Double?,
        val energy: TripEnergyBreakdown?,
        val efficiencyWhPerKm: Double?,
        val efficiencyKmPerKwh: Double?,
        val measuredIntegral: TripPowerIntegral? = null,
        val measuredAgreesWithSoc: Boolean? = null,
        val measuredDistanceKm: Double? = null
    ) {
        fun toMap(sessionId: String, frameCount: Long): Map<String, Any?> =
            mapOf(
                "sessionId" to sessionId,
                "totalCount" to frameCount,
                "speedEstimatedDistanceKm" to speedDistanceKm,
                "averageSpeedKmh" to averageSpeedKmh,
                "odometerDistanceKm" to odometerDistanceKm,
                "energyConsumedKwh" to energy?.consumedKwh,
                "energyRegeneratedKwh" to energy?.regeneratedKwh,
                "netEnergyKwh" to energy?.netKwh,
                "efficiencyWhPerKm" to efficiencyWhPerKm,
                "efficiencyKmPerKwh" to efficiencyKmPerKwh,
                "capacityWh" to capacityWh
            ) + measuredTripEnergyMap(
                integral = measuredIntegral,
                agreesWithSoc = measuredAgreesWithSoc,
                distanceKm = measuredDistanceKm
            )

        companion object {
            val empty = TripEnergyStats(
                speedDistanceKm = null,
                averageSpeedKmh = null,
                odometerDistanceKm = null,
                capacityWh = null,
                energy = null,
                efficiencyWhPerKm = null,
                efficiencyKmPerKwh = null
            )
        }
    }

    /**
     * Reads a bus signal only into the kind of session it describes.
     *
     * Which signal belongs to which session is a statement about the vehicle,
     * so the answer comes from [VehicleProfile.recordsDuring]. The rule used to
     * be a comment beside each column, where a second vehicle could not reach
     * it and where a new column could quietly be added on the wrong side of it.
     *
     * A frame with no session reads only a signal that every kind records. A
     * gated signal has no session to belong to there, and the last value its
     * ECU sent is not a measurement of anything.
     */
    private inline fun <T> whenRecorded(
        session: ActiveFrameSession?,
        key: SignalKey,
        read: () -> T?
    ): T? {
        val kind = session.sessionKind()
        val records = if (kind == null) {
            SessionKind.entries.all { profile.recordsDuring(key, it) }
        } else {
            profile.recordsDuring(key, kind)
        }
        return if (records) read() else null
    }

    private fun ActiveFrameSession?.sessionKind(): SessionKind? = when (this?.type) {
        "TRIP" -> SessionKind.TRIP
        "CHARGE" -> SessionKind.CHARGE
        "PARKED" -> SessionKind.PARKED
        else -> null
    }

    private fun freshFloat(
        snapshot: Map<SignalKey, SignalSample>,
        signalId: SignalKey,
        timestamp: SignalTimestamp
    ): Float? {
        val sample = snapshot[signalId] ?: return null
        val isFresh = timestamp.receivedAtElapsedNanos - sample.timestamp.receivedAtElapsedNanos <= FRESH_NANOS
        if (!isFresh || sample.quality != SignalQuality.MEASURED) return null
        return sample.floatValue()
    }

    companion object {
        private const val TAG = "FrameRepository"
        private const val FRESH_CAN_NANOS = 500_000_000L

        /**
         * How often the minutes in memory are written. Ten seconds is what a
         * kill costs, against roughly three tiny upserts per interval — next to
         * nothing beside the frame already being written every second.
         */
        private const val ENERGY_FLUSH_INTERVAL_MILLIS = 10_000L

        /**
         * Minutes each flush rewrites. Far wider than the interval needs, so a
         * flush dropped for a full write queue is covered by the next one
         * instead of leaving a hole nothing goes back for. Ten rows of nine
         * doubles is not worth economising on.
         */
        private const val ENERGY_FLUSH_WINDOW_MINUTES = 10

        /** Ten seconds. Divides the minute, so the two cuts stay reconcilable. */
        const val EFFICIENCY_BUCKET_MILLIS = 10_000L

        /** Ninety buckets: the last fifteen minutes the card shows. */
        const val EFFICIENCY_WINDOW_BUCKETS = 90

        /** Ten seconds, for the same reason as the efficiency cut. */
        const val CHARGE_CLIMATE_BUCKET_MILLIS = 10_000L

        /**
         * Six buckets: one minute behind the climate warning.
         *
         * Wide enough that a compressor cycle does not make the warning blink,
         * narrow enough that the warning follows the climate control within a
         * minute of the driver touching it.
         */
        const val CHARGE_CLIMATE_WINDOW_BUCKETS = 6
        private const val FRESH_NANOS = 30_000_000_000L
        private const val CHART_POINT_LIMIT = 1_200
        private const val DETAIL_PAGE_SIZE = 500
        private const val MAX_FRAME_BATCH_SIZE = 16
        private const val FRAME_BATCH_WINDOW_MILLIS = 1_000L
        private const val MAP_PREVIEW_POINT_LIMIT = 220
        private const val MAP_EXPANDED_POINT_LIMIT = 350
    }
}

/**
 * Maps storage's `can*` integral to the public `measured*` wire contract.
 *
 * The measured Wh/km deliberately uses the same odometer-first distance chosen
 * for the SOC estimate. Unlike the SOC figure, it has no 1 km or SOC-step gate;
 * a short trip still has a direct instrument measurement.
 */
internal fun measuredTripEnergyMap(
    integral: TripPowerIntegral?,
    agreesWithSoc: Boolean?,
    distanceKm: Double?
): Map<String, Any?> {
    val usableDistance = distanceKm?.takeIf { it.isFinite() && it >= 0.01 }
    return mapOf(
        "measuredPackWh" to integral?.packWh,
        "measuredTractionWh" to integral?.tractionWh,
        "measuredRegeneratedWh" to integral?.regeneratedWh,
        "measuredAuxiliaryWh" to integral?.auxiliaryWh,
        "measuredSeconds" to integral?.integratedSeconds,
        "measuredAgreesWithSoc" to agreesWithSoc,
        "measuredWhPerKm" to if (integral != null && usableDistance != null) {
            integral.packWh / usableDistance
        } else {
            null
        },
        "measuredRegenerationRatio" to integral?.regenerationRatio
    )
}

/**
 * Estimates a trip cost with the price stored on its preceding charge.
 *
 * There is one energy — the integral — so there is one thing to price. A sign
 * check that **contradicts** SOC withholds the cost rather than falling back:
 * the old fallback was the SOC estimate, and decision 5 removed it. An
 * unconfirmed sign (SOC did not move) still prices, because a short trip is not
 * a wrong trip.
 */
internal fun tripCostEstimateMap(
    costPerKwh: Double?,
    currency: String?,
    netEnergyKwh: Double?,
    measuredAgreesWithSoc: Boolean?
): Map<String, Any?> {
    val usableRate = costPerKwh?.takeIf { it.isFinite() && it >= 0.0 }
    val usableCurrency = currency?.trim()?.takeIf { it.isNotEmpty() }
    val energyKwh = if (measuredAgreesWithSoc == false) {
        null
    } else {
        netEnergyKwh?.takeIf { it.isFinite() && it >= 0.0 }
    }
    return mapOf(
        "lastChargeCostPerKwh" to usableRate,
        "lastChargeCostCurrency" to usableCurrency,
        "estimatedTripCost" to if (usableRate != null && energyKwh != null) {
            usableRate * energyKwh
        } else {
            null
        }
    )
}

/**
 * The frame the energy accumulators are given, from the parts that make it.
 *
 * Pure, so a test can drive a sequence of snapshots through
 * [HeldVehicleReadings] and read exactly what the accumulator would receive.
 * `FrameRepository` itself cannot be built on the JVM — it opens the Room
 * database in its constructor — and the thing worth pinning was never the
 * repository, it was what it hands on. See issue 188, first criterion.
 *
 * [nowUtcMillis] is the wall stamp; the elapsed clock comes from [metrics],
 * and the held readings are asked for their value at that same instant, so a
 * reading too old to count comes back absent rather than stale.
 */
internal fun composeCanStreamSample(
    metrics: RoadcastTripMetrics,
    speed: VhalSpeedReading?,
    held: HeldVehicleReadings,
    nowUtcMillis: Long
): CanStreamSample = CanStreamSample(
    elapsedRealtimeNanos = metrics.receivedAtElapsedNanos,
    wallTimeUtcMillis = nowUtcMillis,
    canDrivePowerKw = metrics.drivePowerKw,
    canPackVoltageV = metrics.packVoltageV,
    canPackCurrentA = metrics.packCurrentA,
    speedKmh = speed?.speedKmh,
    odometerKm = held.odometerKmAt(metrics.receivedAtElapsedNanos),
    socPercent = held.socPercentAt(metrics.receivedAtElapsedNanos),
    speedElapsedRealtimeNanos = speed?.elapsedRealtimeNanos,
    speedWallTimeUtcMillis = speed?.wallTimeUtcMillis,
    canClimatePowerKw = metrics.thermalPowerKw
)

internal data class VhalSpeedReading(
    val speedKmh: Float,
    val elapsedRealtimeNanos: Long,
    val wallTimeUtcMillis: Long
)

/** Selects the source persisted in telemetry_frames.speedKmh. */
internal fun persistedFrameSpeedKmh(
    snapshot: Map<SignalKey, SignalSample>,
    @Suppress("UNUSED_PARAMETER") roadcastMetrics: RoadcastTripMetrics?,
): Float? {
    val sample = snapshot[SignalKey.VEHICLE_SPEED] ?: return null
    return carPropertyVehicleSpeedKmh(sample)
}

internal fun carPropertyVehicleSpeedKmh(sample: SignalSample): Float? {
    if (sample.source != SignalSource.VHAL_CALLBACK &&
        sample.source != SignalSource.VHAL_POLLING
    ) {
        return null
    }
    return sample.floatValue()
}

private fun emptyChargeSessionDetailMap(sessionId: String): Map<String, Any?> = mapOf(
    "sessionId" to sessionId,
    "totalCount" to 0,
    "estimatedEnergyKwh" to null,
    "averagePowerKw" to null,
    "socSeries" to emptyList<Map<String, Any?>>(),
    "voltageSeries" to emptyList<Map<String, Any?>>(),
    "currentSeries" to emptyList<Map<String, Any?>>(),
    "powerSeries" to emptyList<Map<String, Any?>>()
)

private fun emptyTripSessionDetailMap(sessionId: String): Map<String, Any?> = mapOf(
    "sessionId" to sessionId,
    "totalCount" to 0,
    "speedEstimatedDistanceKm" to null,
    "odometerDistanceKm" to null,
    "energyConsumedKwh" to null,
    "energyRegeneratedKwh" to null,
    "netEnergyKwh" to null,
    "netSocDropPercent" to null,
    "socStepPercent" to null,
    "efficiencyWhPerKm" to null,
    "efficiencyKmPerKwh" to null,
    "capacityWh" to null,
    "measuredPackWh" to null,
    "measuredTractionWh" to null,
    "measuredRegeneratedWh" to null,
    "measuredAuxiliaryWh" to null,
    "measuredSeconds" to null,
    "measuredAgreesWithSoc" to null,
    "measuredWhPerKm" to null,
    "measuredRegenerationRatio" to null,
    "lastChargeCostPerKwh" to null,
    "lastChargeCostCurrency" to null,
    "estimatedTripCost" to null,
    "speedSeries" to emptyList<Map<String, Any?>>(),
    "socSeries" to emptyList<Map<String, Any?>>(),
    "altitudeSeries" to emptyList<Map<String, Any?>>(),
    "ambientTempSeries" to emptyList<Map<String, Any?>>(),
    "measuredPackPowerSeries" to emptyList<Map<String, Any?>>(),
    "measuredDrivePowerSeries" to emptyList<Map<String, Any?>>(),
    "gpsPointCount" to 0,
    "meanAmbientTempC" to null,
    "altitudeGainM" to null,
    "altitudeLossM" to null,
    "mapPreviewPoints" to emptyList<Map<String, Any?>>(),
    "mapExpandedPoints" to emptyList<Map<String, Any?>>()
)

private fun tripContextMap(
    session: SessionEntity?,
): Map<String, Any?> = mapOf(
    "meanAmbientTempC" to session?.meanAmbientTempC?.toDouble(),
    "altitudeGainM" to null,
    "altitudeLossM" to null,
)

private fun SignalQuality.toValidity(): String = when (this) {
    SignalQuality.MEASURED -> "MEASURED"
    SignalQuality.DERIVED -> "ESTIMATED"
    SignalQuality.UNAVAILABLE, SignalQuality.ERROR -> "INVALID"
}

private fun SignalSample.doubleValue(): Double? = (value as? Number)?.toDouble()

/** The numeric value of a sample, or null when it carries something else. */
internal fun SignalSample.numericDoubleValue(): Double? = when (val v = value) {
    is Number -> v.toDouble()
    is Boolean -> if (v) 1.0 else 0.0
    else -> null
}
