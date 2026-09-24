package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.concurrent.namedSingleThreadExecutor
import com.timhss.capyenergy.telemetry.db.SessionCostEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import java.util.concurrent.Callable

/**
 * The price of charges, on the annotation side.
 *
 * Slice 6 moved a charge's `costPerKwh` and `paidAmount` off the session
 * measurement table because a price is a person stating what they paid: it
 * is edited after the session closes, from the phone as well, and it syncs
 * both directions. The default rate still lands when a charge session is
 * **created** and never when a total is read; what changed is the table,
 * not that rule.
 */
class SessionCostRepository(
    context: Context,
    private val clock: () -> Long = System::currentTimeMillis,
    /**
     * Fired after every landed cost write. Wired to the session change
     * broadcaster's `chargesChanged` and to the annotation channel: a cost
     * is both a charge row a list shows and an annotation a replica learns.
     */
    private val onChanged: () -> Unit = {},
    private val hlcClock: AnnotationHlcClock = AnnotationHlcClock.global,
    private val accountIdProvider: () -> String? = { null },
) {
    private val database = TelemetryDatabase.get(context.applicationContext)
    private val costDao = database.sessionCostDao()
    // Singular, and that is not a typo: "session-costs-db" is 16 characters and
    // Linux truncates a thread name at 15, so `namedThreadFactory` refuses it.
    private val dbExecutor = namedSingleThreadExecutor("session-cost-db")

    /** The car's own edit: a person priced a charge. */
    fun priceFromCar(
        sessionId: String,
        costPerKwh: Double?,
        paidAmount: Double?,
        currency: String?
    ): SessionCostEntity {
        require(sessionId.isNotBlank()) { "priceFromCar requires a sessionId" }
        return upsert(
            sessionId = sessionId,
            costPerKwh = normalize(costPerKwh),
            paidAmount = normalize(paidAmount),
            currency = currency?.trim()?.takeIf { it.isNotEmpty() },
            updatedAtUtcMillis = clock(),
            origin = AnnotationConvergence.ORIGIN_CAR
        )
    }

    /** The default rate stamped when a charge session is created. */
    fun stampDefaultAtCreate(sessionId: String, costPerKwh: Double?, currency: String) {
        val rate = normalize(costPerKwh) ?: return
        upsert(
            sessionId = sessionId,
            costPerKwh = rate,
            paidAmount = null,
            currency = currency.trim().takeIf { it.isNotEmpty() },
            updatedAtUtcMillis = clock(),
            origin = AnnotationConvergence.ORIGIN_CAR
        )
    }
    /**
     * Fills the past with the default rate. Returns the row count and the
     * oldest session priced, so the caller can say what landed. A row with a
     * price already is never touched: a rate must not overwrite a receipt.
     */
    fun applyDefaultToUnpriced(rate: Double, currency: String): Pair<Int, Long?> {
        val normalizedRate = normalize(rate) ?: return 0 to null
        return dbExecutor.submit(Callable {
            val unpriced = costDao.unpricedClosedChargeSessionIds()
            if (unpriced.isEmpty()) return@Callable 0 to null
            val oldest = costDao.oldestUnpricedClosedStart()
            val now = clock()
            val hlc = hlcClock.tickAt(now)
            for (sessionId in unpriced) {
                costDao.upsert(
                    SessionCostEntity(
                        sessionId = sessionId,
                        costPerKwh = normalizedRate,
                        paidAmount = null,
                        costCurrency = currency.trim().takeIf { it.isNotEmpty() },
                        updatedAtUtcMillis = now,
                        origin = AnnotationConvergence.ORIGIN_CAR,
                        hlcMillis = hlc.millis,
                        hlcCounter = hlc.counter,
                        hlcDeviceId = hlc.deviceId,
                        accountId = accountIdProvider()
                    )
                )
            }
            onChanged()
            unpriced.size to oldest
        }).get()
    }

    /** The start of the oldest closed charge with no price yet. */
    fun oldestUnpricedClosedStart(): Long? =
        dbExecutor.submit(Callable { costDao.oldestUnpricedClosedStart() }).get()

    /** One row from the annotation channel. Last writer wins. */
    fun mergeIncoming(row: Map<String, Any?>): Boolean {
        val sessionId = (row["sessionId"] as? String)?.takeIf { it.isNotBlank() } ?: return false
        val updatedAtUtcMillis = AnnotationConvergence.updatedAtUtcMillis(row) ?: return false
        val origin = AnnotationConvergence.origin(row) ?: AnnotationConvergence.ORIGIN_PHONE
        val incomingHlc = AnnotationHlc.fromRow(row)
            ?: AnnotationHlc(millis = updatedAtUtcMillis, counter = 0, deviceId = origin)

        return dbExecutor.submit(Callable {
            hlcClock.merge(incomingHlc)
            val existing = costDao.findById(sessionId)
            if (existing != null && !AnnotationConvergence.shouldReplace(
                    existingHlc = AnnotationHlc(
                        millis = existing.hlcMillis,
                        counter = existing.hlcCounter,
                        deviceId = existing.hlcDeviceId,
                    ),
                    existingOrigin = existing.origin,
                    incomingHlc = incomingHlc,
                    incomingOrigin = origin
                )
            ) {
                return@Callable false
            }
            costDao.upsert(
                SessionCostEntity(
                    sessionId = sessionId,
                    costPerKwh = normalize((row["costPerKwh"] as? Number)?.toDouble()),
                    paidAmount = normalize((row["paidAmount"] as? Number)?.toDouble()),
                    costCurrency = (row["costCurrency"] as? String)?.trim()?.takeIf { it.isNotEmpty() },
                    updatedAtUtcMillis = updatedAtUtcMillis,
                    origin = origin,
                    hlcMillis = incomingHlc.millis,
                    hlcCounter = incomingHlc.counter,
                    hlcDeviceId = incomingHlc.deviceId,
                    // A row written for the annotation channel is born under
                    // the pairing that is active when it lands — whatever its
                    // origin. A phone-origin row stamped null would stay
                    // unowned forever: nothing on the car re-stamps a landed
                    // row, and the claim backfill does not cover session_costs.
                    accountId = accountIdProvider()
                )
            )
            onChanged()
            true
        }).get()
    }

    private fun upsert(
        sessionId: String,
        costPerKwh: Double?,
        paidAmount: Double?,
        currency: String?,
        updatedAtUtcMillis: Long,
        origin: String,
    ): SessionCostEntity {
        val hlc = hlcClock.tickAt(updatedAtUtcMillis)
        val row = SessionCostEntity(
            sessionId = sessionId,
            costPerKwh = costPerKwh,
            paidAmount = paidAmount,
            costCurrency = currency,
            updatedAtUtcMillis = updatedAtUtcMillis,
            origin = origin,
            hlcMillis = hlc.millis,
            hlcCounter = hlc.counter,
            hlcDeviceId = hlc.deviceId,
            // Born owned under the active pairing, like mergeIncoming above:
            // the origin records who wrote the price, never who owns the row.
            accountId = accountIdProvider(),
        )
        dbExecutor.submit<Unit> {
            costDao.upsert(row)
            onChanged()
        }.get()
        return row
    }


    fun bySession(sessionId: String): SessionCostEntity? =
        dbExecutor.submit(Callable { costDao.findById(sessionId) }).get()

    fun costsFor(sessionIds: List<String>): Map<String, SessionCostEntity> {
        if (sessionIds.isEmpty()) return emptyMap()
        return dbExecutor.submit(Callable {
            costDao.forSessions(sessionIds).associateBy { it.sessionId }
        }).get()
    }

    fun latestPricedBefore(beforeUtcMillis: Long): SessionCostEntity? =
        dbExecutor.submit(Callable { costDao.latestPricedBefore(beforeUtcMillis) }).get()

    fun syncPage(afterUpdatedAtUtcMillis: Long, afterSessionId: String, limit: Int): List<SessionCostEntity> =
        dbExecutor.submit(
            Callable { costDao.syncPage(afterUpdatedAtUtcMillis, afterSessionId, limit) }
        ).get()

    fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String): Long =
        dbExecutor.submit(
            Callable { costDao.syncPendingCount(afterUpdatedAtUtcMillis, afterSessionId) }
        ).get()

    private fun normalize(value: Double?): Double? =
        value?.takeIf { it.isFinite() && it >= 0.0 }
}
