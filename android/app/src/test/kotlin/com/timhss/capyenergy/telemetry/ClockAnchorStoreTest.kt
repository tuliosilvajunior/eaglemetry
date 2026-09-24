package com.timhss.capyenergy.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * T4 truth-source anchor rule.
 *
 * The boot's wall clock is untrusted until two independent sources (or
 * history) agree. Every test below guards one clause of that rule; each was
 * proven red by deleting the clause it protects before being accepted.
 */
class ClockAnchorStoreTest {

    private val store = ClockAnchorStore

    // Fixed instant: Sat 2026-09-12 12:00:00 GMT. Elapsed: 100 s into the boot.
    private val realWall = 1_789_214_400_000L
    private val elapsed = 100_000_000_000L
    private val realOffset = realWall - elapsed / 1_000_000L

    @Before
    fun reset() {
        store.reset()
    }

    @Test
    fun `first valid Date stores the pair but the boot stays pending`() {
        assertTrue(store.offerServerDate(realWall, elapsed))

        val anchor = store.anchor()
        assertEquals(realWall, anchor?.wallMillis)
        assertEquals(elapsed, anchor?.elapsedNanos)
        // One source never leaves PENDING.
        assertFalse(store.isLearned())
    }

    @Test
    fun `shifted Date against reference history is rejected entirely`() {
        store.setReferenceOffset(realOffset)

        assertFalse(store.offerServerDate(realWall + 2 * 3_600_000L, elapsed))
        assertNull(store.anchor())
        assertFalse(store.isLearned())
    }

    @Test
    fun `Date agreeing with reference history learns at once`() {
        store.setReferenceOffset(realOffset)

        assertTrue(store.offerServerDate(realWall + 60_000L, elapsed + 60_000_000_000L))
        assertTrue(store.isLearned())
    }

    @Test
    fun `Date then GPS within 5 minutes learns without history`() {
        assertTrue(store.offerServerDate(realWall, elapsed))
        assertFalse(store.isLearned())

        assertTrue(store.offerGpsFix(realWall + 60_000L, elapsed + 120_000_000_000L))
        assertTrue(store.isLearned())
    }

    @Test
    fun `GPS disagreeing beyond 5 minutes does not learn`() {
        assertTrue(store.offerServerDate(realWall, elapsed))

        assertTrue(store.offerGpsFix(realWall + 10 * 60_000L, elapsed))
        assertFalse(store.isLearned())
    }

    @Test
    fun `corroboration just inside 5 minutes learns`() {
        assertTrue(store.offerServerDate(realWall, elapsed))
        val inside = realWall + ClockAnchorStore.CORROBORATION_TOLERANCE_MILLIS - 1L

        assertTrue(store.offerGpsFix(inside, elapsed))
        assertTrue(store.isLearned())
    }

    @Test
    fun `corroboration just outside 5 minutes does not learn`() {
        assertTrue(store.offerServerDate(realWall, elapsed))
        val outside = realWall + ClockAnchorStore.CORROBORATION_TOLERANCE_MILLIS + 1L

        assertTrue(store.offerGpsFix(outside, elapsed))
        assertFalse(store.isLearned())
    }

    @Test
    fun `corroboration exactly at 5 minutes does not learn`() {
        assertTrue(store.offerServerDate(realWall, elapsed))
        val exactBoundary = realWall + ClockAnchorStore.CORROBORATION_TOLERANCE_MILLIS

        assertTrue(store.offerGpsFix(exactBoundary, elapsed))
        assertFalse(store.isLearned())
    }

    @Test
    fun `GPS then Date within 5 minutes learns without history`() {
        assertTrue(store.offerGpsFix(realWall, elapsed))
        assertFalse(store.isLearned())

        assertTrue(store.offerServerDate(realWall + 60_000L, elapsed + 60_000_000_000L))
        assertTrue(store.isLearned())
    }

    @Test
    fun `second agreeing GPS does not corroborate alone without history`() {
        assertTrue(store.offerGpsFix(realWall, elapsed))
        assertFalse(store.isLearned())

        // Second GPS fix from the same receiver confirms agreement but never leaves PENDING alone:
        assertTrue(store.offerGpsFix(realWall + 1_000L, elapsed + 1_000_000_000L))
        assertFalse(store.isLearned())

        // Independent Date arrives and corroborates:
        assertTrue(store.offerServerDate(realWall + 2_000L, elapsed + 2_000_000_000L))
        assertTrue(store.isLearned())
    }

    @Test
    fun `second agreeing Date does not corroborate alone without history`() {
        assertTrue(store.offerServerDate(realWall, elapsed))
        assertFalse(store.isLearned())

        // Second Date from the same source confirms agreement but never leaves PENDING alone:
        assertTrue(store.offerServerDate(realWall + 30_000L, elapsed + 30_000_000_000L))
        assertFalse(store.isLearned())

        // Independent GPS fix arrives and corroborates:
        assertTrue(store.offerGpsFix(realWall + 40_000L, elapsed + 40_000_000_000L))
        assertTrue(store.isLearned())
    }

    @Test
    fun `shifted Date does not resolve even with repeated calls`() {
        val shiftedWall = realWall + 2 * 3_600_000L
        assertTrue(store.offerServerDate(shiftedWall, elapsed))
        assertFalse(store.isLearned())

        // Repeated shifted calls from the same server never leave PENDING:
        assertTrue(store.offerServerDate(shiftedWall + 30_000L, elapsed + 30_000_000_000L))
        assertFalse(store.isLearned())

        // Real GPS fix arrives: they disagree by 2h (> 5 min), so shifted Date never resolves:
        store.offerGpsFix(realWall + 60_000L, elapsed + 60_000_000_000L)
        assertFalse(store.isLearned())
    }

    @Test
    fun `second disagreeing Date does not corroborate`() {
        assertTrue(store.offerServerDate(realWall, elapsed))

        assertFalse(store.offerServerDate(realWall + 10 * 60_000L, elapsed))
        assertFalse(store.isLearned())
    }

    @Test
    fun `GPS alone never learns without history`() {
        assertTrue(store.offerGpsFix(realWall, elapsed))

        assertFalse(store.isLearned())
    }

    @Test
    fun `GPS agreeing with reference history learns at once`() {
        store.setReferenceOffset(realOffset)

        assertTrue(store.offerGpsFix(realWall, elapsed))
        assertTrue(store.isLearned())
    }

    @Test
    fun `GPS disagreeing with reference history is rejected`() {
        store.setReferenceOffset(realOffset)

        assertFalse(store.offerGpsFix(realWall + 2 * 3_600_000L, elapsed))
        assertNull(store.anchor())
    }

    @Test
    fun `reboot clears the boot anchor and reference so new boot learns cleanly`() {
        store.setReferenceOffset(realOffset)
        assertTrue(store.offerServerDate(realWall, elapsed))
        assertTrue(store.isLearned())

        // Car shuts down, parked for 30 minutes, then boots:
        // Elapsed resets to 5 seconds (drop > 10s signals reboot).
        // The boot state dies, and in-boot reference offset is cleared so
        // it does not poison the new boot.
        val newWall = realWall + 30 * 60 * 1_000L
        val newElapsed = 5_000_000_000L
        assertTrue(store.offerServerDate(newWall, newElapsed))
        assertFalse(store.isLearned())

        // In the new boot, corroborating GPS arrives and learns:
        assertTrue(store.offerGpsFix(newWall + 10_000L, newElapsed + 10_000_000_000L))
        assertTrue(store.isLearned())
        assertEquals(newWall, store.anchor()?.wallMillis)
    }

    @Test
    fun `GPS fix with elapsed slightly behind server date does not trigger false reboot`() {
        val t1 = 100_000_000_000L // 100s
        assertTrue(store.offerServerDate(realWall, t1))

        // GPS fix computed 200ms earlier (normal GNSS latency):
        val tGps = t1 - 200_000_000L // 99.8s
        val gpsWall = realWall - 200L
        assertTrue(store.offerGpsFix(gpsWall, tGps))

        // Corroborates and learns cleanly:
        assertTrue(store.isLearned())
    }

    @Test
    fun `learned anchor never moves within a boot`() {
        store.setReferenceOffset(realOffset)
        assertTrue(store.offerServerDate(realWall, elapsed))
        val first = store.anchor()

        // A later agreeing Date confirms but does not replace the anchor.
        assertTrue(store.offerServerDate(realWall + 5_000L, elapsed + 5_000_000_000L))
        assertEquals(first, store.anchor())
    }

    @Test
    fun `late reference agreeing with a stored Date learns at once`() {
        assertTrue(store.offerServerDate(realWall, elapsed))
        assertFalse(store.isLearned())

        store.setReferenceOffset(realOffset)
        assertTrue(store.isLearned())
    }

    @Test
    fun `late reference disagreeing with a stored Date learns nothing`() {
        assertTrue(store.offerServerDate(realWall + 2 * 3_600_000L, elapsed))

        store.setReferenceOffset(realOffset)
        assertFalse(store.isLearned())
    }

    @Test
    fun `concurrent server Date and GPS fix offers are thread safe and learn`() {
        val threads = mutableListOf<Thread>()
        val errors = AtomicInteger(0)

        for (i in 0 until 50) {
            val t = Thread {
                try {
                    store.offerServerDate(realWall + i * 1_000L, elapsed + i * 1_000_000_000L)
                    store.offerGpsFix(realWall + i * 1_000L + 500L, elapsed + i * 1_000_000_000L + 500_000_000L)
                } catch (_: Exception) {
                    errors.incrementAndGet()
                }
            }
            threads.add(t)
        }

        threads.forEach { it.start() }
        threads.forEach { it.join(5000) }

        assertEquals(0, errors.get())
        assertTrue(store.isLearned())
        assertNotNull(store.anchor())
    }

    // ---- HTTP Date parsing: hostile headers never throw, never resolve ----

    @Test
    fun `parse absent blank and malformed Date yields null`() {
        assertNull(store.parseHttpDateHeader(null))
        assertNull(store.parseHttpDateHeader(""))
        assertNull(store.parseHttpDateHeader("   "))
        assertNull(store.parseHttpDateHeader("not a date"))
        assertNull(store.parseHttpDateHeader("32 Foo 2099 99:99:99"))
    }

    @Test
    fun `parse IMF-fixdate round-trips the instant`() {
        assertEquals(realWall, store.parseHttpDateHeader("Sat, 12 Sep 2026 12:00:00 GMT"))
    }

    @Test
    fun `parse alternate HTTP date formats`() {
        // RFC 850 and asctime: accepted when well-formed, never throwing.
        assertEquals(realWall, store.parseHttpDateHeader("Saturday, 12-Sep-26 12:00:00 GMT"))
        assertEquals(realWall, store.parseHttpDateHeader("Sat Sep 12 12:00:00 2026"))
    }

    @Test
    fun `parse ISO 8601 or invalid timezone yields null`() {
        assertNull(store.parseHttpDateHeader("2026-09-12T12:00:00Z"))
        assertNull(store.parseHttpDateHeader("Sat, 12 Sep 2026 12:00:00 INVALID_TZ"))
    }

    @Test
    fun `parse epoch Date yields null`() {
        assertNull(store.parseHttpDateHeader("Thu, 01 Jan 1970 00:00:00 GMT"))
    }

    // ---- GPS provider wiring: the pair that reaches the store ----

    @Test
    fun `provider fix offers its wall plus elapsed pair`() {
        val provider = LocationSignalProvider(FakeSettingsContext())

        provider.onFixReceived(realWall, elapsed)

        val anchor = store.anchor()
        assertEquals(realWall, anchor?.wallMillis)
        assertEquals(elapsed, anchor?.elapsedNanos)
        assertEquals(ClockAnchorStore.Source.GPS_FIX, anchor?.source)
    }

    @Test
    fun `provider fix without either half is dropped`() {
        val provider = LocationSignalProvider(FakeSettingsContext())

        provider.onFixReceived(0L, elapsed)
        provider.onFixReceived(realWall, 0L)

        assertNull(store.anchor())
    }

    // ---- G1: learn transition callback ----

    @Test
    fun `learn fires the registered listener once`() {
        var calls = 0
        store.onLearned { calls++ }

        store.setReferenceOffset(realOffset)
        assertTrue(store.offerServerDate(realWall + 60_000L, elapsed + 60_000_000_000L))

        assertEquals(1, calls)
    }

    @Test
    fun `listener registered after learning runs immediately`() {
        store.setReferenceOffset(realOffset)
        assertTrue(store.offerServerDate(realWall + 60_000L, elapsed + 60_000_000_000L))

        var calls = 0
        store.onLearned { calls++ }

        assertEquals(1, calls)
    }

    @Test
    fun `date plus gps corroboration fires the listener`() {
        var calls = 0
        store.onLearned { calls++ }

        assertTrue(store.offerServerDate(realWall, elapsed))
        assertEquals(0, calls)
        assertTrue(store.offerGpsFix(realWall + 60_000L, elapsed + 120_000_000_000L))

        assertEquals(1, calls)
    }

    @Test
    fun `reset drops listeners registered before the reboot`() {
        var calls = 0
        store.onLearned { calls++ }
        store.reset()

        store.setReferenceOffset(realOffset)
        assertTrue(store.offerServerDate(realWall + 60_000L, elapsed + 60_000_000_000L))

        assertEquals(0, calls)
    }
}
