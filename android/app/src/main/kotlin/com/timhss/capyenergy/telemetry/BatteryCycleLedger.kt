package com.timhss.capyenergy.telemetry

import kotlin.math.min

/**
 * Folds the session history into battery cycles.
 *
 * One cycle is one equivalent full cycle: it closes when the SOC removed by
 * trips reaches 100 %. The three that control every number here are:
 *
 * - The boundary is in SOC percent, never in kWh. A boundary in kWh would need
 *   pack capacity, which this car does not report truthfully.
 * - Parked SOC loss is counted but does not move the boundary, so a cycle keeps
 *   answering "how far does one full battery go".
 * - Cost uses the moving weighted average price of the pack, because the pack
 *   mixes. Charging changes the blend; discharging does not.
 *
 * This object is pure. It holds no Room type and no Android type, so the rules
 * above can be tested without a database. The caller resolves pack capacity and
 * trip distance before it builds the events.
 */
object BatteryCycleLedger {

    /** Per-step SOC moves below this are noise, not discharge. Matches CLAUDE.md. */
    const val SOC_NOISE_FLOOR_PERCENT = 0.05

    /** The SOC a cycle must discharge before it closes. */
    const val CYCLE_PERCENT = 100.0

    private const val EPSILON = 1e-9

    enum class EventKind { TRIP, CHARGE, PARKED }

    /**
     * One SOC-moving interval, already resolved by the caller.
     *
     * @param capacityWh pack capacity for this interval, or null when no
     *   trustworthy capacity is known. A null makes the energy of this interval
     *   unknown; it never makes it zero.
     * @param distanceKm trip distance, odometer-first, resolved by the caller.
     * @param costPerKwh the charge price, or null for an unpriced charge. Free
     *   charging and a price the user did not enter cannot be told apart, so an
     *   unpriced charge adds unpriced energy rather than energy at zero.
     */
    data class Event(
        val kind: EventKind,
        /** The session row this interval came from, so the fold can name it. */
        val sessionId: String,
        val startUtcMillis: Long,
        val endUtcMillis: Long,
        val startSoc: Double,
        val endSoc: Double,
        val capacityWh: Double? = null,
        val distanceKm: Double? = null,
        val costPerKwh: Double? = null,
        val costCurrency: String? = null
    )

    /**
     * One session's part in one cycle.
     *
     * The fold is the only place that knows this. A cycle is a window of time,
     * but the sessions inside that window are not the sessions the cycle
     * counted: a trip that crosses the 100 % mark belongs to **two** cycles, in
     * the proportion the ledger split it by, and a reader that recovers the
     * list from the timestamps alone cannot see that.
     *
     * A member is recorded for every interval that moved SOC past the noise
     * floor, including one whose capacity was unknown — that interval is part
     * of the cycle even though its energy is not. An interval below the floor
     * is not a member: the fold treats it as noise and it contributed nothing.
     *
     * @param share how much of the session this cycle took, 0 to 1. It is
     *   below 1 only for a trip split across a cycle boundary, and the shares
     *   of one session over its cycles sum to 1.
     */
    data class Member(
        val kind: EventKind,
        val sessionId: String,
        val share: Double,
        val startUtcMillis: Long,
        val endUtcMillis: Long
    )

    /**
     * One battery cycle.
     *
     * @param dischargePercent how full the bar is, 0 to 100. Below 100 only for
     *   the open cycle.
     * @param energyIncomplete true when some interval of this cycle had no
     *   trustworthy capacity, so the energy totals are a floor and not a total.
     * @param mixedCurrency true when charges of two currencies fed this cycle.
     *   The cost is then null, because adding them would invent a number.
     */
    data class Cycle(
        val startUtcMillis: Long,
        val endUtcMillis: Long,
        val dischargePercent: Double,
        val distanceKm: Double,
        val tripEnergyKwh: Double,
        val parkedEnergyKwh: Double,
        val parkedSocPercent: Double,
        val cost: Double?,
        val costCurrency: String?,
        val pricedEnergyKwh: Double,
        val unpricedEnergyKwh: Double,
        val isOpen: Boolean,
        val isPartial: Boolean,
        val energyIncomplete: Boolean,
        val mixedCurrency: Boolean,
        /** The pack blend as it was when this cycle opened. See [Resume]. */
        val openingPricedFraction: Double,
        /** The blended price as it was when this cycle opened. See [Resume]. */
        val openingBlendedPrice: Double,
        /** The sessions this cycle counted, oldest first. See [Member]. */
        val members: List<Member> = emptyList()
    ) {
        /** The share of this cycle's energy that carries a known price, 0 to 1. */
        val costCoverage: Double?
            get() {
                val total = pricedEnergyKwh + unpricedEnergyKwh
                return if (total <= EPSILON) null else pricedEnergyKwh / total
            }

        /** Distance over energy. Null when either is unknown, never zero. */
        val efficiencyKmPerKwh: Double?
            get() = if (tripEnergyKwh > EPSILON && distanceKm > EPSILON) {
                distanceKm / tripEnergyKwh
            } else {
                null
            }

        /** The usable capacity this cycle measured, in kWh per 100 % of SOC. */
        val measuredCapacityKwh: Double?
            get() = if (dischargePercent > EPSILON && tripEnergyKwh > EPSILON && !energyIncomplete) {
                tripEnergyKwh * CYCLE_PERCENT / dischargePercent
            } else {
                null
            }
    }

    /**
     * Where a fold starts, so it does not have to start at the beginning.
     *
     * Retention deletes old sessions, but a cycle outlives them, so the cycles are stored and
     * extended rather than folded again from the first session.
     *
     * A cycle is never continued in place. It is rebuilt from its own start,
     * with the pack blend it opened with, over the sessions inside it. That
     * keeps the resume state to two numbers: continuing a half-accumulated
     * cycle would need the blend as it stands **now**, which is not the blend
     * the cycle opened with, so it would have to be stored and kept in step
     * with every charge. Rebuilding needs neither.
     *
     * Every stored cycle carries the blend it opened with, so any cycle is a
     * valid resume point. That is what lets a late pricing edit refold the tail
     * from the charge it touched instead of from the beginning, and it bounds
     * the work of a refresh to one cycle.
     */
    data class Resume(
        val pricedFraction: Double = 0.0,
        val blendedPrice: Double = 0.0,
        /** True when the cycle being rebuilt is the first of the record. */
        val isPartial: Boolean = false
    )

    /**
     * Folds [events] into cycles, oldest first.
     *
     * [events] must be in time order and must not overlap. The caller merges the
     * trip, charge and parked rows into that one stream.
     *
     * With no [resume] this is a fold from the beginning of the record, and the
     * first cycle is marked partial: collection started in the middle of a
     * battery, so its bar does not describe a whole one. With a [resume],
     * [events] must be the sessions from the resume point onward, and the
     * returned list holds the rebuilt cycle and every cycle after it.
     * The last cycle is marked open when it did not reach 100 %.
     */
    fun fold(events: List<Event>, resume: Resume? = null): List<Cycle> {
        if (events.isEmpty()) return emptyList()

        val cycles = mutableListOf<Cycle>()
        val pack = PackComposition(
            pricedFraction = resume?.pricedFraction ?: 0.0,
            blendedPrice = resume?.blendedPrice ?: 0.0
        )
        var current = OpenCycle(events.first().startUtcMillis, pack)
        current.isPartial = resume?.isPartial ?: false

        for (event in events) {
            current.touch(event)
            // A trip can close one or more cycles, so it is the only step that
            // replaces the open cycle. It returns the one to carry forward.
            current = when (event.kind) {
                EventKind.CHARGE -> current.also { applyCharge(event, pack, it) }
                EventKind.PARKED -> current.also { applyParked(event, pack, it) }
                EventKind.TRIP -> applyTrip(event, pack, current, cycles)
            }
        }

        cycles.add(current.close(isOpen = true))
        // Only a fold from the beginning of the record can know that its first
        // cycle is partial. A resumed fold continues a cycle that already
        // carries the answer.
        if (resume != null) return cycles
        return cycles.mapIndexed { index, cycle ->
            if (index == 0) cycle.copy(isPartial = true) else cycle
        }
    }

    private fun applyCharge(event: Event, pack: PackComposition, current: OpenCycle) {
        val socGain = event.endSoc - event.startSoc
        if (socGain <= SOC_NOISE_FLOOR_PERCENT) return
        current.addMember(event, share = 1.0)
        val capacityKwh = capacityKwhOf(event)
        if (capacityKwh == null) {
            current.energyIncomplete = true
            return
        }
        val before = event.startSoc / 100.0 * capacityKwh
        val added = socGain / 100.0 * capacityKwh
        pack.charge(before, added, event.costPerKwh)
        if (event.costPerKwh != null) current.observeCurrency(event.costCurrency)
    }

    private fun applyParked(event: Event, pack: PackComposition, current: OpenCycle) {
        val socDrop = event.startSoc - event.endSoc
        if (socDrop <= SOC_NOISE_FLOOR_PERCENT) return
        current.addMember(event, share = 1.0)
        current.parkedSocPercent += socDrop
        val capacityKwh = capacityKwhOf(event)
        if (capacityKwh == null) {
            current.energyIncomplete = true
            return
        }
        val energy = socDrop / 100.0 * capacityKwh
        current.parkedEnergyKwh += energy
        // Parked energy is bought energy too, so it is debited against the
        // ledger. It is reported apart, because a driver must see what standing
        // still cost. It does not move the boundary.
        val draw = pack.discharge(energy)
        current.addMoney(draw)
    }

    private fun applyTrip(
        event: Event,
        pack: PackComposition,
        openCycle: OpenCycle,
        cycles: MutableList<Cycle>
    ): OpenCycle {
        val socDrop = event.startSoc - event.endSoc
        if (socDrop <= SOC_NOISE_FLOOR_PERCENT) return openCycle

        val capacityKwh = capacityKwhOf(event)
        val totalEnergy = capacityKwh?.let { socDrop / 100.0 * it }
        val totalDistance = event.distanceKm ?: 0.0
        val draw = totalEnergy?.let { pack.discharge(it) }

        var current = openCycle
        var remainingSoc = socDrop

        // A trip is split across the 100 % mark in proportion to the SOC on
        // each side of it. Nothing else keeps the sum of the parts equal to the
        // whole. The loop is a loop, not an if, so that a trip larger than one
        // whole cycle cannot leave SOC unattributed.
        while (remainingSoc > EPSILON) {
            val room = CYCLE_PERCENT - current.dischargePercent
            val take = min(remainingSoc, room)
            val share = take / socDrop

            current.addMember(event, share)
            current.dischargePercent += take
            current.distanceKm += totalDistance * share
            if (totalEnergy == null) {
                current.energyIncomplete = true
            } else {
                current.tripEnergyKwh += totalEnergy * share
                current.addMoney(draw!!.share(share))
            }
            current.touchEnd(event.endUtcMillis)

            remainingSoc -= take
            if (current.dischargePercent >= CYCLE_PERCENT - EPSILON) {
                cycles.add(current.close(isOpen = false))
                // Discharging does not move the blend, so the cycle that opens
                // here inherits exactly the blend the closed one drew at.
                current = OpenCycle(event.endUtcMillis, pack)
            }
        }
        return current
    }

    private fun capacityKwhOf(event: Event): Double? {
        val wh = event.capacityWh ?: return null
        return if (wh > EPSILON) wh / 1000.0 else null
    }

    /**
     * What is in the pack and what it cost.
     *
     * The pack is a mixing tank, so the state is a blend and not a queue.
     * Charging moves the blend; discharging draws at the blend and leaves it
     * unchanged. The pack energy itself is never accumulated: it is read from
     * SOC at each event, so the ledger cannot drift.
     *
     * The blend starts fully unpriced. Nothing is known about the energy that
     * was in the pack before collection began, and calling it free would be an
     * invented price.
     */
    private class PackComposition(
        var pricedFraction: Double = 0.0,
        var blendedPrice: Double = 0.0
    ) {

        fun charge(beforeKwh: Double, addedKwh: Double, price: Double?) {
            val total = beforeKwh + addedKwh
            if (total <= EPSILON) return
            val pricedBefore = beforeKwh * pricedFraction
            val moneyBefore = pricedBefore * blendedPrice
            val pricedAfter: Double
            val moneyAfter: Double
            if (price != null) {
                pricedAfter = pricedBefore + addedKwh
                moneyAfter = moneyBefore + addedKwh * price
            } else {
                pricedAfter = pricedBefore
                moneyAfter = moneyBefore
            }
            pricedFraction = (pricedAfter / total).coerceIn(0.0, 1.0)
            blendedPrice = if (pricedAfter > EPSILON) moneyAfter / pricedAfter else 0.0
        }

        fun discharge(takeKwh: Double): Draw {
            val priced = takeKwh * pricedFraction
            return Draw(
                pricedKwh = priced,
                unpricedKwh = takeKwh - priced,
                money = priced * blendedPrice
            )
        }
    }

    /** One withdrawal from the pack, and what part of it had a known price. */
    private data class Draw(
        val pricedKwh: Double,
        val unpricedKwh: Double,
        val money: Double
    ) {
        fun share(fraction: Double) =
            Draw(pricedKwh * fraction, unpricedKwh * fraction, money * fraction)
    }

    private class OpenCycle {
        var startUtcMillis: Long
        var endUtcMillis: Long
        var dischargePercent = 0.0
        var distanceKm = 0.0
        var tripEnergyKwh = 0.0
        var parkedEnergyKwh = 0.0
        var parkedSocPercent = 0.0
        var money = 0.0
        var pricedEnergyKwh = 0.0
        var unpricedEnergyKwh = 0.0
        var energyIncomplete = false
        var mixedCurrency = false
        var currency: String? = null
        var isPartial = false
        val members = mutableListOf<Member>()

        /** The blend when this cycle opened, so the cycle can be resumed later. */
        val openingPricedFraction: Double
        val openingBlendedPrice: Double

        constructor(startUtcMillis: Long, pack: PackComposition) {
            this.startUtcMillis = startUtcMillis
            this.endUtcMillis = startUtcMillis
            this.openingPricedFraction = pack.pricedFraction
            this.openingBlendedPrice = pack.blendedPrice
        }


        fun touch(event: Event) {
            if (event.startUtcMillis < startUtcMillis) startUtcMillis = event.startUtcMillis
            touchEnd(event.endUtcMillis)
        }

        fun touchEnd(millis: Long) {
            if (millis > endUtcMillis) endUtcMillis = millis
        }

        fun addMember(event: Event, share: Double) {
            members.add(
                Member(
                    kind = event.kind,
                    sessionId = event.sessionId,
                    share = share,
                    startUtcMillis = event.startUtcMillis,
                    endUtcMillis = event.endUtcMillis
                )
            )
        }

        fun addMoney(draw: Draw) {
            money += draw.money
            pricedEnergyKwh += draw.pricedKwh
            unpricedEnergyKwh += draw.unpricedKwh
        }

        fun observeCurrency(code: String?) {
            if (code == null) return
            val held = currency
            if (held == null) {
                currency = code
            } else if (held != code) {
                // Two currencies cannot be added. Report no cost rather than a
                // number that means nothing.
                mixedCurrency = true
            }
        }

        fun close(isOpen: Boolean) = Cycle(
            startUtcMillis = startUtcMillis,
            endUtcMillis = endUtcMillis,
            dischargePercent = if (isOpen) dischargePercent else CYCLE_PERCENT,
            distanceKm = distanceKm,
            tripEnergyKwh = tripEnergyKwh,
            parkedEnergyKwh = parkedEnergyKwh,
            parkedSocPercent = parkedSocPercent,
            cost = if (mixedCurrency || pricedEnergyKwh <= EPSILON) null else money,
            costCurrency = if (mixedCurrency) null else currency,
            pricedEnergyKwh = pricedEnergyKwh,
            unpricedEnergyKwh = unpricedEnergyKwh,
            isOpen = isOpen,
            isPartial = isPartial,
            energyIncomplete = energyIncomplete,
            mixedCurrency = mixedCurrency,
            openingPricedFraction = openingPricedFraction,
            openingBlendedPrice = openingBlendedPrice,
            members = members.toList()
        )
    }
}
