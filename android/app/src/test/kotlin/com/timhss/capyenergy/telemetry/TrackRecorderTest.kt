package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.TrackEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The car recording a drive: raw on every tick, simplified once at close.
 *
 * Issue 178. The codec itself is proven against the shared vectors in
 * [TrackTest]; what is measured here is the recording — that the tick keeps
 * every point, that the close is the only simplification, and that the two
 * cannot be swapped for each other.
 */
class TrackRecorderTest {

    // A drive: north along a meridian, a stop in the middle, then a bend east.
    // Points 20 m apart, which is the band the position evaluator writes on.
    private val base = 1_800_000_000_000L
    private val session = "drive-1"

    /** Metres north of the start, as a latitude. */
    private fun northOf(metres: Double) = START_LAT + metres / 111_320.0

    private fun straightDrive(): List<Fix> {
        val fixes = mutableListOf<Fix>()
        var wall = base
        // 0..9: rolling north at 50 km/h.
        for (i in 0 until 10) {
            fixes.add(Fix(wall, northOf(i * 20.0), START_LON, 100.0 + i, 50.0))
            wall += 1_440L
        }
        // 10..12: standing at the same place for a minute.
        for (i in 0 until 3) {
            fixes.add(Fix(wall, northOf(180.0), START_LON, 109.0, 0.0))
            wall += 20_000L
        }
        // 13..22: rolling again, now bending east.
        for (i in 1..10) {
            fixes.add(
                Fix(
                    wall,
                    northOf(180.0 + i * 14.0),
                    START_LON + i * 14.0 / 74_000.0,
                    109.0 - i,
                    50.0
                )
            )
            wall += 1_440L
        }
        return fixes
    }

    private data class Fix(
        val wallMillis: Long,
        val lat: Double,
        val lon: Double,
        val altM: Double?,
        val speedKmh: Double?
    )

    private fun recorderOver(fixes: List<Fix>, seed: TrackEntity? = null): TrackRecorder {
        val recorder = TrackRecorder()
        recorder.begin(session, base, seed)
        for (f in fixes) {
            recorder.add(session, f.wallMillis, f.lat, f.lon, f.altM, f.speedKmh)
        }
        return recorder
    }

    private fun pathOf(entity: TrackEntity): List<Pair<Double, Double>> =
        TrackCodec.decode(entity.toRow()).map { it.latitude to it.longitude }

    @Test
    fun `the tick writes every point, none simplified`() {
        val fixes = straightDrive()
        val recorder = recorderOver(fixes)

        val raw = recorder.rawRow(session)!!
        assertEquals(fixes.size, raw.pointCount)
        assertEquals(fixes.size, TrackCodec.decode(raw.toRow()).size)
        // The straight run is exactly what simplification exists to remove, so
        // a raw row that still holds it proves the tick did not simplify.
        val closed = recorder.closedRow(session)!!
        assertTrue(
            "the close must drop points the tick kept",
            closed.track.pointCount < raw.pointCount
        )
    }

    @Test
    fun `a drive taken over many ticks closes to one path`() {
        val fixes = straightDrive()

        // One stamp for both closes. The rows carry the moment they were
        // written, and two closes a millisecond apart would differ on that
        // alone — which is not what this test is asking.
        val stamp = 1_700_000_000_000L
        val inOneGo = recorderOver(fixes).closedRow(session, stamp)!!

        // The same drive, asked for its raw row after every point — the tick
        // running as often as it can.
        val piecemeal = TrackRecorder()
        piecemeal.begin(session, base, null)
        for (f in fixes) {
            piecemeal.add(session, f.wallMillis, f.lat, f.lon, f.altM, f.speedKmh)
            piecemeal.rawRow(session, stamp)
        }
        val closed = piecemeal.closedRow(session, stamp)!!

        assertEquals(inOneGo.track, closed.track)
        assertEquals(inOneGo.fixCount, closed.fixCount)
        assertEquals(inOneGo.climbM, closed.climbM, 1e-9)
        assertEquals(inOneGo.descentM, closed.descentM, 1e-9)
    }

    /**
     * The counter-example the ticket asks to be measured rather than assumed.
     *
     * Douglas-Peucker is not incremental. A section cannot know about the bend
     * that follows it, so simplifying each tick's points and joining the
     * results is not the same path as simplifying the drive once.
     */
    @Test
    fun `simplifying on each tick gives a different path`() {
        val fixes = straightDrive()
        val recorder = recorderOver(fixes)
        val raw = TrackCodec.decode(recorder.rawRow(session)!!.toRow())
        val protection = TrackRecorder.protectionFrom(raw)

        val once = TrackSimplifier.simplify(raw, protected = protection)

        // Ticks that cut the drive every five points, which is where a minute
        // tick would land and is not where the stops are.
        val cuts = (0 until raw.size step 5).toMutableList()
        if (cuts.last() != raw.size - 1) cuts.add(raw.size - 1)
        val perTick = TrackSimplifier.simplifyInSections(
            raw,
            cuts,
            protected = protection
        )

        assertNotEquals(
            "the cuts must not fall on protected indexes, or the two agree",
            emptyList<Int>(),
            cuts.filter { !protection.getOrElse(it) { false } && it != 0 && it != raw.size - 1 }
        )
        assertNotEquals("per-tick simplification must diverge", once, perTick)
        assertTrue(
            "joining sections keeps points the whole path drops",
            perTick.size > once.size
        )
    }

    @Test
    fun `the first point, the last point and both ends of the stop survive`() {
        val fixes = straightDrive()
        val closed = recorderOver(fixes).closedRow(session)!!
        val kept = pathOf(closed.track)
        val raw = TrackCodec.decode(recorderOver(fixes).rawRow(session)!!.toRow())

        assertEquals(raw.first().latitude to raw.first().longitude, kept.first())
        assertEquals(raw.last().latitude to raw.last().longitude, kept.last())

        // Index 10 is the reading that first stands; index 13 is the first that
        // moves again. Both name the stop, and a straight line through either
        // would put it somewhere the vehicle never was.
        val protection = TrackRecorder.protectionFrom(raw)
        val stopEnds = protection.indices.filter { protection[it] }
        assertEquals(listOf(10, 13), stopEnds)
        for (i in stopEnds) {
            val p = raw[i]
            assertTrue(
                "the stop end at $i must survive",
                kept.any { abs(it.first - p.latitude) < 1e-6 && abs(it.second - p.longitude) < 1e-6 }
            )
        }
    }

    @Test
    fun `a drive with no speed reading invents no stop`() {
        // Without a bus reading there is nothing to hold, so every point
        // stores zero. Zero reads as standing, which protects the first point
        // — already protected — and must protect nothing else: a drive with no
        // speedometer is not a drive that stopped twenty times.
        val fixes = straightDrive().map { it.copy(speedKmh = null) }
        val raw = TrackCodec.decode(recorderOver(fixes).rawRow(session)!!.toRow())

        val protection = TrackRecorder.protectionFrom(raw)
        assertEquals(listOf(0), protection.indices.filter { protection[it] })
    }

    @Test
    fun `an unmeasured speed holds the last reading, it does not read as stopped`() {
        // A gap in the bus must not become a stop. Storing zero for "not
        // measured" would put a stop end on both sides of every gap, and the
        // route would keep points the vehicle drove straight through.
        val fixes = listOf(
            Fix(base, northOf(0.0), START_LON, 100.0, 50.0),
            Fix(base + 1_000, northOf(20.0), START_LON, 100.0, null),
            Fix(base + 2_000, northOf(40.0), START_LON, 100.0, null),
            Fix(base + 3_000, northOf(60.0), START_LON, 100.0, 50.0)
        )
        val raw = TrackCodec.decode(recorderOver(fixes).rawRow(session)!!.toRow())

        assertEquals(listOf(50.0, 50.0, 50.0, 50.0), raw.map { it.speedKmh })
        assertFalse(TrackRecorder.protectionFrom(raw).any { it })
    }

    @Test
    fun `protection is read off the stored speed, not the speed that arrived`() {
        // 0.549 km/h stores as 0.5, which is standing. Deriving from the
        // double would call it moving, and a restart that reloads the row
        // would then disagree with the recorder that wrote it.
        val fixes = listOf(
            Fix(base, northOf(0.0), START_LON, 100.0, 50.0),
            Fix(base + 1_000, northOf(20.0), START_LON, 100.0, 0.549),
            Fix(base + 2_000, northOf(40.0), START_LON, 100.0, 50.0)
        )
        val raw = TrackCodec.decode(recorderOver(fixes).rawRow(session)!!.toRow())

        assertEquals(listOf(1, 2), TrackRecorder.protectionFrom(raw).indices.filter {
            TrackRecorder.protectionFrom(raw)[it]
        })
    }

    @Test
    fun `a restart mid-drive keeps the route it had already written`() {
        val fixes = straightDrive()
        val half = fixes.size / 2

        val stamp = 1_700_000_000_000L
        val whole = recorderOver(fixes).closedRow(session, stamp)!!

        // The process dies after the tick that wrote the first half.
        val before = recorderOver(fixes.take(half)).rawRow(session, stamp)!!
        val after = TrackRecorder()
        after.begin(session, base, before)
        for (f in fixes.drop(half)) {
            after.add(session, f.wallMillis, f.lat, f.lon, f.altM, f.speedKmh)
        }
        val restarted = after.closedRow(session, stamp)!!

        assertEquals(whole.track, restarted.track)
        assertEquals(whole.fixCount, restarted.fixCount)
        assertEquals(whole.climbM, restarted.climbM, 1e-6)
    }

    @Test
    fun `a restart with no stored row starts the route over rather than failing`() {
        val recorder = TrackRecorder()
        recorder.begin(session, base, null)
        assertNull(recorder.rawRow(session))
        assertEquals(0, recorder.pointCount())
    }

    @Test
    fun `an unreadable stored row is replaced, not trusted`() {
        val broken = TrackEntity(
            sessionId = session,
            encodingVersion = 99,
            pointCount = 3,
            t = "[0,1,2]",
            path = "??",
            speed = "[0,0,0]",
            alt = "[0,0,0]"
        )
        val recorder = TrackRecorder()
        recorder.begin(session, base, broken)

        assertEquals(0, recorder.pointCount())
    }

    @Test
    fun `a fix stamped days from its neighbours is refused`() {
        val recorder = TrackRecorder()
        recorder.begin(session, base, null)

        assertTrue(recorder.add(session, base + 1_000, START_LAT, START_LON, 100.0, 10.0))
        // The 2026-08-14 shape: one frame stamped 448 days back, between
        // frames a second apart. 448 days of millis does not fit the Int the
        // row stores `t` in.
        assertFalse(
            recorder.add(session, base - 448L * 86_400_000L, START_LAT, START_LON, 100.0, 10.0)
        )
        assertFalse(
            recorder.add(session, base + 448L * 86_400_000L, START_LAT, START_LON, 100.0, 10.0)
        )
        assertEquals(1, recorder.pointCount())
    }

    @Test
    fun `a fix for another session is refused`() {
        val recorder = TrackRecorder()
        recorder.begin(session, base, null)

        assertFalse(recorder.add("other", base + 1_000, START_LAT, START_LON, 100.0, 10.0))
        assertNull(recorder.rawRow("other"))
        assertNull(recorder.closedRow("other"))
    }

    @Test
    fun `the climb and the descent are summed before simplification`() {
        val fixes = straightDrive()
        val closed = recorderOver(fixes).closedRow(session)!!

        // 100 -> 109 climbing, 109 -> 99 falling.
        assertEquals(9.0, closed.climbM, 1e-6)
        assertEquals(10.0, closed.descentM, 1e-6)
        assertEquals(fixes.size, closed.fixCount)

        // The same numbers read back off the simplified path would be smaller,
        // which is why they are columns and not a query.
        val kept = TrackCodec.decode(closed.track.toRow())
        assertTrue("simplification dropped points", kept.size < fixes.size)
        assertTrue(
            "the stored path can never report more climb than was measured",
            climbOf(kept) <= closed.climbM + 1e-9
        )
    }

    /**
     * Why the climb is a column and not a query.
     *
     * Douglas-Peucker measures the ground, not the height. A road that runs
     * dead straight over rolling hills simplifies to its two ends, and every
     * metre the vehicle climbed goes with the dropped points.
     */
    @Test
    fun `a straight road over hills loses its climb when simplified`() {
        val fixes = (0 until 12).map { i ->
            Fix(
                base + i * 1_000L,
                northOf(i * 20.0),
                START_LON,
                100.0 + if (i % 2 == 0) 0.0 else 6.0,
                50.0
            )
        }
        val closed = recorderOver(fixes).closedRow(session)!!
        val kept = TrackCodec.decode(closed.track.toRow())

        // Twelve points, six rises and five falls of six metres. Every one of
        // them is inside the straight line, so the stored path is the two ends
        // and reports the difference between them: six metres, not thirty-six.
        assertEquals(2, kept.size)
        assertEquals(36.0, closed.climbM, 1e-6)
        assertEquals(30.0, closed.descentM, 1e-6)
        assertEquals(6.0, climbOf(kept), 1e-9)
    }

    private fun climbOf(points: List<TrackPoint>): Double {
        var total = 0.0
        var previous: Double? = null
        for (p in points) {
            previous?.let { if (p.altitudeM > it) total += p.altitudeM - it }
            previous = p.altitudeM
        }
        return total
    }

    @Test
    fun `the drive opens at the ground, not at sea level`() {
        // The first fixes carry no altitude. Left at zero they would open the
        // drive with a hundred-metre climb the vehicle never made.
        val fixes = listOf(
            Fix(base, northOf(0.0), START_LON, null, 50.0),
            Fix(base + 1_000, northOf(20.0), START_LON, null, 50.0),
            Fix(base + 2_000, northOf(40.0), START_LON, 100.0, 50.0),
            Fix(base + 3_000, northOf(60.0), START_LON, 104.0, 50.0)
        )
        val closed = recorderOver(fixes).closedRow(session)!!

        assertEquals(4.0, closed.climbM, 1e-6)
        assertEquals(0.0, closed.descentM, 1e-6)
    }

    @Test
    fun `a session with no fix has no row`() {
        val recorder = TrackRecorder()
        recorder.begin(session, base, null)

        assertNull(recorder.rawRow(session))
        assertNull(recorder.closedRow(session))
    }

    @Test
    fun `the recorder drops one session when it begins another`() {
        val recorder = recorderOver(straightDrive())
        assertTrue(recorder.pointCount() > 0)

        recorder.begin("drive-2", base, null)

        assertEquals("drive-2", recorder.currentSessionId())
        assertEquals(0, recorder.pointCount())
        assertNull(recorder.rawRow(session))
    }

    @Test
    fun `the stored row round-trips through its JSON arrays`() {
        val stamp = 1_700_000_000_000L
        val entity = recorderOver(straightDrive()).rawRow(session, stamp)!!
        val row = entity.toRow()

        assertEquals(row.pointCount, row.t.size)
        assertEquals(row.pointCount, row.speed.size)
        assertEquals(row.pointCount, row.alt.size)
        assertEquals(entity, TrackCodec.encode(TrackCodec.decode(row)).toEntity(session, stamp))
    }

    // The tick after the close. Nothing tells the recorder a session ended:
    // the held one is replaced only when a fix from the next drive arrives,
    // minutes later. A tick in that window used to hand back the raw row and
    // the caller wrote it over the simplified one the close had stored, so
    // every route on the vehicle stayed raw. Issue 200.

    @Test
    fun `the tick writes the open session`() {
        val recorder = recorderOver(straightDrive())

        assertNotNull(recorder.rawRowWhileOpen(session))
    }

    @Test
    fun `the tick writes nothing once the session it holds has closed`() {
        val recorder = recorderOver(straightDrive())

        assertNull(recorder.rawRowWhileOpen(null))
    }

    @Test
    fun `the tick writes nothing for a session the next drive replaced`() {
        val recorder = recorderOver(straightDrive())

        assertNull(recorder.rawRowWhileOpen("drive-2"))
    }

    @Test
    fun `a closed session is released, not held for the next tick`() {
        val recorder = recorderOver(straightDrive())

        recorder.rawRowWhileOpen(null)

        assertNull(recorder.currentSessionId())
        assertEquals(0, recorder.pointCount())
        // And the release is what stops the raw row coming back: a later tick
        // that names the same session again finds nothing to write.
        assertNull(recorder.rawRowWhileOpen(session))
    }

    @Test
    fun `a released route is read back from the stored row, not lost`() {
        val stored = recorderOver(straightDrive()).rawRow(session)!!
        val recorder = recorderOver(straightDrive())
        recorder.rawRowWhileOpen(null)

        // What a restart, or the next tick of a resumed drive, does.
        recorder.begin(session, base, stored)

        assertEquals(stored, recorder.rawRow(session, stored.updatedAtUtcMillis))
    }

    private companion object {
        const val START_LAT = -23.5
        const val START_LON = -46.6
    }
}
