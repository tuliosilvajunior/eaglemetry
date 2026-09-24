package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.VehicleIdAliasEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** In-memory [VehicleIdAliasStore]; asserts alias rows without a database. */
private class InMemoryAliasStore : VehicleIdAliasStore {
    val rows = mutableListOf<VehicleIdAliasEntity>()

    override fun record(aliasId: String, canonicalId: String, atUtcMillis: Long) {
        rows.removeAll { it.aliasId == aliasId }
        rows.add(VehicleIdAliasEntity(aliasId = aliasId, canonicalId = canonicalId, createdAtUtcMillis = atUtcMillis))
    }

    override fun canonicalFor(aliasId: String): String? =
        rows.firstOrNull { it.aliasId == aliasId }?.canonicalId
}

// Synthetic fixtures: not a real chassis number or device id.
private const val VIN = "TESTVIN0000000001"
private const val ANDROID_ID = "test-android-id-01"

private fun resolver(
    settings: TelemetrySettings,
    aliases: VehicleIdAliasStore,
    vin: String?,
    androidId: String?,
    sessions: Boolean
): VehicleIdentityResolver = VehicleIdentityResolver(
    settings = settings,
    aliases = aliases,
    identityFile = null,
    vinReader = { vin },
    androidIdProvider = { androidId },
    hasRecordedSessions = { sessions },
    nowUtcMillis = { 1_000L }
)

class VehicleIdentityResolverTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun vinWinsWhenAvailable() {
        val settings = TelemetrySettings(FakeSettingsContext())
        val aliases = InMemoryAliasStore()
        val identity = resolver(settings, aliases, VIN, ANDROID_ID, sessions = false)

        val resolved = identity.bootstrap()

        assertEquals(VIN, resolved)
        assertEquals(VIN, settings.vehicleId())
        assertEquals(VehicleIdAnchor.VIN, settings.vehicleIdAnchor())
    }

    @Test
    fun vinUnreadableThenReadableStillEndsAsVin() {
        val settings = TelemetrySettings(FakeSettingsContext())
        val aliases = InMemoryAliasStore()
        // Boot 1: Car service not up yet; ANDROID_ID carries the identity.
        val boot1 = resolver(settings, aliases, vin = null, androidId = ANDROID_ID, sessions = false)
        val first = boot1.bootstrap()

        assertEquals(ANDROID_ID, first)
        assertEquals(VehicleIdAnchor.ANDROID_ID, settings.vehicleIdAnchor())

        // Boot 2: VIN readable now. The synthetic id is upgraded, never kept.
        val boot2 = resolver(settings, aliases, vin = VIN, androidId = ANDROID_ID, sessions = false)
        val second = boot2.bootstrap()

        assertEquals(VIN, second)
        assertEquals(VIN, settings.vehicleId())
        assertEquals(VehicleIdAnchor.VIN, settings.vehicleIdAnchor())
        assertEquals(VIN, aliases.canonicalFor(ANDROID_ID))
    }

    @Test
    fun reinstallWithoutVinOrFileYieldsSameAndroidId() {
        // Install 1: no VIN, no identity file — ANDROID_ID mints the identity.
        val settings1 = TelemetrySettings(FakeSettingsContext())
        val install1 = resolver(settings1, InMemoryAliasStore(), vin = null, androidId = ANDROID_ID, sessions = false)
        assertEquals(ANDROID_ID, install1.bootstrap())

        // Reinstall wipes settings and the database; ANDROID_ID is unchanged.
        val settings2 = TelemetrySettings(FakeSettingsContext())
        val install2 = resolver(settings2, InMemoryAliasStore(), vin = null, androidId = ANDROID_ID, sessions = false)

        assertEquals(ANDROID_ID, install2.bootstrap())
    }

    @Test
    fun reinstallAdoptsIdentityFileBeforeAndroidId() {
        val filePath = tmp.root.resolve("vehicle_identity")

        // Install 1 leaves the file behind (outside the app sandbox).
        val settings1 = TelemetrySettings(FakeSettingsContext())
        val install1 = VehicleIdentityResolver(
            settings = settings1,
            aliases = InMemoryAliasStore(),
            identityFile = VehicleIdentityFile(filePath),
            vinReader = { null },
            androidIdProvider = { ANDROID_ID },
            hasRecordedSessions = { false },
            nowUtcMillis = { 1_000L }
        )
        assertEquals(ANDROID_ID, install1.bootstrap())
        assertEquals(ANDROID_ID, VehicleIdentityFile(filePath).read())

        // Reinstall: sandbox wiped, file survives and wins over ANDROID_ID.
        val settings2 = TelemetrySettings(FakeSettingsContext())
        val install2 = VehicleIdentityResolver(
            settings = settings2,
            aliases = InMemoryAliasStore(),
            identityFile = VehicleIdentityFile(filePath),
            vinReader = { null },
            androidIdProvider = { "different-device" },
            hasRecordedSessions = { false },
            nowUtcMillis = { 2_000L }
        )

        assertEquals(ANDROID_ID, install2.bootstrap())
        assertEquals(ANDROID_ID, settings2.vehicleId())
        assertEquals(VehicleIdAnchor.FILE, settings2.vehicleIdAnchor())
    }

    @Test
    fun phoneOfferedIdAdoptedOnlyWhenNoIdAndNoSessions() {
        // No id, no sessions: adopted.
        val settings = TelemetrySettings(FakeSettingsContext())
        val identity = resolver(settings, InMemoryAliasStore(), vin = null, androidId = null, sessions = false)

        assertEquals("phone-known-id", identity.adoptOfferedId("phone-known-id"))
        assertEquals("phone-known-id", settings.vehicleId())
        assertEquals(VehicleIdAnchor.OFFERED, settings.vehicleIdAnchor())

        // An id already exists: refused, id unchanged.
        val settings2 = TelemetrySettings(FakeSettingsContext())
        settings2.setVehicleId(ANDROID_ID)
        val identity2 = resolver(settings2, InMemoryAliasStore(), vin = null, androidId = null, sessions = false)

        assertNull(identity2.adoptOfferedId("phone-known-id"))
        assertEquals(ANDROID_ID, settings2.vehicleId())

        // No id, but sessions already recorded: refused.
        val settings3 = TelemetrySettings(FakeSettingsContext())
        val identity3 = resolver(settings3, InMemoryAliasStore(), vin = null, androidId = null, sessions = true)

        assertNull(identity3.adoptOfferedId("phone-known-id"))
        assertNull(settings3.vehicleId())
    }

    @Test
    fun upgradeWritesAliasRowAndNeverRewritesHistory() {
        val settings = TelemetrySettings(FakeSettingsContext())
        settings.setVehicleId(ANDROID_ID)
        settings.setVehicleIdAnchor(VehicleIdAnchor.ANDROID_ID)
        val aliases = InMemoryAliasStore()
        val identity = resolver(settings, aliases, VIN, ANDROID_ID, sessions = true)

        assertEquals(VIN, identity.tryVinUpgrade())

        // Alias row records old → VIN.
        assertEquals(VIN, aliases.canonicalFor(ANDROID_ID))
        assertEquals(1, aliases.rows.size)
        assertEquals(1_000L, aliases.rows.single().createdAtUtcMillis)

        // Settings now carry the VIN; nothing else was renamed.
        assertEquals(VIN, settings.vehicleId())
        assertEquals(VehicleIdAnchor.VIN, settings.vehicleIdAnchor())

        // Re-running the upgrade is idempotent: no duplicate alias, no
        // alias of the VIN to itself.
        assertEquals(VIN, identity.tryVinUpgrade())
        assertEquals(1, aliases.rows.size)
        assertNull(aliases.canonicalFor(VIN))
    }

    @Test
    fun legacyFrozenUuidIsUpgradedWhenVinBecomesReadable() {
        // Pre-fix install: the old minter froze a random UUID with no anchor.
        val settings = TelemetrySettings(FakeSettingsContext())
        val frozen = "3f2b8c1e-9a4d-4c6e-b1f0-2a7d5e9c8b3a"
        settings.setVehicleId(frozen)
        val aliases = InMemoryAliasStore()
        val identity = resolver(settings, aliases, VIN, androidId = null, sessions = true)

        assertEquals(VIN, identity.bootstrap())
        assertEquals(VIN, settings.vehicleId())
        assertEquals(VehicleIdAnchor.VIN, settings.vehicleIdAnchor())
        assertEquals(VIN, aliases.canonicalFor(frozen))
    }

    @Test
    fun unresolvedIdentityStaysNullInsteadOfRandomUuid() {
        // Every anchor fails: no id is invented, caller keeps `unassigned`.
        val settings = TelemetrySettings(FakeSettingsContext())
        val identity = resolver(settings, InMemoryAliasStore(), vin = null, androidId = null, sessions = false)

        assertNull(identity.bootstrap())
        assertNull(settings.vehicleId())
        assertNull(settings.vehicleIdAnchor())
        assertTrue(InMemoryAliasStore().rows.isEmpty())
    }

    @Test
    fun legacyVehicleIdsAreAutoAliasedToCanonicalIdOnBootstrap() {
        val settings = TelemetrySettings(FakeSettingsContext())
        val canonical = "canonical-veh-123"
        settings.setVehicleId(canonical)
        val aliases = InMemoryAliasStore()
        val legacy1 = "legacy-veh-809"
        val legacy2 = "legacy-veh-497"

        val identity = VehicleIdentityResolver(
            settings = settings,
            aliases = aliases,
            identityFile = null,
            vinReader = { null },
            androidIdProvider = { null },
            hasRecordedSessions = { true },
            legacyVehicleIdsProvider = { listOf(legacy1, legacy2, canonical, "unassigned", "") },
            nowUtcMillis = { 1_000L }
        )

        identity.bootstrap()

        assertEquals(canonical, aliases.canonicalFor(legacy1))
        assertEquals(canonical, aliases.canonicalFor(legacy2))
        assertNull(aliases.canonicalFor(canonical))
        assertNull(aliases.canonicalFor("unassigned"))
    }
}
