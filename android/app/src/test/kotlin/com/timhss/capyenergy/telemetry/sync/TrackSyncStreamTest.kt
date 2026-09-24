package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.db.TrackDao
import com.timhss.capyenergy.telemetry.db.TrackEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The Track as a measurement stream: what the car offers, in what order, and
 * what it offers again. Issue 179.
 *
 * The stream is paged over the moment each row was written, not over the
 * session it belongs to. That is the whole design, and every test here is a
 * consequence of it.
 */
class TrackSyncStreamTest {

    private lateinit var trackDao: FakeTrackDao
    private lateinit var packer: SyncBatchPacker

    private val fixedNow = 1_760_000_000_000L

    @Before
    fun setUp() {
        trackDao = FakeTrackDao()
        packer = SyncBatchPacker(
            sessionDao = FakeSessionDao(),
            intervalDao = FakeIntervalDao(),
            batteryCycleDao = FakeBatteryCycleDao(),
            trackDao = trackDao,
            nowUtcMillisProvider = { fixedNow }
        )
    }

    @Test
    fun `a recorded route is offered on the first page`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L))

        val batch = packer.packBatch(SyncStreamType.TRACKS.wireName)

        assertEquals(1, batch.items.size)
        assertEquals("trip-a", batch.items[0]["sessionId"])
        assertEquals("1000:trip-a", batch.nextCursor)
        assertFalse(batch.hasMore)
    }

    @Test
    fun `the wire row carries every column the phone needs to decode it`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L))

        val item = packer.packBatch(SyncStreamType.TRACKS.wireName).items.single()

        assertEquals(
            setOf(
                "sessionId",
                "encodingVersion",
                "pointCount",
                "t",
                "path",
                "speed",
                "alt",
                "updatedAtUtcMillis"
            ),
            item.keys
        )
    }

    @Test
    fun `the stream resumes from its cursor rather than sending it again`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L))
        trackDao.upsert(track("trip-b", updatedAt = 2_000L))

        val first = packer.packBatch(SyncStreamType.TRACKS.wireName, limit = 1)
        val second = packer.packBatch(SyncStreamType.TRACKS.wireName, after = first.nextCursor, limit = 1)

        assertEquals(listOf("trip-a"), first.items.map { it["sessionId"] })
        assertTrue(first.hasMore)
        assertEquals(listOf("trip-b"), second.items.map { it["sessionId"] })
        assertFalse(second.hasMore)
        assertEquals(0L, second.remaining)
    }

    /**
     * The reason the cursor is the write stamp and not the session.
     *
     * The car rewrites the open session's route every minute and replaces it
     * once at close with the simplified path. A phone that pulled during the
     * drive holds the raw one; ordered by session it would sit behind the
     * cursor for ever and the phone would keep a route the car has since
     * corrected.
     */
    @Test
    fun `a route rewritten after it was taken is offered again`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L, pointCount = 400))

        val duringTheDrive = packer.packBatch(SyncStreamType.TRACKS.wireName)
        val cursor = duringTheDrive.nextCursor

        // The close: same session, simplified path, later stamp.
        trackDao.upsert(track("trip-a", updatedAt = 9_000L, pointCount = 92))

        val afterTheClose = packer.packBatch(SyncStreamType.TRACKS.wireName, after = cursor)

        assertEquals(1, afterTheClose.items.size)
        assertEquals("trip-a", afterTheClose.items[0]["sessionId"])
        assertEquals(92, afterTheClose.items[0]["pointCount"])
        assertEquals("9000:trip-a", afterTheClose.nextCursor)
    }

    @Test
    fun `two rows written in the same millisecond are separated by the session`() {
        trackDao.upsert(track("trip-b", updatedAt = 5_000L))
        trackDao.upsert(track("trip-a", updatedAt = 5_000L))

        val first = packer.packBatch(SyncStreamType.TRACKS.wireName, limit = 1)
        val second = packer.packBatch(SyncStreamType.TRACKS.wireName, after = first.nextCursor, limit = 1)

        assertEquals(listOf("trip-a"), first.items.map { it["sessionId"] })
        assertEquals(listOf("trip-b"), second.items.map { it["sessionId"] })
    }

    /**
     * A cursor is a position, not a row.
     *
     * Retention deletes routes with their sessions, and the phone's cursor
     * then names a row that is gone. Refusing it would make the phone reset
     * the stream and take every route on the car again to recover from one
     * deletion, so the position is honoured and the reading carries on.
     */
    @Test
    fun `a cursor naming a deleted route still says where the reading stopped`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L))
        trackDao.upsert(track("trip-b", updatedAt = 2_000L))
        trackDao.deleteBySessionIds(listOf("trip-a"))

        val batch = packer.packBatch(SyncStreamType.TRACKS.wireName, after = "1000:trip-a")

        assertEquals(listOf("trip-b"), batch.items.map { it["sessionId"] })
    }

    @Test
    fun `a cursor that is not a position at all is refused`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L))

        val thrown = runCatching {
            packer.packBatch(SyncStreamType.TRACKS.wireName, after = "not-a-cursor")
        }.exceptionOrNull()

        assertTrue(thrown is SyncCursorCorruptException)
    }

    @Test
    fun `the count says what is left after the cursor and what there is in all`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L))
        trackDao.upsert(track("trip-b", updatedAt = 2_000L))
        trackDao.upsert(track("trip-c", updatedAt = 3_000L))

        val count = packer.countStream(SyncStreamType.TRACKS.wireName, after = "1000:trip-a")

        assertEquals(3L, count.total)
        assertEquals(2L, count.remaining)
    }

    @Test
    fun `the route stream is counted in the inventory`() {
        assertTrue(packer.countedStreams.contains(SyncStreamType.TRACKS))
    }

    /**
     * A sync stopped mid-stream leaves a shorter history, never a broken one.
     *
     * The cursor only moves on a page the phone confirmed, so the run that
     * follows starts at the last confirmed route and offers every one after
     * it. What the interrupted run took is a prefix of the whole, in order.
     */
    @Test
    fun `an interrupted run resumes at the last route it confirmed`() {
        for (i in 1..5) trackDao.upsert(track("trip-$i", updatedAt = i * 1_000L))

        var cursor: String? = null
        val taken = mutableListOf<String>()
        // Two pages land, then the phone stops.
        repeat(2) {
            val batch = packer.packBatch(SyncStreamType.TRACKS.wireName, after = cursor, limit = 1)
            taken += batch.items.map { it["sessionId"] as String }
            cursor = batch.nextCursor
        }

        val resumed = mutableListOf<String>()
        var hasMore = true
        while (hasMore) {
            val batch = packer.packBatch(SyncStreamType.TRACKS.wireName, after = cursor, limit = 2)
            resumed += batch.items.map { it["sessionId"] as String }
            cursor = batch.nextCursor
            hasMore = batch.hasMore
        }

        assertEquals(listOf("trip-1", "trip-2"), taken)
        assertEquals(listOf("trip-3", "trip-4", "trip-5"), resumed)
    }

    @Test
    fun `the cursor is acknowledged only for a route the car still holds`() {
        trackDao.upsert(track("trip-a", updatedAt = 1_000L))
        val repository = SyncCursorRepository(
            syncCursorDao = InMemorySyncCursorDao(),
            isDevicePaired = { true },
            trackDao = trackDao
        )

        val good = repository.acknowledge(ack("1000:trip-a"), nowUtcMillis = fixedNow)
        val bad = repository.acknowledge(ack("1000:trip-gone"), nowUtcMillis = fixedNow)

        assertTrue(good is SyncAckResult.Applied)
        assertTrue(bad is SyncAckResult.Rejected)
    }

    private fun ack(recordId: String) = SyncAckRequest(
        deviceId = "phone-1",
        streamType = SyncStreamType.TRACKS.wireName,
        recordId = recordId,
        syncedAtHlcMillis = fixedNow - 1_000L,
        syncedAtHlcCounter = 0,
        syncedAtHlcDeviceId = "phone-1",
        success = true
    )

    private fun track(
        sessionId: String,
        updatedAt: Long,
        pointCount: Int = 3
    ) = TrackEntity(
        sessionId = sessionId,
        encodingVersion = 1,
        pointCount = pointCount,
        t = "[0,1000,1000]",
        path = "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        speed = "[0,300,300]",
        alt = "[0,0,0]",
        updatedAtUtcMillis = updatedAt
    )
}

/** In-memory [TrackDao] with the same ordering the query declares. */
class FakeTrackDao : TrackDao {
    private val rows = mutableMapOf<String, TrackEntity>()

    override fun upsert(track: TrackEntity) {
        rows[track.sessionId] = track
    }

    override fun forSession(sessionId: String): TrackEntity? = rows[sessionId]

    override fun forSessions(sessionIds: List<String>): List<TrackEntity> =
        sessionIds.mapNotNull { rows[it] }

    override fun count(): Long = rows.size.toLong()

    override fun countForSession(sessionId: String): Long =
        if (rows.containsKey(sessionId)) 1L else 0L

    override fun deleteBySessionIds(sessionIds: List<String>): Int {
        var removed = 0
        for (id in sessionIds) if (rows.remove(id) != null) removed += 1
        return removed
    }

    override fun deleteOrphans(): Int = 0

    override fun dirtyTracks(limit: Int): List<TrackEntity> = rows.values.filter { it.dirty }.take(limit)
    override fun dirtyTrackCount(): Long = rows.values.count { it.dirty }.toLong()
    override fun clearDirty(ids: List<String>): Int {
        var cleared = 0
        for (id in ids) {
            val track = rows[id]
            if (track != null && track.dirty) {
                rows[id] = track.copy(dirty = false)
                cleared++
            }
        }
        return cleared
    }
    override fun markAllDirty(): Int {
        var marked = 0
        for ((id, track) in rows.toList()) {
            if (!track.dirty) { rows[id] = track.copy(dirty = true); marked++ }
        }
        return marked
    }

    override fun syncPage(
        afterUpdatedAtUtcMillis: Long,
        afterSessionId: String,
        limit: Int
    ): List<TrackEntity> = after(afterUpdatedAtUtcMillis, afterSessionId).take(limit)

    override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String): Long =
        after(afterUpdatedAtUtcMillis, afterSessionId).size.toLong()

    private fun after(updatedAt: Long, sessionId: String): List<TrackEntity> =
        rows.values
            .filter {
                it.updatedAtUtcMillis > updatedAt ||
                    (it.updatedAtUtcMillis == updatedAt && it.sessionId > sessionId)
            }
            .sortedWith(compareBy({ it.updatedAtUtcMillis }, { it.sessionId }))
}
