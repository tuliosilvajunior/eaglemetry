package com.timhss.capyenergy.telemetry.control

import com.timhss.capyenergy.telemetry.db.PreferenceProposalDao
import com.timhss.capyenergy.telemetry.db.PreferenceProposalEntity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The car's Lane C sync, driven by a fake cloud and a fake proposal DAO —
 * the same fake-double style the annotation uploader tests use. No network,
 * no Room.
 */
class PreferenceControlSyncTest {

    // ---- Fakes -------------------------------------------------------------

    private class FakeCloud : PreferenceControlCloud {
        var configured = true
        var desired = mutableListOf<PreferenceDesiredRow>()
        var reported = mutableListOf<PreferenceReportedRow>()
        val reportedWrites = mutableListOf<List<PreferenceReportedRow>>()
        var failRead = false
        var failReport = false

        override val isConfigured: Boolean get() = configured

        override suspend fun desiredForVehicle(vehicleId: String): List<PreferenceDesiredRow> {
            if (failRead) throw PreferenceControlCloudException(IllegalStateException("network down"))
            return desired.filter { it.vehicleId == vehicleId }
        }

        override suspend fun reportedForVehicle(vehicleId: String): List<PreferenceReportedRow> {
            if (failRead) throw PreferenceControlCloudException(IllegalStateException("network down"))
            return reported.filter { it.vehicleId == vehicleId }
        }

        override suspend fun report(rows: List<PreferenceReportedRow>) {
            if (failReport) {
                failReport = false
                throw PreferenceControlCloudException(IllegalStateException("write refused"))
            }
            reportedWrites.add(rows.toList())
            reported.addAll(rows)
        }
    }

    private class FakeProposalDao : PreferenceProposalDao {
        val rows = mutableListOf<PreferenceProposalEntity>()

        override fun upsert(proposal: PreferenceProposalEntity) {
            rows.removeAll { it.id == proposal.id }
            rows.add(proposal)
        }

        override fun findById(id: String): PreferenceProposalEntity? =
            rows.firstOrNull { it.id == id }

        override fun all(): List<PreferenceProposalEntity> =
            rows.sortedWith(compareByDescending<PreferenceProposalEntity> { it.proposedAtUtcMillis }.thenByDescending { it.id })

        override fun byStatus(status: String): List<PreferenceProposalEntity> =
            rows.filter { it.status == status }

        override fun syncPage(afterUpdatedAtUtcMillis: Long, afterId: String, limit: Int): List<PreferenceProposalEntity> =
            emptyList()

        override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterId: String): Long = 0L
    }

    private class FakeStore : ReportedDecisionStore {
        val entries = mutableSetOf<String>()
        override fun contains(key: String, decidedAtUtcMillis: Long): Boolean =
            "$key\n$decidedAtUtcMillis" in entries
        override fun add(key: String, decidedAtUtcMillis: Long) {
            entries.add("$key\n$decidedAtUtcMillis")
        }
    }

    // ---- Fixture -----------------------------------------------------------

    private lateinit var cloud: FakeCloud
    private lateinit var dao: FakeProposalDao
    private lateinit var store: FakeStore
    private lateinit var sync: PreferenceControlSync

    private val vehicleId = "VIN-CAR-1"
    private val accountId = "00000000-0000-4000-a000-000000000001"
    private var now = 100_000L

    @Before
    fun setUp() {
        cloud = FakeCloud()
        dao = FakeProposalDao()
        store = FakeStore()
        now = 100_000L
        sync = buildSync()
    }

    private fun buildSync(configured: Boolean = true): PreferenceControlSync {
        cloud.configured = configured
        return PreferenceControlSync(
            cloud = cloud,
            proposalDao = dao,
            surfaceProposal = { row -> acceptAsPending(row) },
            reportedStore = store,
            vehicleIdProvider = { vehicleId },
            accountIdProvider = { accountId },
            clock = { now },
        )
    }

    /** Mirrors [com.timhss.capyenergy.telemetry.PreferenceRepository.mergeIncomingProposal]'s local effect. */
    private fun acceptAsPending(row: Map<String, Any?>): Boolean {
        val id = row["id"] as? String ?: return false
        val key = row["key"] as? String ?: return false
        if (key !in com.timhss.capyenergy.telemetry.PreferenceRepository.CONTROL_KEYS) return false
        dao.upsert(
            PreferenceProposalEntity(
                id = id,
                key = key,
                value = row["value"] as? String,
                status = PreferenceProposalEntity.STATUS_PENDING,
                proposedAtUtcMillis = (row["proposedAtUtcMillis"] as Number).toLong(),
                decidedAtUtcMillis = null,
                updatedAtUtcMillis = (row["updatedAtUtcMillis"] as Number).toLong(),
                origin = row["origin"] as? String ?: "phone",
            )
        )
        return true
    }

    private fun desire(
        key: String = "pack_capacity_wh",
        value: String? = "64000",
        proposedAt: Long = 1_000L,
        vehicle: String = vehicleId,
    ) = PreferenceDesiredRow(
        accountId = accountId,
        vehicleId = vehicle,
        key = key,
        value = value,
        proposedAtUtcMillis = proposedAt,
        origin = "phone",
    )

    private fun decision(
        key: String = "pack_capacity_wh",
        value: String? = "64000",
        decidedAt: Long = 500L,
        status: String = PreferenceReportedRow.STATUS_ACCEPTED,
    ) = PreferenceReportedRow(
        vehicleId = vehicleId,
        accountId = accountId,
        key = key,
        value = value,
        status = status,
        decidedAtUtcMillis = decidedAt,
        reportedAtUtcMillis = decidedAt + 1_000L,
    )

    private fun pendingProposals(): List<PreferenceProposalEntity> =
        dao.byStatus(PreferenceProposalEntity.STATUS_PENDING)

    // ---- Read path ---------------------------------------------------------

    @Test
    fun `surfaces a new desired row as a pending proposal`() = runBlocking {
        cloud.desired.add(desire())
        cloud.reported.addAll(listOf(decision(key = "default_charge_cost_per_kwh", decidedAt = 999L)))

        val report = sync.sync()

        assertEquals(1, report.surfaced)
        val pending = pendingProposals()
        assertEquals(1, pending.size)
        assertEquals("pack_capacity_wh", pending.single().key)
        assertEquals("64000", pending.single().value)
        assertEquals(PreferenceProposalEntity.STATUS_PENDING, pending.single().status)
        assertEquals("cloud:pack_capacity_wh:1000", pending.single().id)
        assertEquals("phone", pending.single().origin)
    }

    @Test
    fun `does not surface a desire already covered by a decision`() = runBlocking {
        cloud.desired.add(desire(proposedAt = 1_000L))
        cloud.reported.add(decision(decidedAt = 2_000L))

        val report = sync.sync()

        assertEquals(0, report.surfaced)
        assertTrue(pendingProposals().isEmpty())
    }

    @Test
    fun `surfaces a superseded desire whose decision predates it`() = runBlocking {
        // Same key: decision at 500, a newer desire proposed at 1000. The report
        // is older than the desire -> the desire must be surfaced (stale), never
        // treated as applied.
        cloud.desired.add(desire(proposedAt = 1_000L))
        cloud.reported.add(decision(decidedAt = 500L))

        val report = sync.sync()

        assertEquals(1, report.surfaced)
        assertEquals("cloud:pack_capacity_wh:1000", pendingProposals().single().id)
    }

    @Test
    fun `does not surface a desire while a prompt is already pending for the key`() = runBlocking {
        dao.upsert(
            PreferenceProposalEntity(
                id = "existing-prompt",
                key = "pack_capacity_wh",
                value = "60000",
                status = PreferenceProposalEntity.STATUS_PENDING,
                proposedAtUtcMillis = 500L,
                decidedAtUtcMillis = null,
                updatedAtUtcMillis = 500L,
                origin = "phone",
            )
        )
        cloud.desired.add(desire(value = "64000", proposedAt = 1_000L))

        val report = sync.sync()

        assertEquals(0, report.surfaced)
        assertEquals(1, pendingProposals().size)
        assertEquals("existing-prompt", pendingProposals().single().id)
    }

    @Test
    fun `does not surface the same cloud desire twice`() = runBlocking {
        cloud.desired.add(desire())
        cloud.reported.clear()
        sync.sync()
        assertEquals(1, pendingProposals().size)

        val report = sync.sync()

        assertEquals(0, report.surfaced)
        assertEquals(1, pendingProposals().size)
    }

    @Test
    fun `ignores desires for keys outside the control lane`() = runBlocking {
        cloud.desired.add(desire(key = "theme_id", value = "dark", proposedAt = 1_000L))

        val report = sync.sync()

        assertEquals(0, report.surfaced)
        assertTrue(pendingProposals().isEmpty())
    }

    @Test
    fun `surfaced desire flows into the local pending table for the UI`() = runBlocking {
        cloud.desired.add(desire())
        sync.sync()
        // The settings screen reads pendingProposals() -> byStatus(PENDING).
        assertTrue(dao.byStatus(PreferenceProposalEntity.STATUS_PENDING).isNotEmpty())
    }

    // ---- Write path --------------------------------------------------------

    @Test
    fun `reports an accepted decision with applied value`() = runBlocking {
        dao.upsert(
            decided(
                status = PreferenceProposalEntity.STATUS_ACCEPTED,
                value = "64000",
                decidedAt = 5_000L,
            )
        )

        val report = sync.sync()

        assertEquals(1, report.reported)
        val write = cloud.reportedWrites.last()
        assertEquals(1, write.size)
        val row = write.single()
        assertEquals(vehicleId, row.vehicleId)
        assertEquals(accountId, row.accountId)
        assertEquals("pack_capacity_wh", row.key)
        assertEquals("64000", row.value)
        assertEquals(PreferenceReportedRow.STATUS_ACCEPTED, row.status)
        assertEquals(5_000L, row.decidedAtUtcMillis)
        assertEquals(now, row.reportedAtUtcMillis)
    }

    @Test
    fun `reports a refused decision with the desired value`() = runBlocking {
        dao.upsert(
            decided(
                status = PreferenceProposalEntity.STATUS_REFUSED,
                value = "60000",
                decidedAt = 6_000L,
            )
        )

        sync.sync()

        val row = cloud.reportedWrites.last().single()
        assertEquals(PreferenceReportedRow.STATUS_REFUSED, row.status)
        // The value the car declined: the proposed (desired) value.
        assertEquals("60000", row.value)
        assertEquals(6_000L, row.decidedAtUtcMillis)
    }

    @Test
    fun `an already reported decision is not re-sent`() = runBlocking {
        dao.upsert(
            decided(
                status = PreferenceProposalEntity.STATUS_ACCEPTED,
                value = "64000",
                decidedAt = 5_000L,
            )
        )

        sync.sync()
        assertEquals(1, cloud.reportedWrites.size)

        val report = sync.sync()
        assertEquals(0, report.reported)
        assertEquals(1, cloud.reportedWrites.size)
    }

    @Test
    fun `a failed report is retried and never marked`() = runBlocking {
        dao.upsert(
            decided(
                status = PreferenceProposalEntity.STATUS_ACCEPTED,
                value = "64000",
                decidedAt = 5_000L,
            )
        )
        cloud.failReport = true

        var threw = false
        try {
            sync.sync()
        } catch (e: PreferenceControlCloudException) {
            threw = true
        }
        assertTrue(threw)
        assertTrue(cloud.reportedWrites.isEmpty())
        assertFalse(store.contains("pack_capacity_wh", 5_000L))
        assertTrue(dao.byStatus(PreferenceProposalEntity.STATUS_ACCEPTED).isNotEmpty())

        // Next pass succeeds; the decision is written (and marked) once.
        sync.sync()
        assertEquals(1, cloud.reportedWrites.size)
        assertTrue(store.contains("pack_capacity_wh", 5_000L))
    }

    @Test
    fun `read failure surfaces nothing and does not downgrade local rows`() = runBlocking {
        dao.upsert(
            decided(
                status = PreferenceProposalEntity.STATUS_ACCEPTED,
                value = "64000",
                decidedAt = 5_000L,
            )
        )
        cloud.desired.add(desire())
        cloud.failRead = true

        var threw = false
        try {
            sync.sync()
        } catch (e: PreferenceControlCloudException) {
            threw = true
        }
        assertTrue(threw)
        // The accepted row stays terminal; nothing re-surfaced.
        assertEquals(1, dao.byStatus(PreferenceProposalEntity.STATUS_ACCEPTED).size)
        assertTrue(pendingProposals().isEmpty())
    }

    // ---- Gating ------------------------------------------------------------

    @Test
    fun `unconfigured cloud moves nothing`() = runBlocking {
        cloud.desired.add(desire())
        dao.upsert(
            decided(status = PreferenceProposalEntity.STATUS_ACCEPTED, decidedAt = 5_000L)
        )
        val inert = buildSync(configured = false)

        val report = inert.sync()

        assertTrue(report.movedNothing)
        assertTrue(cloud.reportedWrites.isEmpty())
        assertTrue(pendingProposals().isEmpty())
    }

    @Test
    fun `missing vehicle id moves nothing`() = runBlocking {
        cloud.desired.add(desire())
        dao.upsert(decided(status = PreferenceProposalEntity.STATUS_ACCEPTED, decidedAt = 5_000L))
        val noVehicle = PreferenceControlSync(
            cloud = cloud,
            proposalDao = dao,
            surfaceProposal = { acceptAsPending(it) },
            reportedStore = store,
            vehicleIdProvider = { null },
            accountIdProvider = { accountId },
            clock = { now },
        )

        val report = noVehicle.sync()

        assertTrue(report.movedNothing)
        assertTrue(cloud.reportedWrites.isEmpty())
        assertTrue(pendingProposals().isEmpty())
    }

    @Test
    fun `missing account id moves nothing`() = runBlocking {
        cloud.desired.add(desire())
        dao.upsert(decided(status = PreferenceProposalEntity.STATUS_ACCEPTED, decidedAt = 5_000L))
        val noAccount = PreferenceControlSync(
            cloud = cloud,
            proposalDao = dao,
            surfaceProposal = { acceptAsPending(it) },
            reportedStore = store,
            vehicleIdProvider = { vehicleId },
            accountIdProvider = { null },
            clock = { now },
        )

        val report = noAccount.sync()

        assertTrue(report.movedNothing)
        assertTrue(cloud.reportedWrites.isEmpty())
        assertTrue(pendingProposals().isEmpty())
    }

    // ---- Mass agreement ----------------------------------------------------

    @Test
    fun `a decision on a cloud-surfaced row reports once and is not resurfaced`() = runBlocking {
        cloud.desired.add(desire(proposedAt = 1_000L))
        sync.sync()
        assertEquals(1, pendingProposals().size)

        // The person accepts on the settings screen: decide() flips status and
        // stamps decidedAt. Simulate that exactly as PreferenceRepository.decide()
        // would leave it.
        val surfaced = pendingProposals().single()
        dao.upsert(
            PreferenceProposalEntity(
                id = surfaced.id,
                key = surfaced.key,
                value = surfaced.value,
                status = PreferenceProposalEntity.STATUS_ACCEPTED,
                proposedAtUtcMillis = surfaced.proposedAtUtcMillis,
                decidedAtUtcMillis = 9_000L,
                updatedAtUtcMillis = 9_000L,
                origin = "car",
            )
        )

        val report = sync.sync()

        assertEquals(1, report.reported)
        assertEquals(0, report.surfaced)
        // The cloud now holds the decision, so a later pass sees it covered.
        assertTrue(cloud.reported.any { it.key == "pack_capacity_wh" && it.decidedAtUtcMillis == 9_000L })
    }

    private fun decided(
        status: String,
        value: String? = "64000",
        decidedAt: Long,
        id: String = "local-uuid-$decidedAt",
    ) = PreferenceProposalEntity(
        id = id,
        key = "pack_capacity_wh",
        value = value,
        status = status,
        proposedAtUtcMillis = 1_000L,
        decidedAtUtcMillis = decidedAt,
        updatedAtUtcMillis = decidedAt,
        origin = "car",
        hlcMillis = 0L,
        hlcCounter = 0,
        hlcDeviceId = "car",
    )
}