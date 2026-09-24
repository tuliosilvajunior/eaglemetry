package com.timhss.capyenergy.bridge

import com.timhss.capyenergy.bridge.generated.AnnotationChangeWire
import com.timhss.capyenergy.bridge.generated.AnnotationsChangedStreamHandler
import com.timhss.capyenergy.bridge.generated.BatteryCycleSessionsWire
import com.timhss.capyenergy.bridge.generated.BatteryCycleSessionKindWire
import com.timhss.capyenergy.bridge.generated.BatteryCycleSessionWire
import com.timhss.capyenergy.bridge.generated.BatteryCycleWire
import com.timhss.capyenergy.bridge.generated.BatteryCyclesWire
import com.timhss.capyenergy.bridge.generated.ChargeMergeBreakWire
import com.timhss.capyenergy.bridge.generated.ChargeMergeCandidateWire
import com.timhss.capyenergy.bridge.generated.ChargeMergeCandidatesWire
import com.timhss.capyenergy.bridge.generated.ChargeMergeResultWire
import com.timhss.capyenergy.bridge.generated.ChargeSessionCostUpdateWire
import com.timhss.capyenergy.bridge.generated.ChargeSessionWire
import com.timhss.capyenergy.bridge.generated.EnergyBucketWire
import com.timhss.capyenergy.bridge.generated.HeadingWire
import com.timhss.capyenergy.bridge.generated.EnergyWindowBucketsWire
import com.timhss.capyenergy.bridge.generated.InsightPlaceWire
import com.timhss.capyenergy.bridge.generated.InsightPlacesWire
import com.timhss.capyenergy.bridge.generated.InsightTripWire
import com.timhss.capyenergy.bridge.generated.InsightTripsWire
import com.timhss.capyenergy.bridge.generated.LiveEnergyBucketsWire
import com.timhss.capyenergy.bridge.generated.IntervalRecordWire
import com.timhss.capyenergy.bridge.generated.MeasurementWire
import com.timhss.capyenergy.bridge.generated.PageRequestWire
import com.timhss.capyenergy.bridge.generated.PreferenceProposalWire
import com.timhss.capyenergy.bridge.generated.PreferenceRowWire
import com.timhss.capyenergy.bridge.generated.SamplePointWire
import com.timhss.capyenergy.bridge.generated.SampleSeriesWire
import com.timhss.capyenergy.bridge.generated.SessionDetailWire
import com.timhss.capyenergy.bridge.generated.SessionFilterWire
import com.timhss.capyenergy.bridge.generated.SessionListPageWire
import com.timhss.capyenergy.bridge.generated.SessionRecordWire
import com.timhss.capyenergy.bridge.generated.SessionRollupWire
import com.timhss.capyenergy.bridge.generated.TelemetryEventRecordWire
import com.timhss.capyenergy.bridge.generated.TelemetrySeriesWire
import com.timhss.capyenergy.bridge.generated.TrackRowWire
import com.timhss.capyenergy.bridge.generated.TelemetryWireApi
import com.timhss.capyenergy.bridge.generated.TelemetryWireError
import com.timhss.capyenergy.bridge.generated.TripSessionWire
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.PreferenceEntity
import com.timhss.capyenergy.telemetry.db.PreferenceProposalEntity
import com.timhss.capyenergy.telemetry.db.SessionCostEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryEventEntity
import com.timhss.capyenergy.telemetry.db.TrackEntity
import com.timhss.capyenergy.telemetry.AnnotationChange
import com.timhss.capyenergy.telemetry.AnnotationChangeBroadcaster
import com.timhss.capyenergy.telemetry.BatteryCycleRow
import com.timhss.capyenergy.telemetry.BatteryCycleSessionRow
import com.timhss.capyenergy.telemetry.ChargeCostUpdate
import com.timhss.capyenergy.telemetry.ChargeMergeBreakRow
import com.timhss.capyenergy.telemetry.ChargeMergeCandidateRow
import com.timhss.capyenergy.telemetry.ChargeMergeOutcome
import com.timhss.capyenergy.telemetry.ChargeSessionRow
import com.timhss.capyenergy.telemetry.ClockAnchorStore
import com.timhss.capyenergy.telemetry.WallClockGuard
import com.timhss.capyenergy.telemetry.SessionChange
import com.timhss.capyenergy.telemetry.SessionChangeBroadcaster
import com.timhss.capyenergy.telemetry.EnergyBucket
import com.timhss.capyenergy.telemetry.FrameRepository
import com.timhss.capyenergy.telemetry.InsightPlaceRow
import com.timhss.capyenergy.telemetry.InsightTripRow
import android.os.Handler
import android.os.Looper
import com.timhss.capyenergy.bridge.generated.PigeonEventSink
import com.timhss.capyenergy.bridge.generated.RangeEstimateWire
import com.timhss.capyenergy.bridge.generated.SessionChangeWire
import com.timhss.capyenergy.bridge.generated.SessionsChangedStreamHandler
import com.timhss.capyenergy.telemetry.LiveEnergyBuckets
import com.timhss.capyenergy.telemetry.NativeRangeEstimate
import com.timhss.capyenergy.telemetry.TelemetryRuntime
import com.timhss.capyenergy.telemetry.TripSessionRow
import com.timhss.capyenergy.telemetry.VehicleHeading
import com.timhss.capyenergy.telemetry.WindowEnergySeries

/**
 * The typed half of the bridge.
 *
 * `TelemetryBridge` dispatches on a method name and answers with a
 * `Map<String, Any?>`; nothing checks that the keys it writes are the keys
 * Flutter reads. Methods described in `pigeons/telemetry_wire.dart` are handled
 * here instead, against a generated interface, so a field rename fails to
 * compile on both sides rather than reaching the car as a null.
 *
 * Pigeon puts these calls on their own channels and its own background task
 * queue, so `TelemetryBridge` no longer routes them and its executors do not
 * serialize them.
 *
 * Error codes match what the map-based bridge reported for the same failures,
 * because they are what the Flutter side shows when a read fails on the car.
 */
class TelemetryWireHandler(
    private val telemetryRuntime: TelemetryRuntime,
) : TelemetryWireApi {

    override fun getEnergyBucketsInWindow(minutes: Long): EnergyWindowBucketsWire =
        guard("ENERGY_BUCKETS_WINDOW_FAILED") {
            require(minutes > 0) {
                "getEnergyBucketsInWindow requires a positive minutes"
            }
            val now = System.currentTimeMillis()
            telemetryRuntime.energySeriesInWindow(
                startUtcMillis = now - minutes * 60_000L,
                endUtcMillis = now
            ).toWire()
        }

    override fun getParkedEnergyBucketsInWindow(minutes: Long): EnergyWindowBucketsWire =
        guard("PARKED_ENERGY_BUCKETS_WINDOW_FAILED") {
            require(minutes > 0) {
                "getParkedEnergyBucketsInWindow requires a positive minutes"
            }
            val now = System.currentTimeMillis()
            telemetryRuntime.parkedEnergySeriesInWindow(
                startUtcMillis = now - minutes * 60_000L,
                endUtcMillis = now
            ).toWire()
        }

    override fun getLiveEnergyBuckets(): LiveEnergyBucketsWire =
        guard("LIVE_ENERGY_BUCKETS_FAILED") {
            telemetryRuntime.liveEnergySeries()
                ?.toWire()
                ?: emptyLiveEnergyBuckets(EnergyBucket.BUCKET_MILLIS)
        }

    override fun getLiveEfficiencyBuckets(): LiveEnergyBucketsWire =
        guard("LIVE_EFFICIENCY_BUCKETS_FAILED") {
            telemetryRuntime.liveEfficiencySeries()
                ?.toWire()
                ?: emptyLiveEnergyBuckets(telemetryRuntime.efficiencyBucketMillis())
        }

    override fun getLiveChargeEnergyBuckets(): LiveEnergyBucketsWire =
        guard("LIVE_CHARGE_ENERGY_BUCKETS_FAILED") {
            telemetryRuntime.liveChargeEnergySeries()
                ?.toWire()
                ?: emptyLiveEnergyBuckets(FrameRepository.CHARGE_CLIMATE_BUCKET_MILLIS)
        }

    override fun getLiveContinuousEnergyBuckets(): LiveEnergyBucketsWire =
        guard("LIVE_CONTINUOUS_ENERGY_BUCKETS_FAILED") {
            telemetryRuntime.liveContinuousEnergySeries()
                ?.toWire()
                ?: emptyLiveEnergyBuckets(EnergyBucket.BUCKET_MILLIS)
        }

    override fun getRangeEstimate(): RangeEstimateWire =
        guard("RANGE_ESTIMATE_READ_FAILED") {
            telemetryRuntime.rangeEstimate().toWire()
        }

    override fun getHeading(): HeadingWire =
        guard("HEADING_READ_FAILED") {
            telemetryRuntime.heading().toWire()
        }

    override fun getBatteryCycles(limit: Long): BatteryCyclesWire =
        guard("BATTERY_CYCLES_FAILED") {
            require(limit > 0) { "getBatteryCycles requires a positive limit" }
            val page = telemetryRuntime.batteryCycles(limit.toInt())
            BatteryCyclesWire(
                cycles = page.cycles.map { it.toWire() },
                totalCount = page.totalCount,
                limit = page.limit.toLong(),
            )
        }

    override fun getBatteryCycleSessions(ordinal: Long): BatteryCycleSessionsWire =
        guard("BATTERY_CYCLE_SESSIONS_FAILED") {
            require(ordinal > 0) { "getBatteryCycleSessions requires a positive ordinal" }
            val page = telemetryRuntime.batteryCycleSessions(ordinal)
            BatteryCycleSessionsWire(
                ordinal = page.ordinal,
                sessions = page.sessions.map { it.toWire() },
            )
        }

    override fun getInsightTrips(subjectId: String?): InsightTripsWire =
        guard("INSIGHT_TRIPS_FAILED") {
            val page = telemetryRuntime.insightTrips(subjectId)
            InsightTripsWire(
                trips = page.trips.map { it.toWire() },
                subjectId = page.subjectId,
            )
        }

    override fun getInsightPlaces(): InsightPlacesWire =
        guard("INSIGHT_PLACES_FAILED") {
            InsightPlacesWire(
                places = telemetryRuntime.insightPlaces().map { it.toWire() },
            )
        }

    override fun saveInsightPlace(
        id: String?,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusM: Double,
        autoName: String?,
        autoNameUpdatedAtUtcMillis: Long?,
        autoNameSource: String?,
    ): InsightPlaceWire = guard("INSIGHT_PLACE_SAVE_FAILED") {
        telemetryRuntime.saveInsightPlace(
            id = id,
            name = name,
            latitude = latitude,
            longitude = longitude,
            radiusM = radiusM,
            autoName = autoName,
            autoNameUpdatedAtUtcMillis = autoNameUpdatedAtUtcMillis,
            autoNameSource = autoNameSource,
        ).toWire()
    }

    override fun deleteInsightPlace(id: String) {
        guard("INSIGHT_PLACE_DELETE_FAILED") {
            require(id.isNotBlank()) { "deleteInsightPlace requires an id" }
            telemetryRuntime.deleteInsightPlace(id)
        }
    }

    override fun getChargeMergeCandidates(limit: Long): ChargeMergeCandidatesWire =
        guard("CHARGE_MERGE_CANDIDATES_FAILED") {
            val page = telemetryRuntime.chargeMergeCandidates(limit.toInt())
            ChargeMergeCandidatesWire(
                candidates = page.candidates.map { it.toWire() },
                totalCount = page.totalCount.toLong(),
                limit = page.limit.toLong(),
            )
        }

    override fun mergeChargeSessions(sessionIds: List<String>): ChargeMergeResultWire =
        guard("CHARGE_SESSION_MERGE_FAILED") {
            require(sessionIds.size >= 2) {
                "mergeChargeSessions requires at least two sessionIds"
            }
            telemetryRuntime.mergeChargeSessions(sessionIds).toWire()
        }

    override fun updateChargeSessionCost(
        sessionId: String,
        costPerKwh: Double?,
        paidAmount: Double?,
        currency: String,
    ): ChargeSessionCostUpdateWire = guard("CHARGE_SESSION_COST_FAILED") {
        require(sessionId.isNotBlank()) { "updateChargeSessionCost requires sessionId" }
        telemetryRuntime.updateChargeSessionCost(
            sessionId = sessionId,
            costPerKwh = costPerKwh,
            paidAmount = paidAmount,
            currency = currency,
        ).toWire()
    }

    override fun getPreferenceRows(): List<PreferenceRowWire> =
        guard("PREFERENCE_ROWS_FAILED") {
            telemetryRuntime.preferenceRows().map { it.toWire() }
        }

    override fun savePreferenceRow(
        scope: String,
        key: String,
        value: String?,
    ): PreferenceRowWire? = guard("PREFERENCE_SAVE_FAILED") {
        require(scope.isNotBlank() && key.isNotBlank()) {
            "savePreferenceRow requires scope and key"
        }
        telemetryRuntime.savePreferenceFromCar(scope, key, value)?.toWire()
    }

    override fun getPreferenceProposals(): List<PreferenceProposalWire> =
        guard("PREFERENCE_PROPOSALS_FAILED") {
            telemetryRuntime.pendingPreferenceProposals().map { it.toWire() }
        }

    override fun proposePreference(key: String, value: String?): PreferenceProposalWire? =
        guard("PREFERENCE_PROPOSE_FAILED") {
            require(key.isNotBlank()) { "proposePreference requires a key" }
            telemetryRuntime.proposePreference(key, value)?.toWire()
        }

    override fun decidePreferenceProposal(
        id: String,
        accept: Boolean,
    ): PreferenceProposalWire? = guard("PREFERENCE_DECIDE_FAILED") {
        require(id.isNotBlank()) { "decidePreferenceProposal requires an id" }
        telemetryRuntime.decidePreferenceProposal(id, accept)?.toWire()
    }

    override fun storeListSessions(
        filter: SessionFilterWire?,
        page: PageRequestWire?,
    ): SessionListPageWire = guard("STORE_LIST_SESSIONS_FAILED") {
        val limit = page?.limit?.toInt() ?: 50
        val offset = page?.offset?.toInt() ?: 0
        val kind = filter?.kind?.uppercase()
        val status = filter?.status
        val fromUtc = filter?.fromUtcMillis
        val toUtc = filter?.toUtcMillis
        val sessionDao = telemetryRuntime.database.sessionDao()
        val accountId = telemetryRuntime.partialCurrentAccountId()
        val entities = sessionDao.listSessionsSatisfyingAccount(
            accountId = accountId,
            kind = kind,
            status = status,
            fromUtcMillis = fromUtc,
            toUtcMillis = toUtc,
            limit = limit,
            offset = offset,
        )
        val totalCount = sessionDao.countSessionsSatisfyingAccount(
            accountId = accountId,
            kind = kind,
            status = status,
            fromUtcMillis = fromUtc,
            toUtcMillis = toUtc,
        )
        val hasMore = offset + entities.size < totalCount
        // The cost keys on the wire are frozen; the values live in the
        // annotation table since slice 6, so the page composes them here.
        val costs = telemetryRuntime.database.sessionCostDao()
            .forSessions(entities.map { it.id })
            .associateBy { it.sessionId }

        SessionListPageWire(
            sessions = entities.map { it.toRecordWire(cost = costs[it.id]) },
            totalCount = totalCount,
            limit = limit.toLong(),
            offset = offset.toLong(),
            hasMore = hasMore,
        )
    }

    override fun storeGetSession(id: String): SessionDetailWire? =
        guard("STORE_GET_SESSION_FAILED") {
            require(id.isNotBlank()) { "storeGetSession requires a non-empty id" }
            val db = telemetryRuntime.database
            val session = db.sessionDao().findById(id) ?: return@guard null
            val events = db.telemetryEventDao().forSession(id)
            val track = db.trackDao().forSession(id)
            SessionDetailWire(
                session = session.toRecordWire(cost = db.sessionCostDao().findById(id)),
                events = events.map { it.toRecordWire() },
                track = track?.toTrackRowWire(),
            )
        }

    override fun storeGetSeries(
        id: String,
        keys: List<String>?,
        widthMillis: Long?,
    ): TelemetrySeriesWire = guard("STORE_GET_SERIES_FAILED") {
        require(id.isNotBlank()) { "storeGetSeries requires a non-empty id" }
        val db = telemetryRuntime.database
        val intervals = db.intervalDao().forSession(id)

        TelemetrySeriesWire(
            sessionId = id,
            intervals = intervals.map { it.toRecordWire() },
            sampleSeries = emptyList(),
        )
    }

    /**
     * Finding 14: no live session on this stream. Shared by the trip,
     * efficiency, charge, parked and continuous live reads — not a
     * no-trip verdict, since the other streams may be live while this one
     * is empty. The reader gets the width it would have been cut to and
     * nothing else.
     */
    private fun emptyLiveEnergyBuckets(bucketMillis: Long) = LiveEnergyBucketsWire(
        bucketMillis = bucketMillis,
        buckets = emptyList(),
        sessionId = null,
        startedAtUtcMillis = null,
    )

    private fun <T> guard(code: String, block: () -> T): T = try {
        block()
    } catch (e: Exception) {
        throw TelemetryWireError(code, e.message ?: e.javaClass.simpleName, null)
    }
}

internal fun EnergyBucket.toWire(): EnergyBucketWire = EnergyBucketWire(
    startUtcMillis = startUtcMillis,
    tractionWh = tractionWh,
    regeneratedWh = regeneratedWh,
    auxiliaryWh = auxiliaryWh,
    integratedSeconds = integratedSeconds,
    speedDistanceKm = speedDistanceKm,
    odometerDistanceKm = odometerDistanceKm,
    speedIntegratedSeconds = speedIntegratedSeconds,
    climateWh = climateWh,
    climateIntegratedSeconds = climateIntegratedSeconds,
    deliveredWh = deliveredWh,
    startSoc = startSoc,
    endSoc = endSoc,
    startVoltage = startVoltage,
    endVoltage = endVoltage,
)

internal fun WindowEnergySeries.toWire(): EnergyWindowBucketsWire = EnergyWindowBucketsWire(
    startUtcMillis = startUtcMillis,
    endUtcMillis = endUtcMillis,
    sessionCount = sessionCount.toLong(),
    resampledSessionCount = resampledSessionCount.toLong(),
    buckets = buckets.map { it.toWire() },
    lastChargeCostPerKwh = lastChargeCostPerKwh,
    lastChargeCostCurrency = lastChargeCostCurrency,
)

internal fun VehicleHeading.toWire(): HeadingWire = HeadingWire(
    timestampMillis = timestampMillis,
    availability = availability.name,
    bearingDeg = bearingDeg,
    bearingAccuracyDeg = bearingAccuracyDeg,
    speedMps = speedMps,
    fixAgeMillis = fixAgeMillis,
)

internal fun NativeRangeEstimate.toWire(): RangeEstimateWire = RangeEstimateWire(
    timestampMillis = timestampMillis,
    carRangeQuality = carRangeQuality.name,
    carRangePropertyId = carRangePropertyId.toLong(),
    capacityKwh = capacityKwh,
    capacitySource = capacitySource,
    efficiencyTripCount = efficiencyTripCount.toLong(),
    ownRangeQuality = ownRangeQuality.name,
    carRangeKm = carRangeKm,
    carRangeReason = carRangeReason,
    carRangeSignalSource = carRangeSignalSource,
    carRangeReceivedAtUtcMillis = carRangeReceivedAtUtcMillis,
    carRangeSourceTimestampNanos = carRangeSourceTimestampNanos,
    socPercent = socPercent,
    efficiencyKmPerKwh = efficiencyKmPerKwh,
    efficiencySource = efficiencySource,
    efficiencyWindowDays = efficiencyWindowDays?.toLong(),
    efficiencyDistanceKm = efficiencyDistanceKm,
    efficiencyNetEnergyKwh = efficiencyNetEnergyKwh,
    efficiencyUpdatedAtUtcMillis = efficiencyUpdatedAtUtcMillis,
    fullRangeKm = fullRangeKm,
    ownRangeKm = ownRangeKm,
    ownRangeReason = ownRangeReason,
)
internal fun LiveEnergyBuckets.toWire(): LiveEnergyBucketsWire = LiveEnergyBucketsWire(
    bucketMillis = bucketMillis,
    buckets = buckets.map { it.toWire() },
    sessionId = sessionId,
    startedAtUtcMillis = startedAtUtcMillis,
    // Unlearned anchor means birth-clock stamps. But the accumulator keeps
    // the anchor of its first sample for the whole session, so stamps stay
    // on the birth line even after the anchor learns mid-session — until the
    // session rotates. A series whose newest bucket lags now past the guard
    // tolerance is on that stale line, whatever the anchor says (G5).
    timeUnsynced =
        !ClockAnchorStore.isLearned() ||
            (buckets.maxOfOrNull { it.startUtcMillis }?.let {
                System.currentTimeMillis() - it > WallClockGuard.TOLERANCE_MILLIS
            } ?: false),
)


internal fun InsightTripRow.toWire(): InsightTripWire = InsightTripWire(
    id = id,
    hasMinuteBuckets = hasMinuteBuckets,
    endedAtUtcMillis = endedAtUtcMillis,
    rollupDistanceKm = rollupDistanceKm,
    startOdometerKm = startOdometerKm,
    endOdometerKm = endOdometerKm,
    rollupTractionWh = rollupTractionWh,
    rollupRegenWh = rollupRegenWh,
    rollupAuxiliaryWh = rollupAuxiliaryWh,
    socAgreesWithIntegral = socAgreesWithIntegral,
    startLatitude = startLatitude,
    startLongitude = startLongitude,
    endLatitude = endLatitude,
    endLongitude = endLongitude,
    path = path,
    meanAmbientTempC = meanAmbientTempC,
)

internal fun InsightPlaceRow.toWire(): InsightPlaceWire = InsightPlaceWire(
    id = id,
    name = name,
    latitude = latitude,
    longitude = longitude,
    radiusM = radiusM,
    autoName = autoName,
    autoNameUpdatedAtUtcMillis = autoNameUpdatedAtUtcMillis,
    autoNameSource = autoNameSource,
)

internal fun BatteryCycleRow.toWire(): BatteryCycleWire = BatteryCycleWire(
    ordinal = ordinal,
    startUtcMillis = startUtcMillis,
    endUtcMillis = endUtcMillis,
    dischargePercent = dischargePercent,
    distanceKm = distanceKm,
    tripEnergyKwh = tripEnergyKwh,
    parkedEnergyKwh = parkedEnergyKwh,
    parkedSocPercent = parkedSocPercent,
    pricedEnergyKwh = pricedEnergyKwh,
    unpricedEnergyKwh = unpricedEnergyKwh,
    isOpen = isOpen,
    isPartial = isPartial,
    energyIncomplete = energyIncomplete,
    mixedCurrency = mixedCurrency,
    updatedAtUtcMillis = updatedAtUtcMillis,
    cost = cost,
    costCurrency = costCurrency,
    frozenAtUtcMillis = frozenAtUtcMillis,
)

internal fun BatteryCycleSessionRow.toWire(): BatteryCycleSessionWire =
    BatteryCycleSessionWire(
        kind = when (kind) {
            "TRIP" -> BatteryCycleSessionKindWire.TRIP
            "CHARGE" -> BatteryCycleSessionKindWire.CHARGE
            else -> BatteryCycleSessionKindWire.PARKED
        },
        sessionId = sessionId,
        share = share,
        startUtcMillis = startUtcMillis,
        endUtcMillis = endUtcMillis,
        deleted = deleted,
        trip = trip?.toWire(),
        charge = charge?.toWire(),
    )

internal fun TripSessionRow.toWire(): TripSessionWire = TripSessionWire(
    id = session.id,
    status = session.status,
    startedAtUtcMillis = session.startedAtUtcMillis,
    startedAtElapsedNanos = session.startedAtElapsedNanos,
    createdAtUtcMillis = session.createdAtUtcMillis,
    updatedAtUtcMillis = updatedAtUtcMillis,
    movementStartedAtUtcMillis = session.movementStartedAtUtcMillis,
    movementStartedAtElapsedNanos = session.movementStartedAtElapsedNanos,
    endedAtUtcMillis = session.endedAtUtcMillis,
    endedAtElapsedNanos = session.endedAtElapsedNanos,
    durationMillis = durationMillis,
    startSoc = session.startSocPercent?.toDouble(),
    endSoc = endSoc?.toDouble(),
    startOdometerKm = session.startOdometerKm?.toDouble(),
    endOdometerKm = endOdometerKm?.toDouble(),
    startGear = session.startGear?.toLong(),
    endReason = session.endReason,
    capacityWh = null,
)

internal fun ChargeSessionRow.toWire(): ChargeSessionWire = ChargeSessionWire(
    id = session.id,
    status = session.status,
    plugConnectedAtUtcMillis = session.startedAtUtcMillis,
    plugConnectedAtElapsedNanos = session.startedAtElapsedNanos,
    createdAtUtcMillis = session.createdAtUtcMillis,
    updatedAtUtcMillis = updatedAtUtcMillis,
    chargeStartedAtUtcMillis = session.chargeStartedAtUtcMillis,
    chargeStartedAtElapsedNanos = session.chargeStartedAtElapsedNanos,
    chargeEndedAtUtcMillis = session.chargeEndedAtUtcMillis,
    chargeEndedAtElapsedNanos = session.chargeEndedAtElapsedNanos,
    plugDisconnectedAtUtcMillis = session.plugDisconnectedAtUtcMillis,
    plugDisconnectedAtElapsedNanos = session.plugDisconnectedAtElapsedNanos,
    durationMillis = durationMillis,
    startSoc = session.startSocPercent?.toDouble(),
    endSoc = endSoc?.toDouble(),
    startOdometerKm = session.startOdometerKm?.toDouble(),
    endOdometerKm = endOdometerKm?.toDouble(),
    plugType = session.plugType?.toLong(),
    startPowerKw = session.startPowerKw?.toDouble(),
    estimatedEnergyKwh = estimatedEnergyKwh,
    costPerKwh = session.costPerKwh,
    paidAmount = session.paidAmount,
    costCurrency = session.costCurrency,
    startAmbientTempC = session.startAmbientTempC?.toDouble(),
    endAmbientTempC = endAmbientTempC?.toDouble(),
    startLatitude = session.startLatitude,
    startLongitude = session.startLongitude,
    startAltitudeM = session.startAltitudeM,
    startGpsAccuracyM = session.startGpsAccuracyM?.toDouble(),
    startLocationProvider = session.startLocationProvider,
    startLocationElapsedRealtimeNanos = session.startLocationElapsedRealtimeNanos,
    chargeEndReason = session.chargeEndReason,
    endReason = session.endReason,
)

internal fun ChargeMergeBreakRow.toWire(): ChargeMergeBreakWire = ChargeMergeBreakWire(
    previousSessionId = previousSessionId,
    nextSessionId = nextSessionId,
    gapMillis = gapMillis,
    socDelta = socDelta?.toDouble(),
    odometerDeltaKm = odometerDeltaKm?.toDouble(),
)

internal fun ChargeMergeCandidateRow.toWire(): ChargeMergeCandidateWire =
    ChargeMergeCandidateWire(
        sessionIds = sessionIds,
        sessions = sessions.map { it.toWire() },
        breaks = breaks.map { it.toWire() },
        startUtcMillis = startUtcMillis,
        endUtcMillis = endUtcMillis,
        durationMillis = durationMillis,
        totalFrames = totalFrames,
        startSoc = startSoc?.toDouble(),
        endSoc = endSoc?.toDouble(),
        startOdometerKm = startOdometerKm?.toDouble(),
        endOdometerKm = endOdometerKm?.toDouble(),
    )

internal fun ChargeMergeOutcome.toWire(): ChargeMergeResultWire = ChargeMergeResultWire(
    ok = ok,
    mergedCount = mergedCount.toLong(),
    framesReassigned = framesReassigned.toLong(),
    deletedSessions = deletedSessions.toLong(),
    error = error,
    mergedSessionId = mergedSessionId,
)

internal fun ChargeCostUpdate.toWire(): ChargeSessionCostUpdateWire =
    ChargeSessionCostUpdateWire(
        ok = ok,
        updatedRows = updatedRows.toLong(),
        session = session?.toWire(),
    )

/**
 * Pushes a session write to Flutter, so a list stops asking whether one
 * happened.
 *
 * One event per write, with no rows in it. The listener is removed when the
 * stream is cancelled: a broadcaster held by the process would otherwise keep
 * a reference to a sink belonging to a Flutter engine that is gone.
 */
class SessionChangeStreamHandler(
    private val changes: SessionChangeBroadcaster,
    private val mainHandler: Handler = Handler(Looper.getMainLooper()),
) : SessionsChangedStreamHandler() {

    private var listener: ((SessionChange) -> Unit)? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<SessionChangeWire>) {
        val listener: (SessionChange) -> Unit = { change ->
            // Session writes arrive on the write executor. An event sink may
            // only be touched from the platform thread, so the hop is required
            // rather than defensive.
            mainHandler.post { sink.success(change.toWire()) }
        }
        this.listener = listener
        changes.addListener(listener)
    }

    override fun onCancel(p0: Any?) {
        listener?.let(changes::removeListener)
        listener = null
        // Anything already posted would reach a sink Flutter has released.
        mainHandler.removeCallbacksAndMessages(null)
    }
}

internal fun SessionChange.toWire(): SessionChangeWire = SessionChangeWire(
    revision = revision,
    trips = trips,
    charges = charges,
    parked = parked,
)

/**
 * Pushes an annotation write to Flutter, so a settings prompt and a place
 * list stop asking whether one happened. Same shape as the session stream:
 * the event carries that something changed, and the reader re-reads.
 */
class AnnotationChangeStreamHandler(
    private val changes: AnnotationChangeBroadcaster,
    private val mainHandler: Handler = Handler(Looper.getMainLooper()),
) : AnnotationsChangedStreamHandler() {

    private var listener: ((AnnotationChange) -> Unit)? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<AnnotationChangeWire>) {
        val listener: (AnnotationChange) -> Unit = { change ->
            mainHandler.post { sink.success(change.toWire()) }
        }
        this.listener = listener
        changes.addListener(listener)
    }

    override fun onCancel(p0: Any?) {
        listener?.let(changes::removeListener)
        listener = null
        mainHandler.removeCallbacksAndMessages(null)
    }
}

internal fun AnnotationChange.toWire(): AnnotationChangeWire = AnnotationChangeWire(
    revision = revision,
    places = places,
    preferences = preferences,
    sessionCosts = sessionCosts,
    proposals = proposals,
    journeys = journeys,
)

internal fun PreferenceEntity.toWire(): PreferenceRowWire = PreferenceRowWire(
    scope = scope,
    key = key,
    value = value,
    updatedAtUtcMillis = updatedAtUtcMillis,
    origin = origin,
    deletedAtUtcMillis = deletedAtUtcMillis,
)

internal fun PreferenceProposalEntity.toWire(): PreferenceProposalWire = PreferenceProposalWire(
    id = id,
    key = key,
    value = value,
    status = status,
    proposedAtUtcMillis = proposedAtUtcMillis,
    updatedAtUtcMillis = updatedAtUtcMillis,
    origin = origin,
    decidedAtUtcMillis = decidedAtUtcMillis,
)

internal fun MeasurementWire(
    value: Double?,
    unit: String,
    validity: String = if (value != null) "measured" else "unreported",
    note: String = "",
): MeasurementWire =
    MeasurementWire(
        value = value,
        unit = unit,
        validity = validity,
        note = note,
    )

internal fun SessionEntity.toRecordWire(cost: SessionCostEntity? = null): SessionRecordWire {
    val priced = cost?.let {
        copy(
            costPerKwh = it.costPerKwh,
            paidAmount = it.paidAmount,
            costCurrency = it.costCurrency
        )
    } ?: this
    val rollup = SessionRollupWire(
        distance = MeasurementWire(priced.rollupDistanceKm, "km"),
        traction = MeasurementWire(priced.rollupTractionWh, "Wh"),
        regen = MeasurementWire(priced.rollupRegenWh, "Wh"),
        auxiliary = MeasurementWire(priced.rollupAuxiliaryWh, "Wh"),
        climate = MeasurementWire(priced.rollupClimateWh, "Wh"),
        delivered = MeasurementWire(priced.rollupDeliveredWh, "Wh"),
        integratedSeconds = MeasurementWire(priced.rollupIntegratedSeconds, "s"),
    )
    val duration = if (priced.endedAtUtcMillis != null) (priced.endedAtUtcMillis - priced.startedAtUtcMillis) else null
    return SessionRecordWire(
        id = priced.id,
        vehicleId = priced.vehicleId,
        kind = priced.kind,
        status = priced.status,
        startedAtUtcMillis = priced.startedAtUtcMillis,
        startedAtElapsedNanos = priced.startedAtElapsedNanos,
        startedAtBootCount = priced.startedAtBootCount?.toLong(),
        endedAtUtcMillis = priced.endedAtUtcMillis,
        endedAtElapsedNanos = priced.endedAtElapsedNanos,
        endedAtBootCount = priced.endedAtBootCount?.toLong(),
        durationMillis = duration,
        rollup = rollup,
        startOdometer = MeasurementWire(priced.startOdometerKm?.toDouble(), "km"),
        endOdometer = MeasurementWire(priced.endOdometerKm?.toDouble(), "km"),
        startSoc = MeasurementWire(priced.startSocPercent?.toDouble(), "%"),
        endSoc = MeasurementWire(priced.endSocPercent?.toDouble(), "%"),
        minSoc = MeasurementWire(priced.minSocPercent?.toDouble(), "%"),
        maxSoc = MeasurementWire(priced.maxSocPercent?.toDouble(), "%"),
        socAgreesWithIntegral = priced.socAgreesWithIntegral,
        startAmbientTemp = MeasurementWire(priced.startAmbientTempC?.toDouble(), "°C"),
        endAmbientTemp = MeasurementWire(priced.endAmbientTempC?.toDouble(), "°C"),
        meanAmbientTemp = MeasurementWire(priced.meanAmbientTempC?.toDouble(), "°C"),
        plugType = priced.plugType?.toLong(),
        costPerKwh = priced.costPerKwh,
        paidAmount = priced.paidAmount,
        costCurrency = priced.costCurrency,
        chargeStartedAtUtcMillis = priced.chargeStartedAtUtcMillis,
        chargeEndedAtUtcMillis = priced.chargeEndedAtUtcMillis,
        plugDisconnectedAtUtcMillis = priced.plugDisconnectedAtUtcMillis,
        movementStartedAtUtcMillis = priced.movementStartedAtUtcMillis,
        chargeEndReason = priced.chargeEndReason,
        endReason = priced.endReason,
        startLatitude = priced.startLatitude,
        startLongitude = priced.startLongitude,
        startAltitudeM = priced.startAltitudeM,
        startGpsAccuracyM = priced.startGpsAccuracyM?.toDouble(),
        startGear = priced.startGear?.toLong(),
        startPowerKw = priced.startPowerKw?.toDouble(),
        movementStartedAtElapsedNanos = priced.movementStartedAtElapsedNanos,
        movementStartedAtBootCount = priced.movementStartedAtBootCount?.toLong(),
        chargeStartedAtElapsedNanos = priced.chargeStartedAtElapsedNanos,
        chargeStartedAtBootCount = priced.chargeStartedAtBootCount?.toLong(),
        chargeEndedAtElapsedNanos = priced.chargeEndedAtElapsedNanos,
        chargeEndedAtBootCount = priced.chargeEndedAtBootCount?.toLong(),
        plugDisconnectedAtElapsedNanos = priced.plugDisconnectedAtElapsedNanos,
        plugDisconnectedAtBootCount = priced.plugDisconnectedAtBootCount?.toLong(),
        noLongerReducible = priced.noLongerReducible,
        createdAtUtcMillis = priced.createdAtUtcMillis,
        updatedAtUtcMillis = priced.updatedAtUtcMillis,
        climbM = priced.climbM,
        descentM = priced.descentM,
        fixCount = priced.fixCount?.toLong(),
        sleepSeconds = priced.sleepSeconds,
        sleepSocDeltaPercent = priced.sleepSocDeltaPercent?.toDouble(),
        sleepEnergyWhEstimate = priced.sleepEnergyWhEstimate,
    )
}

internal fun TelemetryEventEntity.toRecordWire(): TelemetryEventRecordWire =
    TelemetryEventRecordWire(
        id = id,
        sessionId = sessionId,
        type = type,
        occurredAtUtcMillis = occurredAtUtcMillis,
        occurredAtElapsedNanos = occurredAtElapsedNanos,
        signalKey = signalId,
        value = value,
        previousValue = previousValue,
        quality = quality,
        source = source,
        details = details,
    )

internal fun IntervalEntity.toRecordWire(): IntervalRecordWire =
    IntervalRecordWire(
        sessionId = sessionId,
        startUtcMillis = startUtcMillis,
        widthMillis = widthMillis,
        traction = MeasurementWire(tractionWh, "Wh"),
        regen = MeasurementWire(regenWh, "Wh"),
        auxiliary = MeasurementWire(auxiliaryWh, "Wh"),
        climate = MeasurementWire(climateWh, "Wh"),
        delivered = MeasurementWire(deliveredWh, "Wh"),
        distance = MeasurementWire(distanceKm, "km"),
        coveredSeconds = coveredSeconds,
        climateCoveredSeconds = climateCoveredSeconds,
        speedCoveredSeconds = speedCoveredSeconds,
        deliveredCoveredSeconds = deliveredCoveredSeconds,
        startSoc = MeasurementWire(startSoc, "%"),
        endSoc = MeasurementWire(endSoc, "%"),
        startVoltage = MeasurementWire(startVoltage, "V"),
        endVoltage = MeasurementWire(endVoltage, "V"),
        startElapsedNanos = startElapsedNanos,
        startBootCount = startBootCount?.toLong(),
        timeState = timeState,
    )

internal fun TrackEntity.toTrackRowWire(): TrackRowWire =
    TrackRowWire(
        encodingVersion = encodingVersion.toLong(),
        pointCount = pointCount.toLong(),
        path = path,
        t = t,
        speed = speed,
        alt = alt,
    )

