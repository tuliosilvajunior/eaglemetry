package com.timhss.capyenergy.telemetry

import android.content.Context
import com.timhss.capyenergy.telemetry.ClockAnchorStore.Anchor
import com.timhss.capyenergy.telemetry.OffsetDetector.ClockSample
import com.timhss.capyenergy.telemetry.OffsetDetector.StructuralFlag
import com.timhss.capyenergy.telemetry.db.ClockBadSignatureDao
import com.timhss.capyenergy.telemetry.db.ClockBadSignatureEntity
import com.timhss.capyenergy.telemetry.db.IntervalDao

/**
 * Time authority T5, step 4: the evidence-backed boot-default ledger.
 *
 * Every session close feeds the boot's paired stamps through the detector.
 * When the detector PROVES a stamp is a boot default — the census plus
 * plateau override, the only arm that names rows bad with structural
 * evidence, not distribution alone — the stamp lands in
 * `clock_bad_signatures`. A later boot that opens on a value in this ledger
 * writes its minutes PENDING from the first sample, with no MAD test and no
 * wait for the jump: the fleet's checksum, learned from real data and never
 * written as a constant anywhere (plan section 3.2.3, section 9).
 *
 * Reading is the cheap half: one exact-key lookup the collector can afford
 * per minute.
 */
class ClockBadSignatureLedger(
    private val signatureDao: ClockBadSignatureDao,
    private val intervalDao: IntervalDao,
    private val nowUtcMillis: () -> Long = { System.currentTimeMillis() }
) {
    /** True when the exact wall value is a proven boot default. */
    fun isKnownBad(wallMillis: Long): Boolean = signatureDao.countByWall(wallMillis) > 0

    /**
     * Feeds one boot's paired rows through the detector and records the
     * stamps it proved default. Returns how many new signatures were
     * recorded. Read-only on intervals.
     */
    fun learnFromBoot(bootCount: Long): Int {
        val rows = intervalDao.allPaired()
        val samples = rows.mapNotNull { row ->
            val elapsed = row.startElapsedNanos ?: return@mapNotNull null
            ClockSample(
                bootCount = row.startBootCount?.toLong() ?: return@mapNotNull null,
                wallMillis = row.startUtcMillis,
                elapsedNanos = elapsed
            )
        }
        if (samples.isEmpty()) return 0
        val result = OffsetDetector.detect(samples)
        val verdict = result.boots[bootCount] ?: return 0
        // Only the structural override names evidence: census stars, plateau
        // prefixes. The distributional arm alone flags outliers, and one
        // honest outlier must never become a fleet-wide banned value.
        if (StructuralFlag.DUPLICATE_STAMP !in verdict.flags) return 0
        val learned = verdict.rejected
            .filter { it.bootCount == bootCount }
            .map { it.wallMillis }
            .toSet()
        if (learned.isEmpty()) return 0
        val now = nowUtcMillis()
        var recorded = 0
        for (wall in learned) {
            if (signatureDao.countByWall(wall) > 0) continue
            signatureDao.upsert(ClockBadSignatureEntity(wallUtcMillis = wall, firstSeenUtcMillis = now, hits = 1))
            recorded++
        }
        return recorded
    }
}
