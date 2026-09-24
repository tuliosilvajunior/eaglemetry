package com.timhss.capyenergy.telemetry.db

import android.database.Cursor
import android.database.SQLException
import android.database.sqlite.SQLiteTransactionListener
import android.os.CancellationSignal
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteQuery
import androidx.sqlite.db.SupportSQLiteStatement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class TelemetryDatabasePreservationUnitTest {

    @Test
    fun restorePreservedPlacesInsertsAllPlacesInTransaction() {
        val fakeDb = FakeSupportSQLiteDatabase()
        val places = listOf(
            InsightPlaceEntity(
                id = "place-1",
                name = "Home",
                latitude = -23.55,
                longitude = -46.63,
                radiusM = 100.0,
                createdAtUtcMillis = 1000L,
                updatedAtUtcMillis = 2000L
            ),
            InsightPlaceEntity(
                id = "place-2",
                name = "Work",
                latitude = -23.56,
                longitude = -46.65,
                radiusM = 150.0,
                createdAtUtcMillis = 3000L,
                updatedAtUtcMillis = 4000L
            )
        )

        TelemetryDatabase.restorePreservedPlaces(fakeDb, places)

        assertTrue(fakeDb.transactionStarted)
        assertTrue(fakeDb.transactionSuccessful)
        assertTrue(fakeDb.transactionEnded)
        assertEquals(2, fakeDb.executedStatements.size)
        assertEquals("place-1", fakeDb.executedStatements[0].second[0])
        assertEquals("Home", fakeDb.executedStatements[0].second[1])
        assertEquals("place-2", fakeDb.executedStatements[1].second[0])
        assertEquals("Work", fakeDb.executedStatements[1].second[1])
    }

    @org.junit.Rule
    @JvmField
    val tempFolder = org.junit.rules.TemporaryFolder()

    @Test
    fun orphanFileForReturnsExpectedPath() {
        val root = tempFolder.root
        val dbFile = java.io.File(root, "geely_telemetry.db")
        val orphan = TelemetryDatabase.orphanFileFor(dbFile, 39)
        assertEquals("geely_telemetry.db.39.orphan", orphan.name)
        assertEquals(dbFile.parentFile, orphan.parentFile)
    }

    @Test
    fun quarantineDowngradedDatabaseMovesMainDbAndSidecars() {
        val root = tempFolder.root
        val dbFile = java.io.File(root, "geely_telemetry.db")
        val walFile = java.io.File(root, "geely_telemetry.db-wal")
        val shmFile = java.io.File(root, "geely_telemetry.db-shm")
        val journalFile = java.io.File(root, "geely_telemetry.db-journal")

        dbFile.writeText("db-content")
        walFile.writeText("wal-content")
        shmFile.writeText("shm-content")
        journalFile.writeText("journal-content")

        val orphan = TelemetryDatabase.quarantineDowngradedDatabase(dbFile, 39)
        org.junit.Assert.assertNotNull(orphan)
        assertEquals("geely_telemetry.db.39.orphan", orphan!!.name)
        assertTrue(orphan.exists())
        assertEquals("db-content", orphan.readText())

        val orphanWal = java.io.File(root, "geely_telemetry.db.39.orphan-wal")
        val orphanShm = java.io.File(root, "geely_telemetry.db.39.orphan-shm")
        val orphanJournal = java.io.File(root, "geely_telemetry.db.39.orphan-journal")

        assertTrue("WAL sidecar must be moved", orphanWal.exists())
        assertEquals("wal-content", orphanWal.readText())

        assertTrue("SHM sidecar must be moved", orphanShm.exists())
        assertEquals("shm-content", orphanShm.readText())

        assertTrue("Journal sidecar must be moved", orphanJournal.exists())
        assertEquals("journal-content", orphanJournal.readText())

        assertTrue("Original db file must no longer exist", !dbFile.exists())
        assertTrue("Original wal file must no longer exist", !walFile.exists())
        assertTrue("Original shm file must no longer exist", !shmFile.exists())
        assertTrue("Original journal file must no longer exist", !journalFile.exists())
    }

    private class FakeSupportSQLiteDatabase : SupportSQLiteDatabase {
        var transactionStarted = false
        var transactionSuccessful = false
        var transactionEnded = false
        val executedStatements = mutableListOf<Pair<String, Array<out Any?>>>()

        override fun beginTransaction() {
            transactionStarted = true
        }

        override fun setTransactionSuccessful() {
            transactionSuccessful = true
        }

        override fun endTransaction() {
            transactionEnded = true
        }

        override fun execSQL(sql: String, bindArgs: Array<out Any?>) {
            executedStatements.add(Pair(sql, bindArgs))
        }

        override fun execSQL(sql: String) {
            executedStatements.add(Pair(sql, emptyArray()))
        }

        override fun compileStatement(sql: String): SupportSQLiteStatement = throw NotImplementedError()
        override fun beginTransactionNonExclusive() = throw NotImplementedError()
        override fun beginTransactionWithListener(transactionListener: SQLiteTransactionListener) = throw NotImplementedError()
        override fun beginTransactionWithListenerNonExclusive(transactionListener: SQLiteTransactionListener) = throw NotImplementedError()
        override fun inTransaction(): Boolean = transactionStarted && !transactionEnded
        override val isDbLockedByCurrentThread: Boolean get() = false
        override fun yieldIfContendedSafely(): Boolean = false
        override fun yieldIfContendedSafely(sleepAmount: Long): Boolean = false
        override var version: Int = 32
        override val maximumSize: Long get() = 0L
        override fun setMaximumSize(numBytes: Long): Long = 0L
        override var pageSize: Long = 0L
        override fun query(query: String): Cursor = throw NotImplementedError()
        override fun query(query: String, bindArgs: Array<out Any?>): Cursor = throw NotImplementedError()
        override fun query(query: SupportSQLiteQuery): Cursor = throw NotImplementedError()
        override fun query(query: SupportSQLiteQuery, cancellationSignal: CancellationSignal?): Cursor = throw NotImplementedError()
        override fun insert(table: String, conflictAlgorithm: Int, values: android.content.ContentValues): Long = 0L
        override fun delete(table: String, whereClause: String?, whereArgs: Array<out Any?>?): Int = 0
        override fun update(table: String, conflictAlgorithm: Int, values: android.content.ContentValues, whereClause: String?, whereArgs: Array<out Any?>?): Int = 0
        override fun needUpgrade(newVersion: Int): Boolean = false
        override val path: String? get() = null
        override fun setLocale(locale: Locale) {}
        override fun setMaxSqlCacheSize(cacheSize: Int) {}
        override fun setForeignKeyConstraintsEnabled(enable: Boolean) {}
        override fun enableWriteAheadLogging(): Boolean = false
        override fun disableWriteAheadLogging() {}
        override val isWriteAheadLoggingEnabled: Boolean get() = false
        override val attachedDbs: List<android.util.Pair<String, String>>? get() = null
        override val isDatabaseIntegrityOk: Boolean get() = true
        override fun close() {}
        override val isOpen: Boolean get() = true
        override val isReadOnly: Boolean get() = false
    }
}
