package com.timhss.capyenergy.telemetry

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.telemetry.db.SessionCostEntity
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

class SessionRepository(
    context: Context,
    private val capacityWhProvider: () -> Double? = { null },
    private val vehicleIdProvider: () -> String = { "unassigned" },
    private val defaultChargeCostPerKwhProvider: () -> Double? = { null },
    private val chargeCostCurrencyProvider: () -> String = { "BRL" },
    private val changes: SessionChangeBroadcaster = SessionChangeBroadcaster(),
    private val annotationChanges: AnnotationChangeBroadcaster? = null,
    private val accountIdProvider: () -> String? = { null },
    databaseOverride: TelemetryDatabase? = null,
    private val bootCountProvider: (() -> Int?)? = null,
) : TripSessionStore, ChargeSessionStore, ParkedSessionStore, ContinuousSessionStore {
    private val appContext = context.applicationContext
    private val database = databaseOverride ?: TelemetryDatabase.get(appContext)
    private val sessionDao = database.sessionDao()
    private val intervalDao = database.intervalDao()
    private val sessionFinalizer = SessionFinalizer(
        database = database,
        capacityWhProvider = capacityWhProvider,
        currentBootCountProvider = { currentBootCount()?.toLong() }
    )
    private val writeExecutor = TelemetryWriteCoordinator.executor
    /**
     * G1: when the boot's anchor is learned after a truthless close left
     * pendings behind, sweep the boot on the same single write queue the
     * closes use — serialized with them, off the learn caller's thread
     * (uploader IO or GPS). The sweep is idempotent: a later close or a
     * second learn is a no-op.
     */
    init {
        ClockAnchorStore.onLearned {
            val boot = currentBootCount()?.toLong() ?: return@onLearned
            writeExecutor.executeWrite("anchor_learned_sweep") {
                runCatching {
                    ClockBackfillSweeper(
                        intervalDao,
                        replacedKeyDao = database.intervalReplacedKeyDao(),
                        sessionDao = sessionDao,
                        currentBootCountProvider = { currentBootCount()?.toLong() }
                    ).sweepBoot(boot)
                }.onFailure {
                    Log.w(TAG, "anchor-learned sweep failed for boot $boot", it)
                }
            }
        }
    }

    /**
     * The charge prices, on the annotation side. A cost is both a charge
     * row a list shows and an annotation a replica learns, so a landed
     * write fires both broadcasters.
     */
    private val costRepository = SessionCostRepository(
        context = appContext,
        accountIdProvider = accountIdProvider,
        onChanged = {
            changes.chargesChanged()
            annotationChanges?.sessionCostsChanged()
        }
    )

    private val readExecutor = namedSingleThreadExecutor("sessions-db")
    private val tripWrites = AtomicLong(0L)
    private val chargeWrites = AtomicLong(0L)
    private val pendingFinalizations = AtomicLong(0L)
    private val finalizationFailures = AtomicLong(0L)
    private val lastFinalizedUtcMillis = AtomicLong(0L)
    private val lastFinalizedThroughElapsedNanos = AtomicLong(0L)
    private val lastFinalizationError = AtomicReference<String?>(null)

    @Volatile
    private var frameWriteBarrier: () -> Unit = {}

    override fun createTripSession(
        startedAt: SignalTimestamp,
        movementStartedAt: SignalTimestamp?,
        startSoc: Float?,
        startOdometerKm: Float?,
        startGear: Int?,
        startLocation: LocationSnapshot?,
        status: String
    ): String {
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val bootCount = currentBootCount()
        upsertTrip(
            SessionEntity(
                id = id,
                vehicleId = vehicleIdProvider(),
                kind = "TRIP",
                status = status,
                startedAtUtcMillis = startedAt.receivedAtUtcMillis,
                startedAtElapsedNanos = startedAt.receivedAtElapsedNanos,
                startedAtBootCount = bootCount,
                movementStartedAtUtcMillis = movementStartedAt?.receivedAtUtcMillis,
                movementStartedAtElapsedNanos = movementStartedAt?.receivedAtElapsedNanos,
                movementStartedAtBootCount = movementStartedAt?.let { bootCount },
                startSocPercent = startSoc,
                startOdometerKm = startOdometerKm,
                startGear = startGear,
                startLatitude = startLocation?.latitude,
                startLongitude = startLocation?.longitude,
                startAltitudeM = startLocation?.altitudeM,
                startGpsAccuracyM = startLocation?.accuracyM,
                startLocationProvider = startLocation?.provider,
                startLocationElapsedRealtimeNanos = startLocation?.elapsedRealtimeNanos,
                createdAtUtcMillis = now,
                updatedAtUtcMillis = now,
                accountId = accountIdProvider(),
                timeState = birthTimeState()
            )
        )
        return id
    }

    /**
     * Time authority T6: the stamp a session is born with. An existing row
     * keeps its own state; only a true birth consults the anchor.
     */
    private fun birthTimeState(existing: SessionEntity? = null): String =
        existing?.timeState
            ?: ClockUnlockBackfillEngine.sessionBirthState(ClockAnchorStore.isLearned())

    override fun closeTripSession(
        id: String?,
        startedAt: SignalTimestamp?,
        movementStartedAt: SignalTimestamp?,
        endedAt: SignalTimestamp,
        startSoc: Float?,
        endSoc: Float?,
        startOdometerKm: Float?,
        endOdometerKm: Float?,
        startGear: Int?,
        reason: TripEndReason
    ) {
        val sessionId = id ?: UUID.randomUUID().toString()
        val started = startedAt ?: endedAt
        val now = System.currentTimeMillis()
        val existing = findTripById(sessionId)
        val endBootCount = currentBootCount()
        val startBootCount = if (existing == null) endBootCount else existing.startedAtBootCount
        val movementBootCount = if (existing == null) {
            movementStartedAt?.let { endBootCount }
        } else {
            existing.movementStartedAtBootCount
        }
        // Guard the close stamp first: a jumped wall here would strand the end
        // months off the monotonic line and drag the reconciled start onto
        // itself. The session-open stamp is ground truth; the end must agree
        // with start + elapsed delta (gb-continuous-mode finding F-C).
        val guardedEndUtcMillis = SessionTimeReconciler.reconcileEndUtcMillis(
            startUtcMillis = started.receivedAtUtcMillis,
            startElapsedNanos = started.receivedAtElapsedNanos,
            startBootCount = startBootCount,
            endUtcMillis = endedAt.receivedAtUtcMillis,
            endElapsedNanos = endedAt.receivedAtElapsedNanos,
            endBootCount = endBootCount
        )
        val guardedEndedAt = if (guardedEndUtcMillis == endedAt.receivedAtUtcMillis) {
            endedAt
        } else {
            endedAt.copy(receivedAtUtcMillis = guardedEndUtcMillis)
        }
        val reconciledStartUtcMillis = SessionTimeReconciler.reconcileStartUtcMillis(
            startUtcMillis = started.receivedAtUtcMillis,
            startElapsedNanos = started.receivedAtElapsedNanos,
            startBootCount = startBootCount,
            endUtcMillis = guardedEndedAt.receivedAtUtcMillis,
            endElapsedNanos = guardedEndedAt.receivedAtElapsedNanos,
            endBootCount = endBootCount
        )
        val reconciledMovementUtcMillis = movementStartedAt?.let {
            SessionTimeReconciler.reconcileStartUtcMillis(
                startUtcMillis = it.receivedAtUtcMillis,
                startElapsedNanos = it.receivedAtElapsedNanos,
                startBootCount = movementBootCount,
                endUtcMillis = guardedEndedAt.receivedAtUtcMillis,
                endElapsedNanos = guardedEndedAt.receivedAtElapsedNanos,
                endBootCount = endBootCount
            )
        }
        finalizeTrip(
            SessionEntity(
                id = sessionId,
                vehicleId = existing?.vehicleId ?: vehicleIdProvider(),
                accountId = existing?.accountId ?: accountIdProvider(),
                timeState = birthTimeState(existing),
                kind = "TRIP",
                status = "ENDED",
                startedAtUtcMillis = reconciledStartUtcMillis,
                startedAtElapsedNanos = started.receivedAtElapsedNanos,
                startedAtBootCount = startBootCount,
                movementStartedAtUtcMillis = reconciledMovementUtcMillis,
                movementStartedAtElapsedNanos = movementStartedAt?.receivedAtElapsedNanos,
                movementStartedAtBootCount = movementBootCount,
                endedAtUtcMillis = guardedEndedAt.receivedAtUtcMillis,
                endedAtElapsedNanos = guardedEndedAt.receivedAtElapsedNanos,
                endedAtBootCount = endBootCount,
                startSocPercent = startSoc,
                endSocPercent = endSoc,
                startOdometerKm = startOdometerKm,
                endOdometerKm = endOdometerKm,
                startGear = startGear,
                endReason = reason.name,
                createdAtUtcMillis = existing?.createdAtUtcMillis ?: now,
                updatedAtUtcMillis = now
            )
        )
    }

    override fun markTripActive(id: String, movementStartedAt: SignalTimestamp) {
        val existing = findTripById(id) ?: return
        upsertTrip(
            existing.copy(
                status = "ACTIVE",
                movementStartedAtUtcMillis = movementStartedAt.receivedAtUtcMillis,
                movementStartedAtElapsedNanos = movementStartedAt.receivedAtElapsedNanos,
                movementStartedAtBootCount = currentBootCount(),
                updatedAtUtcMillis = System.currentTimeMillis()
            )
        )
    }

    override fun deleteTripSession(id: String) {
        writeExecutor.executeWrite(
            operation = "delete_trip",
            onFailure = { Log.w(TAG, "Failed to delete trip session id=$id", it) }
        ) {
            database.runInTransaction {
                database.tripSegmentDao().deleteBySessionId(id)
                intervalDao.deleteBySessionIds(listOf(id))
                sessionDao.deleteById(id)
            }
            changes.tripsChanged()
        }
    }

    override fun createChargeSession(
        plugConnectedAt: SignalTimestamp,
        startSoc: Float?,
        startOdometerKm: Float?,
        plugType: Int?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?
    ): String {
        latestReusableOpenChargeSession(plugConnectedAt, startSoc, startOdometerKm, plugType)?.let {
            return it.id
        }
        val id = UUID.randomUUID().toString()
        val now = System.currentTimeMillis()
        val bootCount = currentBootCount()
        val session = SessionEntity(
            id = id,
            vehicleId = vehicleIdProvider(),
            kind = "CHARGE",
            status = "PLUG_CONNECTED",
            startedAtUtcMillis = plugConnectedAt.receivedAtUtcMillis,
            startedAtElapsedNanos = plugConnectedAt.receivedAtElapsedNanos,
            startedAtBootCount = bootCount,
            startSocPercent = startSoc,
            startOdometerKm = startOdometerKm,
            plugType = plugType,
            costPerKwh = null,
            paidAmount = null,
            costCurrency = null,
            startAmbientTempC = startAmbientTempC,
            startLatitude = startLocation?.latitude,
            startLongitude = startLocation?.longitude,
            startAltitudeM = startLocation?.altitudeM,
            startGpsAccuracyM = startLocation?.accuracyM,
            startLocationProvider = startLocation?.provider,
            startLocationElapsedRealtimeNanos = startLocation?.elapsedRealtimeNanos,
            createdAtUtcMillis = now,
            updatedAtUtcMillis = now,
            accountId = accountIdProvider(),
            timeState = birthTimeState()
        )
        upsertCharge(session)
        // A charge is priced in its own row. The default rate lands when the
        // session is created, and never when a total is read.
        costRepository.stampDefaultAtCreate(
            sessionId = id,
            costPerKwh = defaultChargeCostPerKwhProvider(),
            currency = chargeCostCurrencyProvider()
        )
        return id
    }

    override fun updateChargeStarted(
        id: String?,
        plugConnectedAt: SignalTimestamp?,
        chargeStartedAt: SignalTimestamp,
        startSoc: Float?,
        startOdometerKm: Float?,
        plugType: Int?,
        startPowerKw: Float?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?
    ): String {
        val sessionId = id ?: UUID.randomUUID().toString()
        val connectedAt = plugConnectedAt ?: chargeStartedAt
        val now = System.currentTimeMillis()
        val existing = findChargeById(sessionId)
        val startBootCount = currentBootCount()
        val connectedBootCount = if (existing == null) {
            startBootCount
        } else {
            existing.startedAtBootCount
        }
        val startedBootCount = SessionTimeReconciler.boundBootCount(
            existing = existing?.chargeStartedAtBootCount,
            existingElapsedNanos = existing?.chargeStartedAtElapsedNanos,
            elapsedNanos = chargeStartedAt.receivedAtElapsedNanos,
            current = startBootCount
        )
        val connectedUtcMillis = SessionTimeReconciler.reconcileStartUtcMillis(
            startUtcMillis = connectedAt.receivedAtUtcMillis,
            startElapsedNanos = connectedAt.receivedAtElapsedNanos,
            startBootCount = connectedBootCount,
            endUtcMillis = chargeStartedAt.receivedAtUtcMillis,
            endElapsedNanos = chargeStartedAt.receivedAtElapsedNanos,
            endBootCount = startedBootCount
        )
        val effectiveLocation = startLocation ?: existing?.startLocationSnapshot()
        val effectiveStartAmbient = startAmbientTempC ?: existing?.startAmbientTempC
        val session = SessionEntity(
            id = sessionId,
            vehicleId = existing?.vehicleId ?: vehicleIdProvider(),
            kind = "CHARGE",
            status = "CHARGING",
            timeState = birthTimeState(existing),
            startedAtUtcMillis = connectedUtcMillis,
            startedAtElapsedNanos = connectedAt.receivedAtElapsedNanos,
            startedAtBootCount = connectedBootCount,
            chargeStartedAtUtcMillis = chargeStartedAt.receivedAtUtcMillis,
            chargeStartedAtElapsedNanos = chargeStartedAt.receivedAtElapsedNanos,
            chargeStartedAtBootCount = startedBootCount,
            startSocPercent = startSoc,
            startOdometerKm = startOdometerKm,
            plugType = plugType,
            startPowerKw = startPowerKw,
            costPerKwh = null,
            paidAmount = null,
            costCurrency = null,
            startAmbientTempC = effectiveStartAmbient,
            startLatitude = effectiveLocation?.latitude,
            startLongitude = effectiveLocation?.longitude,
            startAltitudeM = effectiveLocation?.altitudeM,
            startGpsAccuracyM = effectiveLocation?.accuracyM,
            createdAtUtcMillis = existing?.createdAtUtcMillis ?: now,
            startLocationProvider = effectiveLocation?.provider,
            startLocationElapsedRealtimeNanos = effectiveLocation?.elapsedRealtimeNanos,
            updatedAtUtcMillis = now,
            accountId = existing?.accountId ?: accountIdProvider(),
        )
        upsertCharge(session)
        return sessionId
    }

    override fun updateChargePlugType(id: String?, plugType: Int) {
        if (id == null) return
        sessionDao.updatePlugType(id, plugType, System.currentTimeMillis())
    }

    override fun closeChargeSession(
        id: String?,
        plugConnectedAt: SignalTimestamp?,
        chargeStartedAt: SignalTimestamp?,
        chargeEndedAt: SignalTimestamp?,
        plugDisconnectedAt: SignalTimestamp?,
        startSoc: Float?,
        endSoc: Float?,
        startOdometerKm: Float?,
        endOdometerKm: Float?,
        plugType: Int?,
        startPowerKw: Float?,
        startLocation: LocationSnapshot?,
        startAmbientTempC: Float?,
        endAmbientTempC: Float?,
        chargeEndReason: String?,
        disconnectReason: String?,
        status: String
    ) {
        val rawTerminalAt = plugDisconnectedAt ?: chargeEndedAt ?: chargeStartedAt ?: plugConnectedAt
            ?: SignalTimestamp(System.currentTimeMillis(), 0L, null, TimestampAccuracy.INFERRED, 0L)
        val connectedAt = plugConnectedAt ?: rawTerminalAt
        val now = System.currentTimeMillis()
        val sessionId = id ?: UUID.randomUUID().toString()
        val existing = findChargeById(sessionId)
        val terminalBootCount = currentBootCount()
        val connectedBootCount = if (existing == null) {
            terminalBootCount
        } else {
            existing.startedAtBootCount
        }
        // Guard the close stamp first, as in closeTripSession: a jumped wall
        // here would strand the end months off the monotonic line and drag
        // every reconcileAgainstTerminal result onto itself.
        val terminalAt = rawTerminalAt.copy(
            receivedAtUtcMillis = SessionTimeReconciler.reconcileEndUtcMillis(
                startUtcMillis = connectedAt.receivedAtUtcMillis,
                startElapsedNanos = connectedAt.receivedAtElapsedNanos,
                startBootCount = connectedBootCount,
                endUtcMillis = rawTerminalAt.receivedAtUtcMillis,
                endElapsedNanos = rawTerminalAt.receivedAtElapsedNanos,
                endBootCount = terminalBootCount
            )
        )
        val startedBootCount = if (existing == null) {
            chargeStartedAt?.let { terminalBootCount }
        } else {
            existing.chargeStartedAtBootCount
        }
        val endedBootCount = when {
            chargeEndedAt == null -> null
            existing == null || existing.chargeEndedAtElapsedNanos !=
                chargeEndedAt.receivedAtElapsedNanos -> terminalBootCount
            else -> existing.chargeEndedAtBootCount
        }
        fun reconcileAgainstTerminal(timestamp: SignalTimestamp?, bootCount: Int?): Long? =
            timestamp?.let {
                SessionTimeReconciler.reconcileStartUtcMillis(
                    startUtcMillis = it.receivedAtUtcMillis,
                    startElapsedNanos = it.receivedAtElapsedNanos,
                    startBootCount = bootCount,
                    endUtcMillis = terminalAt.receivedAtUtcMillis,
                    endElapsedNanos = terminalAt.receivedAtElapsedNanos,
                    endBootCount = terminalBootCount
                )
            }
        val effectiveLocation = startLocation ?: existing?.startLocationSnapshot()
        val effectiveStartAmbient = startAmbientTempC ?: existing?.startAmbientTempC
        val session = SessionEntity(
            id = sessionId,
            vehicleId = existing?.vehicleId ?: vehicleIdProvider(),
            kind = "CHARGE",
            status = status,
            timeState = birthTimeState(existing),
            startedAtUtcMillis = reconcileAgainstTerminal(
                connectedAt,
                connectedBootCount
            ) ?: connectedAt.receivedAtUtcMillis,
            startedAtElapsedNanos = connectedAt.receivedAtElapsedNanos,
            startedAtBootCount = connectedBootCount,
            chargeStartedAtUtcMillis = reconcileAgainstTerminal(chargeStartedAt, startedBootCount),
            chargeStartedAtElapsedNanos = chargeStartedAt?.receivedAtElapsedNanos,
            chargeStartedAtBootCount = startedBootCount,
            chargeEndedAtUtcMillis = reconcileAgainstTerminal(chargeEndedAt, endedBootCount),
            chargeEndedAtElapsedNanos = chargeEndedAt?.receivedAtElapsedNanos,
            chargeEndedAtBootCount = endedBootCount,
            plugDisconnectedAtUtcMillis = plugDisconnectedAt?.let { terminalAt.receivedAtUtcMillis },
            plugDisconnectedAtElapsedNanos = plugDisconnectedAt?.receivedAtElapsedNanos,
            plugDisconnectedAtBootCount = plugDisconnectedAt?.let { terminalBootCount },
            endedAtUtcMillis = (plugDisconnectedAt ?: chargeEndedAt)?.let { terminalAt.receivedAtUtcMillis },
            endedAtElapsedNanos = plugDisconnectedAt?.receivedAtElapsedNanos ?: chargeEndedAt?.receivedAtElapsedNanos,
            endedAtBootCount = plugDisconnectedAt?.let { terminalBootCount } ?: endedBootCount,
            startSocPercent = startSoc,
            endSocPercent = endSoc,
            startOdometerKm = startOdometerKm,
            endOdometerKm = endOdometerKm,
            plugType = plugType,
            startPowerKw = startPowerKw,
            costPerKwh = null,
            paidAmount = null,
            costCurrency = null,
            startAmbientTempC = effectiveStartAmbient,
            endAmbientTempC = endAmbientTempC,
            startLatitude = effectiveLocation?.latitude,
            startLongitude = effectiveLocation?.longitude,
            startAltitudeM = effectiveLocation?.altitudeM,
            startGpsAccuracyM = effectiveLocation?.accuracyM,
            startLocationProvider = effectiveLocation?.provider,
            startLocationElapsedRealtimeNanos = effectiveLocation?.elapsedRealtimeNanos,
            chargeEndReason = chargeEndReason ?: existing?.chargeEndReason,
            endReason = disconnectReason ?: existing?.endReason,
            createdAtUtcMillis = existing?.createdAtUtcMillis ?: now,
            updatedAtUtcMillis = now,
            accountId = existing?.accountId ?: accountIdProvider(),
        )
        if (plugDisconnectedAt == null) {
            upsertCharge(session)
        } else {
            finalizeCharge(session)
        }
    }

    fun setFrameWriteBarrier(barrier: () -> Unit) {
        frameWriteBarrier = barrier
    }

    fun recoverPendingFinalizations(): Map<String, Any?> {
        frameWriteBarrier()
        return writeExecutor.call("recover_finalizations", trackAsWrite = true) {
            var tripsRecovered = 0
            var chargesRecovered = 0
            var continuousRecovered = 0
            val failures = mutableListOf<String>()
            val pending = sessionDao.pendingFinalization()
            pendingFinalizations.set(pending.size.toLong())
            pending.forEach { s ->
                runCatching { sessionFinalizer.finalize(s) }
                    .onSuccess {
                        when (s.kind) {
                            "TRIP" -> tripsRecovered += 1
                            "CONTINUOUS" -> continuousRecovered += 1
                            else -> chargesRecovered += 1
                        }
                        recordFinalizationSuccess(s.endedAtElapsedNanos ?: s.plugDisconnectedAtElapsedNanos)
                    }
                    .onFailure { error ->
                        recordFinalizationFailure(error)
                        failures.add("${s.kind.lowercase()}:${s.id}:${error.message}")
                        Log.w(TAG, "Failed to recover pending session id=${s.id}", error)
                    }
            }
            mapOf(
                "tripsRecovered" to tripsRecovered,
                "chargesRecovered" to chargesRecovered,
                "continuousRecovered" to continuousRecovered,
                "failures" to failures
            )
        }
    }

    override fun latestOpenChargeSession(): SessionEntity? {
        return try {
            writeExecutor.call("read_open_charge") { sessionDao.latestOpen("CHARGE") }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read open charge session", e)
            null
        }
    }

    override fun latestOpenTripSession(): SessionEntity? {
        return try {
            writeExecutor.call("read_open_trip") { sessionDao.latestOpen("TRIP") }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read open trip session", e)
            null
        }
    }

    override fun latestOpenParkedSession(): SessionEntity? {
        return try {
            writeExecutor.call("read_open_parked") { sessionDao.latestOpen("PARKED") }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read open parked session", e)
            null
        }
    }

    override fun latestOpenContinuousSession(): SessionEntity? {
        return try {
            writeExecutor.call("read_open_continuous") { sessionDao.latestOpen("CONTINUOUS") }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read open continuous session", e)
            null
        }
    }

    override fun createContinuousSession(startedAt: SignalTimestamp): String {
        val id = UUID.randomUUID().toString()
        val entity = SessionEntity(
            id = id,
            vehicleId = vehicleIdProvider(),
            kind = "CONTINUOUS",
            status = "ACTIVE",
            startedAtUtcMillis = startedAt.receivedAtUtcMillis,
            startedAtElapsedNanos = startedAt.receivedAtElapsedNanos,
            startedAtBootCount = currentBootCount(),
            createdAtUtcMillis = startedAt.receivedAtUtcMillis,
            updatedAtUtcMillis = startedAt.receivedAtUtcMillis,
            updatedAtElapsedNanos = startedAt.receivedAtElapsedNanos,
            accountId = accountIdProvider(),
            timeState = birthTimeState()
        )
        writeExecutor.executeWrite("create_continuous_session") {
            sessionDao.upsert(entity)
        }
        return id
    }

    override fun closeContinuousSession(id: String, endedAt: SignalTimestamp, reason: String) {
        val existing = findContinuousById(id) ?: return
        // Same guard as closeTripSession: the close stamp must agree with
        // the session-open anchor (gb-continuous-mode finding F-C).
        val guardedEndUtcMillis = SessionTimeReconciler.reconcileEndUtcMillis(
            startUtcMillis = existing.startedAtUtcMillis,
            startElapsedNanos = existing.startedAtElapsedNanos,
            startBootCount = existing.startedAtBootCount,
            endUtcMillis = endedAt.receivedAtUtcMillis,
            endElapsedNanos = endedAt.receivedAtElapsedNanos,
            endBootCount = currentBootCount()
        )
        finalizeContinuous(
            existing.copy(
                status = "ENDED",
                endedAtUtcMillis = guardedEndUtcMillis,
                endedAtElapsedNanos = endedAt.receivedAtElapsedNanos,
                endedAtBootCount = currentBootCount(),
                endReason = reason,
                updatedAtUtcMillis = guardedEndUtcMillis,
                updatedAtElapsedNanos = endedAt.receivedAtElapsedNanos
            )
        )
    }

    override fun createParkedSession(
        startedAt: SignalTimestamp,
        startSoc: Float?,
        startAmbientTempC: Float?,
        parkingMode: Int?,
        status: String
    ): String {
        val id = UUID.randomUUID().toString()
        val entity = SessionEntity(
            id = id,
            vehicleId = vehicleIdProvider(),
            kind = "PARKED",
            startedAtUtcMillis = startedAt.receivedAtUtcMillis,
            startedAtElapsedNanos = startedAt.receivedAtElapsedNanos,
            startedAtBootCount = currentBootCount(),
            startSocPercent = startSoc,
            lastSoc = startSoc,
            startAmbientTempC = startAmbientTempC,
            parkingMode = parkingMode,
            status = status,
            createdAtUtcMillis = startedAt.receivedAtUtcMillis,
            updatedAtUtcMillis = startedAt.receivedAtUtcMillis,
            updatedAtElapsedNanos = startedAt.receivedAtElapsedNanos,
            accountId = accountIdProvider(),
            timeState = birthTimeState()
        )
        writeExecutor.executeWrite("create_parked_session") {
            sessionDao.upsert(entity)
            changes.parkedChanged()
        }
        return id
    }

    override fun updateParkedSessionLastSoc(
        id: String,
        lastSoc: Float?,
        updatedAt: SignalTimestamp
    ) {
        writeExecutor.executeWrite("update_parked_session_last_soc") {
            val existing = sessionDao.findById(id) ?: return@executeWrite
            val updated = existing.copy(
                lastSoc = lastSoc ?: existing.lastSoc,
                updatedAtUtcMillis = updatedAt.receivedAtUtcMillis,
                updatedAtElapsedNanos = updatedAt.receivedAtElapsedNanos
            )
            sessionDao.upsert(updated)
            changes.parkedChanged()
        }
    }

    override fun updateParkedSessionParkingMode(
        id: String,
        parkingMode: Int,
        updatedAt: SignalTimestamp
    ) {
        writeExecutor.executeWrite("update_parked_session_parking_mode") {
            val existing = sessionDao.findById(id) ?: return@executeWrite
            val updated = existing.copy(
                parkingMode = parkingMode,
                updatedAtUtcMillis = updatedAt.receivedAtUtcMillis,
                updatedAtElapsedNanos = updatedAt.receivedAtElapsedNanos
            )
            sessionDao.upsert(updated)
            changes.parkedChanged()
        }
    }

    override fun closeParkedSession(
        id: String?,
        endedAt: SignalTimestamp,
        endSoc: Float?,
        endAmbientTempC: Float?,
        parkingMode: Int?,
        reason: String,
        sleepSeconds: Long?,
        sleepSocDeltaPercent: Float?,
        sleepEnergyWhEstimate: Double?
    ) {
        writeExecutor.executeWrite("close_parked_session") {
            val targetId = id ?: sessionDao.latestOpen("PARKED")?.id ?: return@executeWrite
            val existing = sessionDao.findById(targetId)
            val entity = if (existing != null) {
                // Same guard as closeTripSession: the close stamp must agree
                // with the session-open anchor (gb-continuous-mode finding F-C).
                val guardedEndUtcMillis = SessionTimeReconciler.reconcileEndUtcMillis(
                    startUtcMillis = existing.startedAtUtcMillis,
                    startElapsedNanos = existing.startedAtElapsedNanos,
                    startBootCount = existing.startedAtBootCount,
                    endUtcMillis = endedAt.receivedAtUtcMillis,
                    endElapsedNanos = endedAt.receivedAtElapsedNanos,
                    endBootCount = currentBootCount()
                )
                existing.copy(
                    endedAtUtcMillis = guardedEndUtcMillis,
                    endedAtElapsedNanos = endedAt.receivedAtElapsedNanos,
                    endedAtBootCount = currentBootCount(),
                    endSocPercent = endSoc ?: existing.lastSoc ?: existing.startSocPercent,
                    lastSoc = endSoc ?: existing.lastSoc ?: existing.startSocPercent,
                    endAmbientTempC = endAmbientTempC ?: existing.startAmbientTempC,
                    parkingMode = parkingMode ?: existing.parkingMode,
                    status = "ENDED",
                    endReason = reason,
                    sleepSeconds = sleepSeconds ?: existing.sleepSeconds,
                    sleepSocDeltaPercent = sleepSocDeltaPercent ?: existing.sleepSocDeltaPercent,
                    sleepEnergyWhEstimate = sleepEnergyWhEstimate ?: existing.sleepEnergyWhEstimate,
                    updatedAtUtcMillis = guardedEndUtcMillis,
                    updatedAtElapsedNanos = endedAt.receivedAtElapsedNanos
                )
            } else {
                SessionEntity(
                    id = targetId,
                    vehicleId = vehicleIdProvider(),
                    kind = "PARKED",
                    startedAtUtcMillis = endedAt.receivedAtUtcMillis,
                    startedAtElapsedNanos = endedAt.receivedAtElapsedNanos,
                    startedAtBootCount = currentBootCount(),
                    endedAtUtcMillis = endedAt.receivedAtUtcMillis,
                    endedAtElapsedNanos = endedAt.receivedAtElapsedNanos,
                    endedAtBootCount = currentBootCount(),
                    startSocPercent = endSoc,
                    endSocPercent = endSoc,
                    lastSoc = endSoc,
                    startAmbientTempC = endAmbientTempC,
                    endAmbientTempC = endAmbientTempC,
                    parkingMode = parkingMode,
                    sleepSeconds = sleepSeconds,
                    sleepSocDeltaPercent = sleepSocDeltaPercent,
                    sleepEnergyWhEstimate = sleepEnergyWhEstimate,
                    status = "ENDED",
                    endReason = reason,
                    createdAtUtcMillis = endedAt.receivedAtUtcMillis,
                    updatedAtUtcMillis = endedAt.receivedAtUtcMillis,
                    updatedAtElapsedNanos = endedAt.receivedAtElapsedNanos,
                    accountId = accountIdProvider(),
                    timeState = birthTimeState()
                )
            }
            sessionDao.upsert(entity)
            changes.parkedChanged()
        }
    }

    override fun updateParkedSessionSleepEstimate(
        id: String,
        sleepSeconds: Long,
        sleepSocDeltaPercent: Float,
        sleepEnergyWhEstimate: Double
    ) {
        writeExecutor.executeWrite("update_parked_session_sleep_estimate") {
            val existing = sessionDao.findById(id) ?: return@executeWrite
            val updated = existing.copy(
                sleepSeconds = sleepSeconds,
                sleepSocDeltaPercent = sleepSocDeltaPercent,
                sleepEnergyWhEstimate = sleepEnergyWhEstimate,
                updatedAtUtcMillis = System.currentTimeMillis(),
                updatedAtElapsedNanos = SystemClock.elapsedRealtimeNanos()
            )
            sessionDao.upsert(updated)
            changes.parkedChanged()
        }
    }

    override fun deleteParkedSession(id: String) {
        writeExecutor.executeWrite("delete_parked_session") {
            sessionDao.deleteById(id)
            changes.sessionsChanged()
        }
    }

    fun statusMap(): Map<String, Any?> = mapOf(
        "tripWritesThisRun" to tripWrites.get(),
        "chargeWritesThisRun" to chargeWrites.get(),
        "pendingFinalizations" to pendingFinalizations.get(),
        "finalizationFailuresThisRun" to finalizationFailures.get(),
        "lastFinalizedUtcMillis" to lastFinalizedUtcMillis.get().takeIf { it > 0 },
        "lastFinalizedThroughElapsedNanos" to
            lastFinalizedThroughElapsedNanos.get().takeIf { it > 0 },
        "lastFinalizationError" to lastFinalizationError.get()
    )

    fun resetInMemory() {
        tripWrites.set(0L)
        chargeWrites.set(0L)
        pendingFinalizations.set(0L)
        finalizationFailures.set(0L)
        lastFinalizedUtcMillis.set(0L)
        lastFinalizedThroughElapsedNanos.set(0L)
        lastFinalizationError.set(null)
    }

    fun recentChargeSessions(limit: Int): ChargeSessionPage {
        val safeLimit = limit.coerceIn(1, 100)
        val page = try {
            readExecutor.submit(
                Callable {
                    val sessions = sessionDao.latest("CHARGE", safeLimit)
                    val costs = costRepository.costsFor(sessions.map { it.id })
                    val rows = sessions.map { it.toChargeRowWithLatestFrame(cost = costs[it.id]) }
                    rows to sessionDao.countListed("CHARGE")
                }
            ).get()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read charge sessions", e)
            emptyList<ChargeSessionRow>() to 0L
        }
        return ChargeSessionPage(
            sessions = page.first,
            totalCount = page.second,
            limit = safeLimit,
            chargeWritesThisRun = chargeWrites.get(),
        )
    }

    fun chargeMergeCandidates(limit: Int): ChargeMergeCandidatePage {
        val safeLimit = limit.coerceIn(1, 20)
        val candidates = try {
            readExecutor.submit(Callable { buildChargeMergeCandidates().take(safeLimit) }).get()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to detect charge merge candidates", e)
            emptyList()
        }
        return ChargeMergeCandidatePage(
            candidates = candidates.map { candidate ->
                val ids = candidate.sessions.map { it.id }
                candidate.toRow(costs = costRepository.costsFor(ids))
            },
            totalCount = candidates.size,
            limit = safeLimit,
        )
    }

    fun mergeChargeSessions(ids: List<String>): ChargeMergeOutcome {
        val normalizedIds = ids.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (normalizedIds.size < 2) return mergeFailure("at_least_two_sessions_required")
        return try {
            writeExecutor.call("merge_charge_sessions", trackAsWrite = true) block@{
                val candidates = buildChargeMergeCandidates()
                val candidate = candidates.firstOrNull { it.sessions.map { session -> session.id } == normalizedIds }
                    ?: return@block mergeFailure("candidate_no_longer_valid")

                var framesReassigned = 0
                var deletedSessions = 0
                database.runInTransaction {
                    val ordered = sessionDao.byIds(normalizedIds)
                        .associateBy { it.id }
                    val sessions = normalizedIds.mapNotNull { ordered[it] }
                    if (sessions.size != normalizedIds.size) {
                        throw IllegalStateException("Missing sessions during merge")
                    }
                    val primary = sessions.first()
                    val tail = sessions.drop(1)
                    val last = sessions.last()
                    framesReassigned = 0
                    val merged = mergedChargeSession(primary, last)
                    sessionDao.upsert(merged)
                    deletedSessions = sessionDao.deleteByIds(tail.map { it.id })
                    intervalDao.deleteBySessionIds(normalizedIds)
                    sessionFinalizer.finalize(merged)
                }
                changes.sessionsChanged()
                ChargeMergeOutcome(
                    ok = true,
                    error = null,
                    mergedSessionId = candidate.sessions.first().id,
                    mergedCount = candidate.sessions.size,
                    framesReassigned = framesReassigned,
                    deletedSessions = deletedSessions,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to merge charge sessions ids=$normalizedIds", e)
            mergeFailure(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun mergeFailure(error: String) = ChargeMergeOutcome(
        ok = false,
        error = error,
        mergedSessionId = null,
        mergedCount = 0,
        framesReassigned = 0,
        deletedSessions = 0,
    )

    fun updateChargeSessionCost(
        sessionId: String,
        costPerKwh: Double?,
        paidAmount: Double?,
        currency: String?
    ): ChargeCostUpdate {
        val normalizedCurrency = currency?.trim()?.takeIf { it.isNotEmpty() }
            ?: chargeCostCurrencyProvider()
        val session = findChargeById(sessionId)
        if (session == null) {
            return ChargeCostUpdate(
                ok = false,
                updatedRows = 0,
                session = null,
            )
        }
        // A price is an annotation, not a measurement: the write lands on the
        // annotation side, and the session row's own cost columns stay dead.
        val stored = try {
            costRepository.priceFromCar(
                sessionId = sessionId,
                costPerKwh = costPerKwh,
                paidAmount = paidAmount,
                currency = normalizedCurrency
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update charge session cost id=$sessionId", e)
            return ChargeCostUpdate(
                ok = false,
                updatedRows = 0,
                session = null,
            )
        }
        return ChargeCostUpdate(
            ok = true,
            updatedRows = 1,
            session = session.toChargeRowWithLatestFrame(cost = stored),
        )
    }

    fun applyDefaultCostToUnpricedCharges(): DefaultChargeCostApplication {
        val rate = defaultChargeCostPerKwhProvider()?.takeIf { it.isFinite() && it > 0.0 }
        val currency = chargeCostCurrencyProvider()
        if (rate == null) {
            return DefaultChargeCostApplication(
                ok = false,
                updatedRows = 0,
                costPerKwh = null,
                currency = currency,
                error = "NO_DEFAULT_RATE"
            )
        }
        return try {
            // The oldest priced session is read before the write: afterwards no
            // unpriced row points at it, and the cycle ledger is rebuilt from it.
            val oldestStart = readExecutor.submit(
                Callable { costRepository.oldestUnpricedClosedStart() }
            ).get()
            val (updated, pricedOldest) = costRepository.applyDefaultToUnpriced(
                rate = rate,
                currency = currency
            )
            DefaultChargeCostApplication(
                ok = true,
                updatedRows = updated,
                costPerKwh = rate,
                currency = currency,
                error = null,
                oldestPricedStartUtcMillis = if (updated > 0) (pricedOldest ?: oldestStart) else null
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to apply the default charge cost", e)
            DefaultChargeCostApplication(
                ok = false,
                updatedRows = 0,
                costPerKwh = rate,
                currency = currency,
                error = e.message ?: e.javaClass.simpleName
            )
        }
    }

    fun recentTripSessions(limit: Int): TripSessionPage {
        val safeLimit = limit.coerceIn(1, 100)
        val page = try {
            readExecutor.submit(
                Callable {
                    val rows = sessionDao.latest("TRIP", safeLimit).map { it.toTripRowWithLatestFrame() }
                    rows to sessionDao.countListed("TRIP")
                }
            ).get()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read trip sessions", e)
            emptyList<TripSessionRow>() to 0L
        }
        return TripSessionPage(
            sessions = page.first,
            totalCount = page.second,
            limit = safeLimit,
            tripWritesThisRun = tripWrites.get(),
        )
    }

    private fun upsertTrip(session: SessionEntity) {
        writeExecutor.executeWrite(
            operation = "upsert_trip",
            onFailure = { Log.w(TAG, "Failed to persist trip session", it) }
        ) {
            sessionDao.upsert(session)
            tripWrites.incrementAndGet()
            changes.tripsChanged()
        }
    }

    private fun finalizeTrip(session: SessionEntity) {
        val pending = session.copy(status = SessionFinalizer.FINALIZATION_PENDING)
        persistPendingSession(pending)
        frameWriteBarrier()
        writeExecutor.executeWrite(
            operation = "finalize_trip",
            acceptedElapsedNanos = session.endedAtElapsedNanos,
            onFailure = {
                recordFinalizationFailure(it)
                Log.w(TAG, "Failed to finalize trip session id=${session.id}", it)
            }
        ) {
            sessionFinalizer.finalizeTrip(pending, terminalStatus = session.status)
            tripWrites.incrementAndGet()
            recordFinalizationSuccess(session.endedAtElapsedNanos)
            changes.tripsChanged()
        }
    }

    private fun SessionEntity.toTripRowWithLatestFrame(): TripSessionRow {
        val durationMillis = tripDurationMillis()
        return TripSessionRow(
            session = this,
            durationMillis = durationMillis,
            endSoc = endSocPercent,
            endOdometerKm = endOdometerKm,
            updatedAtUtcMillis = updatedAtUtcMillis,
        )
    }

    private fun SessionEntity.toChargeRowWithLatestFrame(cost: SessionCostEntity? = null): ChargeSessionRow {
        // The price is an annotation; the row carries it composed from the
        // annotation table, never from the session's dead cost columns.
        val priced = cost?.let {
            copy(
                costPerKwh = it.costPerKwh,
                paidAmount = it.paidAmount,
                costCurrency = it.costCurrency
            )
        } ?: this
        val energyKwh = chargeEnergyKwh(priced)
        val durationMillis = priced.chargeDurationMillis()
        return ChargeSessionRow(
            session = priced,
            durationMillis = durationMillis,
            endSoc = priced.endSocPercent,
            endOdometerKm = priced.endOdometerKm,
            endAmbientTempC = priced.endAmbientTempC,
            estimatedEnergyKwh = energyKwh,
            updatedAtUtcMillis = priced.updatedAtUtcMillis,
        )
    }

    private fun SessionEntity.tripDurationMillis(): Long? {
        val endUtcMillis = endedAtUtcMillis ?: System.currentTimeMillis()
        val endElapsedNanos = endedAtElapsedNanos ?: SystemClock.elapsedRealtimeNanos()
        val endBootCount = endedAtBootCount ?: currentBootCount()
        return SessionTimeReconciler.canonicalDurationMillis(
            startUtcMillis = startedAtUtcMillis,
            startElapsedNanos = startedAtElapsedNanos,
            startBootCount = startedAtBootCount,
            endUtcMillis = endUtcMillis,
            endElapsedNanos = endElapsedNanos,
            endBootCount = endBootCount,
            maxWallDurationMillis = MAX_TRIP_WALL_DURATION_MILLIS
        )
    }

    private fun SessionEntity.chargeDurationMillis(): Long? {
        val startUtcMillis = chargeStartedAtUtcMillis ?: startedAtUtcMillis
        val startElapsedNanos = chargeStartedAtElapsedNanos ?: startedAtElapsedNanos
        val startBootCount = chargeStartedAtBootCount ?: startedAtBootCount
        val endUtcMillis = plugDisconnectedAtUtcMillis
            ?: chargeEndedAtUtcMillis
            ?: endedAtUtcMillis
            ?: System.currentTimeMillis()
        val endElapsedNanos = plugDisconnectedAtElapsedNanos
            ?: chargeEndedAtElapsedNanos
            ?: endedAtElapsedNanos
            ?: SystemClock.elapsedRealtimeNanos()
        val endBootCount = plugDisconnectedAtBootCount
            ?: chargeEndedAtBootCount
            ?: endedAtBootCount
            ?: currentBootCount()
        return SessionTimeReconciler.canonicalDurationMillis(
            startUtcMillis = startUtcMillis,
            startElapsedNanos = startElapsedNanos,
            startBootCount = startBootCount,
            endUtcMillis = endUtcMillis,
            endElapsedNanos = endElapsedNanos,
            endBootCount = endBootCount,
            maxWallDurationMillis = MAX_CHARGE_WALL_DURATION_MILLIS
        )
    }

    private fun chargeEnergyKwh(session: SessionEntity): Double? {
        if (session.rollupDeliveredWh != null) {
            return session.rollupDeliveredWh / 1_000.0
        }
        return null
    }

    private fun buildChargeMergeCandidates(): List<ChargeMergeCandidate> {
        val sessions = sessionDao.since(
            System.currentTimeMillis() - MERGE_CANDIDATE_WINDOW_MILLIS
        )
        val groups = mutableListOf<ChargeMergeCandidate>()
        var current = mutableListOf<SessionEntity>()
        var reasons = mutableListOf<ChargeMergeBreak>()

        fun flush() {
            if (current.size >= 2) {
                groups.add(
                    ChargeMergeCandidate(
                        sessions = current.toList(),
                        breaks = reasons.toList(),
                        totalFrames = 0L
                    )
                )
            }
            current = mutableListOf()
            reasons = mutableListOf()
        }

        for (index in 0 until sessions.lastIndex) {
            val left = sessions[index]
            val right = sessions[index + 1]
            val continuity = mergeContinuity(left, right)
            if (continuity == null) {
                flush()
                continue
            }
            if (current.isEmpty()) current.add(left)
            current.add(right)
            reasons.add(continuity)
        }
        flush()
        return groups.sortedByDescending { it.startUtcMillis }
    }

    private fun mergeContinuity(
        left: SessionEntity,
        right: SessionEntity
    ): ChargeMergeBreak? {
        if (left.endReason != "removed_while_charging") return null
        val leftEnd = left.plugDisconnectedAtUtcMillis
            ?: left.chargeEndedAtUtcMillis
            ?: left.endedAtUtcMillis
            ?: left.updatedAtUtcMillis
        val gapMillis = right.startedAtUtcMillis - leftEnd
        if (gapMillis < -MAX_CHARGE_MERGE_OVERLAP_MILLIS ||
            gapMillis > MAX_CHARGE_MERGE_GAP_MILLIS
        ) {
            return null
        }
        if (!sameNullableInt(left.plugType, right.plugType)) return null
        if (!closeNullableFloat(left.endSocPercent, right.startSocPercent, SOC_MERGE_TOLERANCE)) return null
        if (!closeNullableFloat(left.endOdometerKm, right.startOdometerKm, ODOMETER_MERGE_TOLERANCE_KM)) {
            return null
        }
        return ChargeMergeBreak(
            previousSessionId = left.id,
            nextSessionId = right.id,
            gapMillis = gapMillis.coerceAtLeast(0L),
            socDelta = nullableDelta(left.endSocPercent, right.startSocPercent),
            odometerDeltaKm = nullableDelta(left.endOdometerKm, right.startOdometerKm)
        )
    }

    private fun mergedChargeSession(
        primary: SessionEntity,
        last: SessionEntity
    ): SessionEntity {
        val now = System.currentTimeMillis()
        return primary.copy(
            status = last.status,
            chargeEndedAtUtcMillis = last.chargeEndedAtUtcMillis,
            chargeEndedAtElapsedNanos = last.chargeEndedAtElapsedNanos,
            chargeEndedAtBootCount = last.chargeEndedAtBootCount,
            plugDisconnectedAtUtcMillis = last.plugDisconnectedAtUtcMillis,
            plugDisconnectedAtElapsedNanos = last.plugDisconnectedAtElapsedNanos,
            plugDisconnectedAtBootCount = last.plugDisconnectedAtBootCount,
            endedAtUtcMillis = last.endedAtUtcMillis ?: last.plugDisconnectedAtUtcMillis ?: last.chargeEndedAtUtcMillis,
            endedAtElapsedNanos = last.endedAtElapsedNanos ?: last.plugDisconnectedAtElapsedNanos ?: last.chargeEndedAtElapsedNanos,
            endedAtBootCount = last.endedAtBootCount ?: last.plugDisconnectedAtBootCount ?: last.chargeEndedAtBootCount,
            endSocPercent = last.endSocPercent ?: primary.endSocPercent,
            endOdometerKm = last.endOdometerKm ?: primary.endOdometerKm,
            endAmbientTempC = last.endAmbientTempC ?: primary.endAmbientTempC,
            endReason = last.endReason,
            updatedAtUtcMillis = now
        )
    }

    private fun nullableDelta(left: Float?, right: Float?): Float? {
        if (left == null || right == null) return null
        return right - left
    }

    private fun SessionEntity.startLocationSnapshot(): LocationSnapshot? {
        val latitude = startLatitude ?: return null
        val longitude = startLongitude ?: return null
        return LocationSnapshot(
            latitude = latitude,
            longitude = longitude,
            altitudeM = startAltitudeM,
            accuracyM = startGpsAccuracyM,
            provider = startLocationProvider,
            elapsedRealtimeNanos = startLocationElapsedRealtimeNanos ?: 0L,
            wallTimeUtcMillis = startedAtUtcMillis
        )
    }

    private fun upsertCharge(session: SessionEntity) {
        writeExecutor.executeWrite(
            operation = "upsert_charge",
            onFailure = { Log.w(TAG, "Failed to persist charge session", it) }
        ) {
            sessionDao.upsert(session)
            chargeWrites.incrementAndGet()
            changes.chargesChanged()
        }
    }

    private val bootCount: Int? by lazy {
        bootCountProvider?.invoke() ?: SessionTimeline.currentBootCount(appContext)
    }

    private fun currentBootCount(): Int? = bootCount

    private fun finalizeCharge(session: SessionEntity) {
        val pending = session.copy(status = SessionFinalizer.FINALIZATION_PENDING)
        persistPendingSession(pending)
        frameWriteBarrier()
        writeExecutor.executeWrite(
            operation = "finalize_charge",
            acceptedElapsedNanos = session.endedAtElapsedNanos ?: session.plugDisconnectedAtElapsedNanos,
            onFailure = {
                recordFinalizationFailure(it)
                Log.w(TAG, "Failed to finalize charge session id=${session.id}", it)
            }
        ) {
            sessionFinalizer.finalizeCharge(pending, terminalStatus = session.status)
            chargeWrites.incrementAndGet()
            recordFinalizationSuccess(session.endedAtElapsedNanos ?: session.plugDisconnectedAtElapsedNanos)
            changes.chargesChanged()
        }
    }

    private fun finalizeContinuous(session: SessionEntity) {
        val pending = session.copy(status = SessionFinalizer.FINALIZATION_PENDING)
        persistPendingSession(pending)
        frameWriteBarrier()
        writeExecutor.executeWrite(
            operation = "finalize_continuous",
            acceptedElapsedNanos = session.endedAtElapsedNanos,
            onFailure = {
                recordFinalizationFailure(it)
                Log.w(TAG, "Failed to finalize continuous session id=${session.id}", it)
            }
        ) {
            sessionFinalizer.finalize(pending, terminalStatus = session.status)
            recordFinalizationSuccess(session.endedAtElapsedNanos)
        }
    }

    private fun findContinuousById(id: String): SessionEntity? {
        return try {
            writeExecutor.call("read_continuous") { sessionDao.findById(id) }?.takeIf { it.kind == "CONTINUOUS" }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read continuous session id=$id", e)
            null
        }
    }

    private fun persistPendingSession(session: SessionEntity) {
        try {
            writeExecutor.call(
                operation = "persist_pending_session",
                trackAsWrite = true,
                acceptedElapsedNanos = session.endedAtElapsedNanos ?: session.plugDisconnectedAtElapsedNanos
            ) { sessionDao.upsert(session) }
            pendingFinalizations.incrementAndGet()
        } catch (e: Exception) {
            throw IllegalStateException("Unable to persist pending session finalization id=${session.id}", e)
        }
    }

    private fun recordFinalizationSuccess(finalizedThroughElapsedNanos: Long?) {
        pendingFinalizations.updateAndGet { (it - 1L).coerceAtLeast(0L) }
        lastFinalizedUtcMillis.set(System.currentTimeMillis())
        finalizedThroughElapsedNanos?.let(lastFinalizedThroughElapsedNanos::set)
        lastFinalizationError.set(null)
    }

    private fun recordFinalizationFailure(error: Throwable) {
        finalizationFailures.incrementAndGet()
        lastFinalizationError.set("${error.javaClass.simpleName}: ${error.message}".take(500))
    }

    fun tripSession(id: String): TripSessionRow? =
        findTripById(id)?.toTripRowWithLatestFrame()

    fun chargeSession(id: String): ChargeSessionRow? =
        findChargeById(id)?.let { it.toChargeRowWithLatestFrame(cost = costRepository.bySession(it.id)) }

    fun parkedSessionExists(id: String): Boolean {
        return try {
            writeExecutor.call("read_parked") { sessionDao.findById(id) }?.kind == "PARKED"
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read parked session id=$id", e)
            false
        }
    }

    private fun findChargeById(id: String): SessionEntity? {
        return try {
            writeExecutor.call("read_charge") { sessionDao.findById(id) }?.takeIf { it.kind == "CHARGE" }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read charge session id=$id", e)
            null
        }
    }

    private fun findTripById(id: String): SessionEntity? {
        return try {
            writeExecutor.call("read_trip") { sessionDao.findById(id) }?.takeIf { it.kind == "TRIP" }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read trip session id=$id", e)
            null
        }
    }

    private fun latestReusableOpenChargeSession(
        plugConnectedAt: SignalTimestamp,
        startSoc: Float?,
        startOdometerKm: Float?,
        plugType: Int?
    ): SessionEntity? {
        val latest = latestOpenChargeSession() ?: return null
        val ageMillis = kotlin.math.abs(plugConnectedAt.receivedAtUtcMillis - latest.startedAtUtcMillis)
        if (ageMillis > CHARGE_REUSE_WINDOW_MILLIS) return null
        if (!sameNullableInt(plugType, latest.plugType)) return null
        if (!closeNullableFloat(startSoc, latest.startSocPercent, SOC_REUSE_TOLERANCE)) return null
        if (!closeNullableFloat(startOdometerKm, latest.startOdometerKm, ODOMETER_REUSE_TOLERANCE_KM)) return null
        return latest
    }

    private fun sameNullableInt(left: Int?, right: Int?): Boolean {
        return left == null || right == null || left == right
    }

    private fun closeNullableFloat(left: Float?, right: Float?, tolerance: Float): Boolean {
        if (left == null || right == null) return true
        return abs(left - right) <= tolerance
    }

    companion object {
        private const val TAG = "SessionRepository"
        private const val CHARGE_REUSE_WINDOW_MILLIS = 10 * 60 * 1_000L
        private const val SOC_REUSE_TOLERANCE = 0.25f
        private const val ODOMETER_REUSE_TOLERANCE_KM = 0.1f
        private const val MAX_CHARGE_MERGE_GAP_MILLIS = 10 * 60 * 1_000L
        private const val MAX_TRIP_WALL_DURATION_MILLIS = 48 * 60 * 60 * 1_000L
        private const val MAX_CHARGE_WALL_DURATION_MILLIS = 31L * 24L * 60L * 60L * 1_000L
        private const val MERGE_CANDIDATE_WINDOW_MILLIS = 30L * 24 * 60 * 60 * 1_000L
        private const val MAX_CHARGE_MERGE_OVERLAP_MILLIS = 5_000L
        private const val SOC_MERGE_TOLERANCE = 0.5f
        private const val ODOMETER_MERGE_TOLERANCE_KM = 0.2f
    }
}

private data class ChargeMergeCandidate(
    val sessions: List<SessionEntity>,
    val breaks: List<ChargeMergeBreak>,
    val totalFrames: Long
) {
    val startUtcMillis: Long = sessions.first().startedAtUtcMillis
    val endUtcMillis: Long = sessions.last().endedAtUtcMillis
        ?: sessions.last().plugDisconnectedAtUtcMillis
        ?: sessions.last().chargeEndedAtUtcMillis
        ?: sessions.last().updatedAtUtcMillis

    fun toRow(costs: Map<String, SessionCostEntity> = emptyMap()): ChargeMergeCandidateRow = ChargeMergeCandidateRow(
        sessionIds = sessions.map { it.id },
        sessions = sessions.map { session ->
            val cost = costs[session.id]
            val priced = cost?.let {
                session.copy(
                    costPerKwh = it.costPerKwh,
                    paidAmount = it.paidAmount,
                    costCurrency = it.costCurrency
                )
            } ?: session
            ChargeSessionRow(
                session = priced,
                durationMillis = null,
                endSoc = session.endSocPercent,
                endOdometerKm = session.endOdometerKm,
                endAmbientTempC = session.endAmbientTempC,
                estimatedEnergyKwh = null,
                updatedAtUtcMillis = session.updatedAtUtcMillis,
            )
        },
        breaks = breaks.map { it.toRow() },
        startUtcMillis = startUtcMillis,
        endUtcMillis = endUtcMillis,
        durationMillis = (endUtcMillis - startUtcMillis).coerceAtLeast(0L),
        totalFrames = totalFrames,
        startSoc = sessions.first().startSocPercent,
        endSoc = sessions.last().endSocPercent,
        startOdometerKm = sessions.first().startOdometerKm,
        endOdometerKm = sessions.last().endOdometerKm,
    )
}

private data class ChargeMergeBreak(
    val previousSessionId: String,
    val nextSessionId: String,
    val gapMillis: Long,
    val socDelta: Float?,
    val odometerDeltaKm: Float?
) {
    fun toRow(): ChargeMergeBreakRow = ChargeMergeBreakRow(
        previousSessionId = previousSessionId,
        nextSessionId = nextSessionId,
        gapMillis = gapMillis,
        socDelta = socDelta,
        odometerDeltaKm = odometerDeltaKm,
    )
}
