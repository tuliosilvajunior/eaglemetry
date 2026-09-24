package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.profile.SignalKey
import com.timhss.capyenergy.telemetry.sync.FakeTelemetryEventDao
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// Issue 226: the persistence gate at the database seam.
///
/// [EventPersistencePolicyTest] pins the predicate; this one pins what the
/// issue's Testing Decisions actually ask for — a stream of events fed to
/// [EventRepository.appendEvent] lands only the narrative, lifecycle, and
/// diagnostic rows in the store, while continuous churn stays in the
/// in-memory recent buffer. Room cannot run on the JVM and the repo runs no
/// Robolectric, so the DAO and the write queue come in as fakes through the
/// seams the repository carries for exactly this.
class EventRepositoryPersistenceTest {
    private val dao = FakeTelemetryEventDao()
    private val executor = ObservedWriteExecutor("event_persistence_test")
    private val dir: File = Files.createTempDirectory("event_repo_test").toFile()
    private val repository = EventRepository(
        FakeFilesContext(dir),
        eventDaoOverride = dao,
        writeExecutorOverride = executor,
    )

    private fun event(
        type: TelemetryEventType,
        signalId: SignalKey? = null,
        sessionId: String? = null
    ) = TelemetryEvent(
        id = "e-${System.nanoTime()}",
        type = type,
        timestamp = SignalTimestamp(0L, 0L, null, TimestampAccuracy.RECEIVED_EVENT, 0L),
        signalId = signalId,
        value = "1",
        previousValue = null,
        quality = SignalQuality.MEASURED,
        source = SignalSource.CAN_BRIDGE,
        details = "",
        sessionId = sessionId
    )

    /** The write queue is a background thread; the row arrives a beat later. */
    private fun awaitRows(expected: Int) {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            if (dao.count() >= expected) return
            Thread.sleep(10)
        }
        assertEquals(expected.toLong(), dao.count())
    }

    @Test
    fun `narrative, lifecycle and diagnostic rows reach the database`() {
        repository.appendEvent(event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.GEAR))
        repository.appendEvent(event(TelemetryEventType.TRIP_STARTED))
        repository.appendEvent(
            event(TelemetryEventType.SIGNAL_ERROR, SignalKey.HV_BATTERY_VOLTAGE)
        )

        awaitRows(3)
    }

    @Test
    fun `continuous churn stays out of the database but not out of memory`() {
        val churn = event(TelemetryEventType.SIGNAL_UPDATED, SignalKey.CLIMATE_ON)
        val narrative = event(
            TelemetryEventType.SIGNAL_UPDATED,
            SignalKey.GEAR,
            sessionId = "trip-1"
        )
        repository.appendEvent(churn)
        repository.appendEvent(narrative)

        awaitRows(1)
        assertEquals("trip-1", dao.forSession("trip-1").single().sessionId)
        assertTrue(repository.recent(10).contains(churn))
        assertTrue(repository.recent(10).contains(narrative))
    }
}

/// A context whose only working parts are the ones [EventRepository] reads:
/// itself as its own application context, and a temp directory as filesDir.
class FakeFilesContext(private val dir: File) : FakeSettingsContext() {
    override fun getFilesDir(): File = dir
}
