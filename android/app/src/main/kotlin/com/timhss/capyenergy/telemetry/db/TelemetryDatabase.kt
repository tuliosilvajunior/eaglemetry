package com.timhss.capyenergy.telemetry.db

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.timhss.capyenergy.telemetry.BackfillTrackMigration
import java.io.File

@Database(
    entities = [
        TelemetryEventEntity::class,
        SessionEntity::class,
        IntervalEntity::class,
        BatteryCycleEntity::class,
        BatteryCycleSessionEntity::class,
        SyncCursorEntity::class,
        TripSegmentEntity::class,
        InsightPlaceEntity::class,
        SessionCostEntity::class,
        PreferenceEntity::class,
        PreferenceProposalEntity::class,
        JourneyEntity::class,
        TrackEntity::class,
        VehicleIdAliasEntity::class,
        ClockBadSignatureEntity::class,
        IntervalReplacedKeyEntity::class,
    ],
    version = TelemetryDatabase.SCHEMA_VERSION,
    exportSchema = true
)
abstract class TelemetryDatabase : RoomDatabase() {
    abstract fun telemetryEventDao(): TelemetryEventDao
    abstract fun sessionDao(): SessionDao
    abstract fun intervalDao(): IntervalDao
    abstract fun batteryCycleDao(): BatteryCycleDao
    abstract fun batteryCycleSessionDao(): BatteryCycleSessionDao
    abstract fun syncCursorDao(): SyncCursorDao
    abstract fun tripSegmentDao(): TripSegmentDao
    abstract fun insightPlaceDao(): InsightPlaceDao
    abstract fun sessionCostDao(): SessionCostDao
    abstract fun preferenceDao(): PreferenceDao
    abstract fun preferenceProposalDao(): PreferenceProposalDao
    abstract fun journeyDao(): JourneyDao
    abstract fun trackDao(): TrackDao
    abstract fun vehicleIdAliasDao(): VehicleIdAliasDao
    abstract fun clockBadSignatureDao(): ClockBadSignatureDao
    abstract fun intervalReplacedKeyDao(): IntervalReplacedKeyDao

    companion object {
        const val SCHEMA_VERSION = 48
        private const val TAG = "TelemetryDatabase"
        private const val DB_NAME = "geely_telemetry.db"

        val MIGRATION_31_32 = object : Migration(31, 32) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `telemetry_events` ADD COLUMN `sessionId` TEXT DEFAULT NULL")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_telemetry_events_sessionId_occurredAtUtcMillis` ON `telemetry_events` (`sessionId`, `occurredAtUtcMillis`)")
            }
        }

        val MIGRATION_32_33 = object : Migration(32, 33) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `sample` (" +
                        "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                        "`sessionId` TEXT, " +
                        "`tUtcMillis` INTEGER NOT NULL, " +
                        "`tElapsedNanos` INTEGER NOT NULL, " +
                        "`bootCount` INTEGER, " +
                        "`key` TEXT NOT NULL, " +
                        "`value` REAL, " +
                        "`validity` TEXT NOT NULL, " +
                        "`groupId` TEXT)"
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_sample_sessionId_key_tElapsedNanos_id` ON `sample` (`sessionId`, `key`, `tElapsedNanos`, `id`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_sample_sessionId_key_tUtcMillis_id` ON `sample` (`sessionId`, `key`, `tUtcMillis`, `id`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_sample_groupId` ON `sample` (`groupId`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_sample_tUtcMillis` ON `sample` (`tUtcMillis`)")
                db.execSQL("DROP TABLE IF EXISTS `telemetry_frames`")
            }
        }

        /**
         * The annotation tables land, and the charge cost moves.
         *
         * The cost moves authority, not shape: existing rows are copied into
         * `session_costs`, and the `session` table keeps its three cost
         * columns dead rather than paying a table rebuild. Nothing writes
         * them after this, every read composes the annotation row, and the
         * sweep test proves it. The frozen export row continues to carry
         * both keys because the composition happens at write time.
         */
        val MIGRATION_33_34 = object : Migration(33, 34) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `origin` TEXT NOT NULL DEFAULT 'car'")
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `deletedAtUtcMillis` INTEGER DEFAULT NULL")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `session_costs` (" +
                        "`sessionId` TEXT NOT NULL, " +
                        "`costPerKwh` REAL, " +
                        "`paidAmount` REAL, " +
                        "`costCurrency` TEXT, " +
                        "`updatedAtUtcMillis` INTEGER NOT NULL, " +
                        "`origin` TEXT NOT NULL, " +
                        "PRIMARY KEY(`sessionId`))"
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `preferences` (" +
                        "`scope` TEXT NOT NULL, " +
                        "`key` TEXT NOT NULL, " +
                        "`value` TEXT, " +
                        "`updatedAtUtcMillis` INTEGER NOT NULL, " +
                        "`origin` TEXT NOT NULL, " +
                        "`deletedAtUtcMillis` INTEGER, " +
                        "PRIMARY KEY(`scope`, `key`))"
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `preference_proposals` (" +
                        "`id` TEXT NOT NULL, " +
                        "`key` TEXT NOT NULL, " +
                        "`value` TEXT, " +
                        "`status` TEXT NOT NULL, " +
                        "`proposedAtUtcMillis` INTEGER NOT NULL, " +
                        "`decidedAtUtcMillis` INTEGER, " +
                        "`updatedAtUtcMillis` INTEGER NOT NULL, " +
                        "`origin` TEXT NOT NULL, " +
                        "PRIMARY KEY(`id`))"
                )
                db.execSQL(
                    "INSERT INTO `session_costs` (`sessionId`, `costPerKwh`, `paidAmount`, `costCurrency`, `updatedAtUtcMillis`, `origin`) " +
                        "SELECT `id`, `costPerKwh`, `paidAmount`, `costCurrency`, `updatedAtUtcMillis`, 'car' " +
                        "FROM `session` WHERE `costPerKwh` IS NOT NULL OR `paidAmount` IS NOT NULL"
                )
            }
        }

        /**
         * The journeys table lands, empty on arrival: the phone names them
         * and the car only carries the rows. Same shape as the other
         * annotations: last writer wins, the tombstone deletes.
         */
        val MIGRATION_34_35 = object : Migration(34, 35) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `journeys` (" +
                        "`id` TEXT NOT NULL, " +
                        "`name` TEXT NOT NULL, " +
                        "`startedAtUtcMillis` INTEGER NOT NULL, " +
                        "`endedAtUtcMillis` INTEGER NOT NULL, " +
                        "`note` TEXT, " +
                        "`createdAtUtcMillis` INTEGER NOT NULL, " +
                        "`updatedAtUtcMillis` INTEGER NOT NULL, " +
                        "`accountId` TEXT, " +
                        "`origin` TEXT NOT NULL, " +
                        "`deletedAtUtcMillis` INTEGER, " +
                        "PRIMARY KEY(`id`))"
                )
            }
        }

        /**
         * InsightPlace gains autoName suggested by the companion Nominatim
         * gateway. Additive nullable columns, no data loss.
         */
        val MIGRATION_35_36 = object : Migration(35, 36) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `autoName` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `autoNameUpdatedAtUtcMillis` INTEGER DEFAULT NULL")
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `autoNameSource` TEXT DEFAULT NULL")
            }
        }

        /**
         * Interval gains startSoc and endSoc to record state-of-charge boundaries.
         * Additive nullable columns, no data loss.
         */
        val MIGRATION_36_37 = object : Migration(36, 37) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `startSoc` REAL DEFAULT NULL")
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `endSoc` REAL DEFAULT NULL")
            }
        }

        /**
         * The Track lands beside the position Samples, and the Session gains
         * the three numbers a reader had to walk the series for.
         *
         * Expand half of issue 173: `sample` keeps writing position rows and
         * nothing reads `track` yet, so the two sources sit side by side and
         * either can be checked against the other.
         *
         * `climbM`, `descentM` and `fixCount` are summed from the *raw* points
         * at close, before simplification. Simplification drops points, and
         * with them altitude the vehicle really climbed, so a reader deriving
         * the climb from the stored path would get a smaller number than the
         * drive measured. That is why these are columns and not a query.
         */
        val MIGRATION_37_38 = object : Migration(37, 38) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `track` (" +
                        "`sessionId` TEXT NOT NULL, " +
                        "`encodingVersion` INTEGER NOT NULL, " +
                        "`pointCount` INTEGER NOT NULL, " +
                        "`t` TEXT NOT NULL, " +
                        "`path` TEXT NOT NULL, " +
                        "`speed` TEXT NOT NULL, " +
                        "`alt` TEXT NOT NULL, " +
                        "PRIMARY KEY(`sessionId`))"
                )
                db.execSQL("ALTER TABLE `session` ADD COLUMN `climbM` REAL DEFAULT NULL")
                db.execSQL("ALTER TABLE `session` ADD COLUMN `descentM` REAL DEFAULT NULL")
                db.execSQL("ALTER TABLE `session` ADD COLUMN `fixCount` INTEGER DEFAULT NULL")
            }
        }

        /**
         * The Track earns the write stamp the sync pages over.
         *
         * Existing rows default to zero rather than to now. Zero is the front
         * of the queue, so every route already recorded is offered to the
         * phone on the first run after the update, which is the answer that
         * loses nothing. A stamp of now would put them behind a cursor a
         * phone may already hold, and those routes would never cross.
         */
        val MIGRATION_38_39 = object : Migration(38, 39) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "ALTER TABLE `track` ADD COLUMN `updatedAtUtcMillis` " +
                        "INTEGER NOT NULL DEFAULT 0"
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS " +
                        "`index_track_updatedAtUtcMillis_sessionId` " +
                        "ON `track` (`updatedAtUtcMillis`, `sessionId`)"
                )
            }
        }

        /**
         * Interval gains startVoltage and endVoltage to record pack voltage boundaries.
         * Additive nullable columns, no data loss.
         */
        val MIGRATION_39_40 = object : Migration(39, 40) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `startVoltage` REAL DEFAULT NULL")
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `endVoltage` REAL DEFAULT NULL")
            }
        }

        /**
         * The Sample stream dies, and the routes it carried move onto Track.
         *
         * Sessions recorded before issue 184 have `sample` rows for their
         * position tuple but no Track row. The backfill turns those rows into
         * one Track row per session and stamps climb/descent/fixCount, then
         * the table is dropped. Without it the reader would lose every
         * pre-184 route, which is exactly what issue 221 exists to prevent.
         */
        val MIGRATION_40_41 = object : Migration(40, 41) {
            override fun migrate(db: SupportSQLiteDatabase) {
                BackfillTrackMigration.run(db)
                db.execSQL("DROP TABLE IF EXISTS `sample`")
            }
        }

        /**
         * Adds the vehicle id alias table. Written when the vehicle identity
         * is upgraded — a synthetic id to the real VIN — so history recorded
         * under the old id can be resolved without rewriting any row.
         */
        val MIGRATION_41_42 = object : Migration(41, 42) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `vehicle_id_aliases` (" +
                        "`aliasId` TEXT NOT NULL, " +
                        "`canonicalId` TEXT NOT NULL, " +
                        "`createdAtUtcMillis` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`aliasId`))"
                )
            }
        }

        /**
         * Every measurement row owes the cloud a mark of whether it has been
         * uploaded. Nothing recorded before this version ever reached the
         * cloud, so the column lands NOT NULL DEFAULT 1 and each of the five
         * historical tables reads dirty. The companion carries the identical
         * mark on its five tables (`companion_database.dart`,
         * `oldVersion < 6`); the car spells it the same way.
         *
         * `ALTER TABLE ... ADD COLUMN` with a constant default is
         * metadata-only in SQLite: no row is rewritten, no table is copied.
         */
        val MIGRATION_42_43 = object : Migration(42, 43) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `session` ADD COLUMN `dirty` INTEGER NOT NULL DEFAULT 1")
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `dirty` INTEGER NOT NULL DEFAULT 1")
                db.execSQL("ALTER TABLE `telemetry_events` ADD COLUMN `dirty` INTEGER NOT NULL DEFAULT 1")
                db.execSQL("ALTER TABLE `track` ADD COLUMN `dirty` INTEGER NOT NULL DEFAULT 1")
                db.execSQL("ALTER TABLE `battery_cycles` ADD COLUMN `dirty` INTEGER NOT NULL DEFAULT 1")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_session_dirty_id` ON `session` (`dirty`, `id`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_interval_dirty` ON `interval` (`dirty`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_telemetry_events_dirty_id` ON `telemetry_events` (`dirty`, `id`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_track_dirty_sessionId` ON `track` (`dirty`, `sessionId`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_battery_cycles_dirty_ordinal` ON `battery_cycles` (`dirty`, `ordinal`)")
            }
        }

        /**
         * Every annotation row gets a hybrid logical clock.
         *
         * The wall clock alone loses when a slow device writes causally later
         * than a fast device (report section 3's clock-skew test). The HLC
         * exists in `HlcTimestamp` / `SyncCursorRepository.compareHlc` but
         * annotations still compare `updatedAtUtcMillis` — this step only
         * stores the clock, and 6b will switch the comparison.
         *
         * New columns land NOT NULL DEFAULT 0 / '' (metadata-only ALTER) and
         * every existing row is then backfilled to `hlcMillis = updatedAtUtcMillis`,
         * `hlcCounter = 0`, `hlcDeviceId = origin`. That is a sensible stamp:
         * a row written before clocks were tracked still sorts by its wall time,
         * with a counter of zero and its own origin as the device, so a future
         * wall-clock comparison would have ordered it the same way. No data is
         * rewritten beyond the stamp.
         */
        val MIGRATION_43_44 = object : Migration(43, 44) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `hlcMillis` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `hlcCounter` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `insight_places` ADD COLUMN `hlcDeviceId` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `session_costs` ADD COLUMN `hlcMillis` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `session_costs` ADD COLUMN `hlcCounter` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `session_costs` ADD COLUMN `hlcDeviceId` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `preferences` ADD COLUMN `hlcMillis` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `preferences` ADD COLUMN `hlcCounter` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `preferences` ADD COLUMN `hlcDeviceId` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `preference_proposals` ADD COLUMN `hlcMillis` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `preference_proposals` ADD COLUMN `hlcCounter` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `preference_proposals` ADD COLUMN `hlcDeviceId` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `journeys` ADD COLUMN `hlcMillis` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `journeys` ADD COLUMN `hlcCounter` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `journeys` ADD COLUMN `hlcDeviceId` TEXT NOT NULL DEFAULT ''")
                // Backfill: a row from before the clock still needs a sensible stamp.
                db.execSQL("UPDATE `insight_places` SET `hlcMillis` = `updatedAtUtcMillis`, `hlcDeviceId` = COALESCE(NULLIF(`origin`, ''), 'car') WHERE `hlcMillis` = 0")
                db.execSQL("UPDATE `session_costs` SET `hlcMillis` = `updatedAtUtcMillis`, `hlcDeviceId` = COALESCE(NULLIF(`origin`, ''), 'car') WHERE `hlcMillis` = 0")
                db.execSQL("UPDATE `preferences` SET `hlcMillis` = `updatedAtUtcMillis`, `hlcDeviceId` = COALESCE(NULLIF(`origin`, ''), 'car') WHERE `hlcMillis` = 0")
                db.execSQL("UPDATE `preference_proposals` SET `hlcMillis` = `updatedAtUtcMillis`, `hlcDeviceId` = COALESCE(NULLIF(`origin`, ''), 'car') WHERE `hlcMillis` = 0")
                db.execSQL("UPDATE `journeys` SET `hlcMillis` = `updatedAtUtcMillis`, `hlcDeviceId` = COALESCE(NULLIF(`origin`, ''), 'car') WHERE `hlcMillis` = 0")
            }
        }

        /**
         * Every interval minute gets its monotonic pair and a time state,
         * and every measurement row gains the account that wrote it.
         *
         * The wall clock lies after a cold boot until time sync lands, but
         * `elapsedRealtimeNanos` does not, so once a trusted wall instant
         * arrives for the boot every earlier minute resolves by exact
         * arithmetic. The pair lands nullable with no backfill: existing
         * rows have no monotonic reading stored anywhere, so they cannot be
         * recovered, and the null says so. `timeState` lands NOT NULL
         * DEFAULT 'unknown': the detector and sweeper own the rest of the
         * vocabulary, and every row starts by admitting it does not know.
         *
         * This is the disk half of `gb236-l1-car-disk-history-on-transfer`
         * (step 1 only: the stamp). The cloud already decides ownership and
         * stamps every row from the device token; the local stamp is the same
         * rule applied on disk, a default-guard and never a competing
         * authority. An existing row or a row written while the car is
         * unpaired carries null, and any account that writes or reads may
         * adopt it — the exact `account_id IS NULL` predicate the cloud's
         * claim backfill proved (PR #281/#282). A row that already carries an
         * account keeps it forever: the stamping code must never re-stamp a
         * full column (session, track, cycle, trip segment) over one that is
         * set, and the event back-stamp must only claim an unowned row. That
         * is what keeps a transfer from ever moving history between accounts
         * on disk. One deliberate exemption: a battery-cycle rebuild
         * (`BatteryCycleRepository`) is a recomputation, not a re-stamp — it
         * deletes and rewrites the derived cycle group under the pairing
         * active at fold time, and is scoped from the resume row forward.
         * Cycles are aggregates, not raw history; the invariant that applies
         * to them is "never re-stamp a row a normal path owns", which the
         * rebuild does not violate because the fold is that path.
         *
         * `battery_cycle_sessions` needs no column: its rows are derived
         * from sessions inside one rebuild transaction, and the cycle whose
         * membership it records is the ownable row.
         *
         * `ALTER TABLE ... ADD COLUMN` with a constant or null default is
         * metadata-only in SQLite: no row is rewritten, no table is copied.
         */
        val MIGRATION_44_45 = object : Migration(44, 45) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `startElapsedNanos` INTEGER DEFAULT NULL")
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `startBootCount` INTEGER DEFAULT NULL")
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `timeState` TEXT NOT NULL DEFAULT 'unknown'")
                db.execSQL("ALTER TABLE `session` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `interval` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `track` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `telemetry_events` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `battery_cycles` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `trip_segments` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `session_costs` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `preferences` ADD COLUMN `accountId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `preference_proposals` ADD COLUMN `accountId` TEXT DEFAULT NULL")
            }
        }

    /**
     * Time authority T6: the consumer contract. Sessions gain `timeState`
     * (NOT NULL DEFAULT 'unknown', the same vocabulary the intervals got in
     * 44_45): the stamp a session is born with says whether its boot had a
     * learned anchor, and the close sweep resolves it. Retention and the
     * uploader read it instead of re-deriving — a pending session is never
     * aged out and never uploaded.
     *
     * `ALTER TABLE ... ADD COLUMN` with a constant default is metadata-only
     * in SQLite: no row is rewritten, no table is copied (same precedent as
     * `MIGRATION_44_45`).
     */
    val MIGRATION_46_47 = object : Migration(46, 47) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE `session` ADD COLUMN `timeState` TEXT NOT NULL DEFAULT 'unknown'")
        }
    }

    /**
     * Time authority T5: the boot-default ledger. One small evidence-backed
     * table; contents come from the detector's structural arms, never from
     * any constant date (plan section 9).
     */
    val MIGRATION_45_46 = object : Migration(45, 46) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS `clock_bad_signatures` (" +
                    "`wallUtcMillis` INTEGER NOT NULL, " +
                    "`firstSeenUtcMillis` INTEGER NOT NULL, " +
                    "`hits` INTEGER NOT NULL, " +
                    "PRIMARY KEY(`wallUtcMillis`))"
            )
        }
    }


    /**
     * Time authority T9: the cloud corrected re-upload. The interval minute
     * records the stamp it was corrected FROM, and the replaced-keys queue
     * names every old wrong key the sweeper rewrote — one per row, two when
     * a collision merged minutes. Both are additive: `ALTER TABLE ... ADD
     * COLUMN` with a constant default is metadata-only in SQLite (same
     * precedent as `MIGRATION_44_45`), and the queue is a fresh empty table.
     */
    val MIGRATION_47_48 = object : Migration(47, 48) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("ALTER TABLE `interval` ADD COLUMN `correctedFromUtcMillis` INTEGER DEFAULT NULL")
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS `interval_replaced_keys` (" +
                    "`sessionId` TEXT NOT NULL, " +
                    "`startUtcMillis` INTEGER NOT NULL, " +
                    "`replacedByUtcMillis` INTEGER NOT NULL, " +
                    "PRIMARY KEY(`sessionId`, `startUtcMillis`))"
            )
        }
    }

        @Volatile
        private var instance: TelemetryDatabase? = null

        fun get(context: Context): TelemetryDatabase =
            instance ?: synchronized(this) {
                instance ?: buildDatabase(context.applicationContext).also { instance = it }
            }

        internal fun setInstanceForTesting(db: TelemetryDatabase?) {
            instance = db
        }

        internal fun buildDatabase(
            appContext: Context,
            dbName: String = DB_NAME,
            targetSchemaVersion: Int = SCHEMA_VERSION
        ): TelemetryDatabase {
            val dbFile = appContext.getDatabasePath(dbName)
            quarantineIfDowngrade(dbFile, targetSchemaVersion)
            val preservedPlaces = readPreservedPlacesBeforeWipe(appContext, dbName, targetSchemaVersion)

            return Room.databaseBuilder(
                appContext,
                TelemetryDatabase::class.java,
                dbName
            )
                .addMigrations(
                    MIGRATION_31_32,
                    MIGRATION_32_33,
                    MIGRATION_33_34,
                    MIGRATION_34_35,
                    MIGRATION_35_36,
                    MIGRATION_36_37,
                    MIGRATION_37_38,
                    MIGRATION_38_39,
                    MIGRATION_39_40,
                    MIGRATION_40_41,
                    MIGRATION_41_42,
                    MIGRATION_42_43,
                    MIGRATION_43_44,
                    MIGRATION_44_45,
                    MIGRATION_45_46,
                    MIGRATION_46_47,
                    MIGRATION_47_48
                )
                .addCallback(object : RoomDatabase.Callback() {
                    override fun onOpen(db: SupportSQLiteDatabase) {
                        super.onOpen(db)
                        if (preservedPlaces.isNotEmpty()) {
                            restorePreservedPlaces(db, preservedPlaces)
                        }
                    }
                })
                .build()
        }

        internal fun readDatabaseVersion(dbFile: File): Int? {
            if (!dbFile.exists() || dbFile.length() == 0L) return null
            return try {
                SQLiteDatabase.openDatabase(
                    dbFile.path,
                    null,
                    SQLiteDatabase.OPEN_READONLY
                ).use { db ->
                    db.version
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to read database version from ${dbFile.path}", e)
                null
            }
        }

        internal fun orphanFileFor(dbFile: File, version: Int): File =
            File(dbFile.parentFile, "${dbFile.name}.$version.orphan")

        internal fun quarantineDowngradedDatabase(dbFile: File, onDiskVersion: Int): File? {
            val orphanFile = orphanFileFor(dbFile, onDiskVersion)
            if (orphanFile.exists()) {
                orphanFile.delete()
            }

            val renamed = dbFile.renameTo(orphanFile)
            if (!renamed) {
                Log.e(TAG, "Failed to rename ${dbFile.path} to ${orphanFile.path}")
                return null
            }

            // Move sidecars (-wal, -shm, -journal) alongside the orphan file
            for (suffix in listOf("-wal", "-shm", "-journal")) {
                val sidecar = File(dbFile.path + suffix)
                if (sidecar.exists()) {
                    val orphanSidecar = File(orphanFile.path + suffix)
                    if (orphanSidecar.exists()) {
                        orphanSidecar.delete()
                    }
                    if (!sidecar.renameTo(orphanSidecar)) {
                        Log.w(TAG, "Failed to rename sidecar ${sidecar.path} to ${orphanSidecar.path}")
                    }
                }
            }

            return orphanFile
        }

        internal fun quarantineIfDowngrade(
            dbFile: File,
            targetSchemaVersion: Int = SCHEMA_VERSION
        ): File? {
            val onDiskVersion = readDatabaseVersion(dbFile) ?: return null
            if (onDiskVersion <= targetSchemaVersion) {
                return null
            }

            Log.w(
                TAG,
                "Database on disk (version $onDiskVersion) is newer than app schema version $targetSchemaVersion. " +
                    "Quarantining ${dbFile.name} to prevent destructive downgrade."
            )

            return quarantineDowngradedDatabase(dbFile, onDiskVersion)
        }

        internal fun readPreservedPlacesBeforeWipe(
            context: Context,
            dbName: String = DB_NAME,
            targetSchemaVersion: Int = SCHEMA_VERSION
        ): List<InsightPlaceEntity> {
            val dbFile = context.getDatabasePath(dbName)
            if (!dbFile.exists() || dbFile.length() == 0L) return emptyList()

            return try {
                SQLiteDatabase.openDatabase(
                    dbFile.path,
                    null,
                    SQLiteDatabase.OPEN_READONLY
                ).use { db ->
                    val version = db.version
                    if (version !in 1 until targetSchemaVersion) {
                        return emptyList()
                    }
                    val places = mutableListOf<InsightPlaceEntity>()
                    val tableCursor = db.rawQuery(
                        "SELECT name FROM sqlite_master WHERE type='table' AND name='insight_places'",
                        null
                    )
                    val tableExists = tableCursor.use { it.moveToFirst() }
                    if (!tableExists) return emptyList()

                    val cursor = db.rawQuery("SELECT * FROM insight_places", null)
                    cursor.use {
                        val idIdx = it.getColumnIndex("id")
                        val nameIdx = it.getColumnIndex("name")
                        val latIdx = it.getColumnIndex("latitude")
                        val lngIdx = it.getColumnIndex("longitude")
                        val radIdx = it.getColumnIndex("radiusM")
                        val crtIdx = it.getColumnIndex("createdAtUtcMillis")
                        val updIdx = it.getColumnIndex("updatedAtUtcMillis")
                        // Absent on databases below schema 34; the preserved
                        // row then re-enters as the car's own.
                        val accIdx = it.getColumnIndex("accountId")
                        val orgIdx = it.getColumnIndex("origin")
                        val delIdx = it.getColumnIndex("deletedAtUtcMillis")
                        val autoIdx = it.getColumnIndex("autoName")
                        val autoUpdIdx = it.getColumnIndex("autoNameUpdatedAtUtcMillis")
                        val autoSrcIdx = it.getColumnIndex("autoNameSource")
                        val hlcMillisIdx = it.getColumnIndex("hlcMillis")
                        val hlcCounterIdx = it.getColumnIndex("hlcCounter")
                        val hlcDeviceIdIdx = it.getColumnIndex("hlcDeviceId")

                        while (it.moveToNext()) {
                            val updatedAt = it.getLong(updIdx)
                            val originVal = if (orgIdx >= 0) (it.getString(orgIdx) ?: "car") else "car"
                            val hlcMillis = if (hlcMillisIdx >= 0 && !it.isNull(hlcMillisIdx)) it.getLong(hlcMillisIdx) else updatedAt
                            val hlcCounter = if (hlcCounterIdx >= 0 && !it.isNull(hlcCounterIdx)) it.getInt(hlcCounterIdx) else 0
                            val hlcDeviceId = if (hlcDeviceIdIdx >= 0 && !it.isNull(hlcDeviceIdIdx)) it.getString(hlcDeviceIdIdx) else originVal
                            places.add(
                                InsightPlaceEntity(
                                    id = it.getString(idIdx),
                                    name = it.getString(nameIdx),
                                    latitude = it.getDouble(latIdx),
                                    longitude = it.getDouble(lngIdx),
                                    radiusM = it.getDouble(radIdx),
                                    createdAtUtcMillis = it.getLong(crtIdx),
                                    updatedAtUtcMillis = updatedAt,
                                    accountId = if (accIdx >= 0) it.getString(accIdx) else null,
                                    origin = originVal,
                                    deletedAtUtcMillis = if (delIdx >= 0 && !it.isNull(delIdx)) it.getLong(delIdx) else null,
                                    autoName = if (autoIdx >= 0) it.getString(autoIdx) else null,
                                    autoNameUpdatedAtUtcMillis = if (autoUpdIdx >= 0 && !it.isNull(autoUpdIdx)) it.getLong(autoUpdIdx) else null,
                                    autoNameSource = if (autoSrcIdx >= 0) it.getString(autoSrcIdx) else null,
                                    hlcMillis = hlcMillis,
                                    hlcCounter = hlcCounter,
                                    hlcDeviceId = hlcDeviceId
                                )
                            )
                        }
                    }
                    Log.i(TAG, "Preserved ${places.size} insight places before destructive migration")
                    places
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to read insight_places prior to destructive migration", e)
                emptyList()
            }
        }

        internal fun restorePreservedPlaces(
            db: SupportSQLiteDatabase,
            places: List<InsightPlaceEntity>
        ) {
            try {
                db.beginTransaction()
                try {
                    for (place in places) {
                        db.execSQL(
                            "INSERT OR REPLACE INTO insight_places (id, name, latitude, longitude, radiusM, createdAtUtcMillis, updatedAtUtcMillis, accountId, origin, deletedAtUtcMillis, autoName, autoNameUpdatedAtUtcMillis, autoNameSource, hlcMillis, hlcCounter, hlcDeviceId) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                            arrayOf<Any?>(
                                place.id,
                                place.name,
                                place.latitude,
                                place.longitude,
                                place.radiusM,
                                place.createdAtUtcMillis,
                                place.updatedAtUtcMillis,
                                place.accountId,
                                place.origin,
                                place.deletedAtUtcMillis,
                                place.autoName,
                                place.autoNameUpdatedAtUtcMillis,
                                place.autoNameSource,
                                place.hlcMillis,
                                place.hlcCounter,
                                place.hlcDeviceId
                            )
                        )
                    }
                    db.setTransactionSuccessful()
                    Log.i(TAG, "Restored ${places.size} insight places after destructive migration")
                } finally {
                    db.endTransaction()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to restore insight places", e)
            }
        }
    }
}
