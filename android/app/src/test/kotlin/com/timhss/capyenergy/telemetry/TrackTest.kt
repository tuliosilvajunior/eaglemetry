package com.timhss.capyenergy.telemetry

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.abs

/**
 * Kotlin codec for the Track, against the shared vectors.
 *
 * Mirrors `packages/telemetry_core/test/track_test.dart`. Every vector in the
 * fixture is asserted here first, so Kotlin is byte-identical to Dart.
 */
class TrackTest {

    private val fixture: JSONObject = loadFixture()
    private val cases: List<JSONObject> = run {
        val arr = fixture.getJSONArray("cases")
        (0 until arr.length()).map { arr.getJSONObject(it) }
    }

    private fun caseNamed(name: String): JSONObject =
        cases.first { it.getString("name") == name }

    private fun pointsOf(c: JSONObject): List<TrackPoint> {
        val arr = c.getJSONArray("points")
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            TrackPoint(
                latitude = o.getDouble("lat"),
                longitude = o.getDouble("lon"),
                tSeconds = o.getDouble("t"),
                speedKmh = o.getDouble("speed"),
                altitudeM = o.getDouble("alt"),
                protected = o.optBoolean("protected", false)
            )
        }
    }

    private fun protectedOf(c: JSONObject): List<Boolean> {
        val arr = c.getJSONArray("protected")
        return (0 until arr.length()).map { arr.getBoolean(it) }
    }

    private fun rowOf(c: JSONObject): TrackRow {
        val enc = c.getJSONObject("encoded")
        return TrackRow(
            encodingVersion = enc.getInt("encoding_version"),
            pointCount = enc.getInt("point_count"),
            t = jsonIntList(enc.getJSONArray("t")),
            path = enc.getString("path"),
            speed = jsonIntList(enc.getJSONArray("speed")),
            alt = jsonIntList(enc.getJSONArray("alt"))
        )
    }

    private fun jsonIntList(arr: org.json.JSONArray): List<Int> =
        (0 until arr.length()).map { arr.getInt(it) }

    // -----------------------------------------------------------------------
    // Shared vectors

    @Test
    fun `declare version 1, the tolerance, and the precision`() {
        assertEquals(TRACK_ENCODING_VERSION, fixture.getInt("encoding_version"))
        assertEquals(TRACK_SIMPLIFY_TOLERANCE_M, fixture.getDouble("tolerance_m"), 1e-9)
        val p = fixture.getJSONObject("precision")
        assertEquals(1e-5, p.getDouble("lat_lon_deg"), 1e-12)
        assertEquals(0.001, p.getDouble("time_seconds"), 1e-12)
        assertEquals(0.1, p.getDouble("speed_kmh"), 1e-12)
        assertEquals(0.1, p.getDouble("altitude_m"), 1e-12)
    }

    @Test
    fun `cover the shapes the format has to survive`() {
        val names = cases.map { it.getString("name") }.toSet()
        assertTrue("empty" in names)
        assertTrue("one_point" in names)
        assertTrue("two_identical_points" in names)
        assertTrue("antimeridian_crossing" in names)
        assertTrue("equator_crossing" in names)
        assertTrue("antimeridian_bend_simplified" in names)
        assertTrue("piecewise_equivalence_protected_cuts" in names)
        assertTrue("piecewise_diverges_off_cut" in names)
    }

    @Test
    fun `every case declares points and protected of the same length`() {
        for (c in cases) {
            val name = c.getString("name")
            assertEquals("$name protected length", pointsOf(c).size, protectedOf(c).size)
        }
    }

    // -----------------------------------------------------------------------
    // Codec

    @Test
    fun `encoding every case reproduces its stored vector`() {
        for (c in cases) {
            val name = c.getString("name")
            val row = TrackCodec.encode(pointsOf(c))
            val stored = rowOf(c)
            assertEquals("$name encodingVersion", stored.encodingVersion, row.encodingVersion)
            assertEquals("$name point_count", stored.pointCount, row.pointCount)
            assertEquals("$name t", stored.t, row.t)
            assertEquals("$name path", stored.path, row.path)
            assertEquals("$name speed", stored.speed, row.speed)
            assertEquals("$name alt", stored.alt, row.alt)
        }
    }

    @Test
    fun `decoding every stored vector returns the points, within precision`() {
        for (c in cases) {
            val name = c.getString("name")
            val points = pointsOf(c)
            val decoded = TrackCodec.decode(rowOf(c))
            assertEquals("$name length", points.size, decoded.size)
            for (i in points.indices) {
                expectWithinPrecision(decoded[i], points[i], "$name point $i")
            }
        }
    }

    @Test
    fun `encode then decode round-trips within precision`() {
        for (c in cases) {
            val name = c.getString("name")
            val points = pointsOf(c)
            val decoded = TrackCodec.decode(TrackCodec.encode(points))
            assertEquals("$name length", points.size, decoded.size)
            for (i in points.indices) {
                expectWithinPrecision(decoded[i], points[i], "$name point $i")
            }
        }
    }

    @Test
    fun `a decoded point never claims protection`() {
        val c = caseNamed("piecewise_equivalence_protected_cuts")
        assertTrue(protectedOf(c).any { it })
        val decoded = TrackCodec.decode(TrackCodec.encode(pointsOf(c)))
        assertTrue("decoded must not carry protection", decoded.all { !it.protected })
    }

    @Test
    fun `a short array fails the decode instead of shifting the map`() {
        val full = TrackCodec.encode(pointsOf(caseNamed("equator_crossing")))
        val shorts = listOf(
            full.copy(t = full.t.dropLast(1)),
            full.copy(speed = full.speed.dropLast(1)),
            full.copy(alt = full.alt.dropLast(1)),
            full.copy(pointCount = full.pointCount + 1)
        )
        for (short in shorts) {
            try {
                TrackCodec.decode(short)
                fail("expected TrackDecodeException for $short")
            } catch (e: TrackDecodeException) {
                // expected
            }
        }
    }

    @Test
    fun `a path holding the wrong number of points fails the decode`() {
        val full = TrackCodec.encode(pointsOf(caseNamed("equator_crossing")))
        val trimmedPath = TrackCodec.encode(pointsOf(caseNamed("equator_crossing")).subList(0, 2)).path
        val trimmed = full.copy(path = trimmedPath)
        try {
            TrackCodec.decode(trimmed)
            fail("expected TrackDecodeException for wrong path count")
        } catch (e: TrackDecodeException) {
            // expected
        }
    }

    @Test
    fun `the decoder refuses a version it does not know`() {
        val full = TrackCodec.encode(pointsOf(caseNamed("equator_crossing")))
        for (v in listOf(0, TRACK_ENCODING_VERSION + 1, 99)) {
            try {
                TrackCodec.decode(full.copy(encodingVersion = v))
                fail("expected TrackDecodeException for version $v")
            } catch (e: TrackDecodeException) {
                // expected
            }
        }
    }

    // -----------------------------------------------------------------------
    // Simplifier

    @Test
    fun `every case simplifies to its stored vector`() {
        for (c in cases) {
            val name = c.getString("name")
            val points = pointsOf(c)
            val kept = TrackSimplifier.simplify(points, protected = protectedOf(c))
            val expected = jsonIntList(c.getJSONArray("simplified_expected"))
            assertEquals("$name simplified_expected", expected, TrackSimplifier.indexesIn(kept, points))
        }
    }

    @Test
    fun `the first and the last point always survive`() {
        for (c in cases) {
            val name = c.getString("name")
            val points = pointsOf(c)
            if (points.isEmpty()) continue
            val kept = TrackSimplifier.simplify(points, protected = protectedOf(c))
            assertEquals("$name first", points.first(), kept.first())
            assertEquals("$name last", points.last(), kept.last())
        }
    }

    @Test
    fun `every protected point survives`() {
        for (c in cases) {
            val name = c.getString("name")
            val points = pointsOf(c)
            val protected = protectedOf(c)
            val kept = TrackSimplifier.simplify(points, protected = protected)
            for (i in points.indices) {
                if (protected[i] || points[i].protected) {
                    assertTrue("$name index $i must survive", kept.contains(points[i]))
                }
            }
        }
    }

    @Test
    fun `a protected list adds to the point flag, it never disarms it`() {
        val flagged = listOf(
            TrackPoint(latitude = 0.0, longitude = 0.0, tSeconds = 0.0, speedKmh = 10.0, altitudeM = 0.0),
            TrackPoint(latitude = 0.0000001, longitude = 0.001, tSeconds = 1.0, speedKmh = 10.0, altitudeM = 0.0, protected = true),
            TrackPoint(latitude = 0.0, longitude = 0.002, tSeconds = 2.0, speedKmh = 10.0, altitudeM = 0.0)
        )
        assertEquals(3, TrackSimplifier.simplify(flagged).size)
        assertEquals(
            3,
            TrackSimplifier.simplify(flagged, protected = listOf(false, false, false)).size
        )
        assertEquals(
            3,
            TrackSimplifier.simplify(
                flagged.map { it.copy(protected = false) },
                protected = listOf(false, true, false)
            ).size
        )
        assertEquals(
            2,
            TrackSimplifier.simplify(flagged.map { it.copy(protected = false) }).size
        )
    }

    @Test
    fun `sections cut on protected indexes join to the whole-path result`() {
        val c = caseNamed("piecewise_equivalence_protected_cuts")
        val points = pointsOf(c)
        val protected = protectedOf(c)
        val cuts = jsonIntList(c.getJSONArray("piecewise_cuts"))
        val whole = TrackSimplifier.simplify(points, protected = protected)
        val joined = TrackSimplifier.simplifyInSections(points, cuts, protected = protected)
        assertEquals(true, c.getBoolean("piecewise_equal"))
        assertEquals(whole, joined)
        assertEquals(
            jsonIntList(c.getJSONArray("simplified_piecewise_expected")),
            TrackSimplifier.indexesIn(joined, points)
        )
        assertTrue(whole.size < points.size)
    }

    @Test
    fun `sections cut anywhere else do not, and the vector says so`() {
        val c = caseNamed("piecewise_diverges_off_cut")
        val points = pointsOf(c)
        val protected = protectedOf(c)
        val cuts = jsonIntList(c.getJSONArray("piecewise_cuts"))
        val whole = TrackSimplifier.simplify(points, protected = protected)
        val joined = TrackSimplifier.simplifyInSections(points, cuts, protected = protected)
        assertEquals(false, c.getBoolean("piecewise_equal"))
        assertTrue(joined != whole)
        assertEquals(
            jsonIntList(c.getJSONArray("simplified_piecewise_expected")),
            TrackSimplifier.indexesIn(joined, points)
        )
        assertTrue(joined.size > whole.size)
    }

    @Test
    fun `a bend on the 180th meridian is measured across the seam`() {
        val c = caseNamed("antimeridian_bend_simplified")
        val points = pointsOf(c)
        val kept = TrackSimplifier.simplify(points)
        assertTrue(kept.size < points.size)
        assertEquals(
            jsonIntList(c.getJSONArray("simplified_expected")),
            TrackSimplifier.indexesIn(kept, points)
        )
        val signs = points.map { kotlin.math.sign(it.longitude) }.toSet()
        assertEquals(2, signs.size)
    }

    @Test
    fun `indexesIn maps by position, so a repeated point is not confused`() {
        val repeated = TrackPoint(latitude = 1.0, longitude = 1.0, tSeconds = 4.0, speedKmh = 0.0, altitudeM = 7.0)
        val other = TrackPoint(latitude = 2.0, longitude = 2.0, tSeconds = 8.0, speedKmh = 0.0, altitudeM = 7.0)
        val all = listOf(repeated, other, repeated)
        assertEquals(repeated, all.first())
        assertEquals(repeated, all.last())
        assertEquals(listOf(0, 1, 2), TrackSimplifier.indexesIn(all, all))
        assertEquals(listOf(0, 2), TrackSimplifier.indexesIn(listOf(repeated, repeated), all))
    }

    // -----------------------------------------------------------------------

    private fun expectWithinPrecision(got: TrackPoint, want: TrackPoint, reason: String) {
        val eps = 1e-9
        assertTrue(
            "$reason lat ${got.latitude} vs ${want.latitude}",
            abs(got.latitude - want.latitude) <= 0.5 / TRACK_POLYLINE_FACTOR + eps
        )
        assertTrue(
            "$reason lon ${got.longitude} vs ${want.longitude}",
            abs(got.longitude - want.longitude) <= 0.5 / TRACK_POLYLINE_FACTOR + eps
        )
        assertTrue(
            "$reason t ${got.tSeconds} vs ${want.tSeconds}",
            abs(got.tSeconds - want.tSeconds) <= 0.5 / TRACK_TIME_FACTOR + eps
        )
        assertTrue(
            "$reason speed ${got.speedKmh} vs ${want.speedKmh}",
            abs(got.speedKmh - want.speedKmh) <= 0.5 / TRACK_SPEED_FACTOR + eps
        )
        assertTrue(
            "$reason alt ${got.altitudeM} vs ${want.altitudeM}",
            abs(got.altitudeM - want.altitudeM) <= 0.5 / TRACK_ALT_FACTOR + eps
        )
    }

    private fun loadFixture(): JSONObject {
        val testdataRoot = System.getProperty("geely.testdata")
        val userDir = System.getProperty("user.dir") ?: "."
        val candidates = listOfNotNull(
            testdataRoot?.let { File(it, "track_cases.json") },
            File(userDir, "testdata/track_cases.json"),
            File(userDir, "../testdata/track_cases.json"),
            File(userDir, "../../testdata/track_cases.json"),
            File(userDir, "src/test/resources/track_cases.json")
        )
        val file = candidates.firstOrNull { it.isFile }
        val content = if (file != null) {
            file.readText(Charsets.UTF_8)
        } else {
            val stream = javaClass.classLoader?.getResourceAsStream("track_cases.json")
            checkNotNull(stream) { "track_cases.json fixture not found in candidates ${candidates.map { it.absolutePath }}" }
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
        }
        return JSONObject(content)
    }
}
