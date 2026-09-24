package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.InsightPlaceEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PlaceDuplicateGuardTest {

    private fun place(
        id: String,
        name: String,
        lat: Double,
        lon: Double,
        deletedAt: Long? = null
    ) = InsightPlaceEntity(
        id = id,
        name = name,
        latitude = lat,
        longitude = lon,
        radiusM = 150.0,
        createdAtUtcMillis = 1000L,
        updatedAtUtcMillis = 1000L,
        deletedAtUtcMillis = deletedAt
    )

    @Test
    fun `same normalized name within 500 m conflicts`() {
        val conflict = PlaceDuplicateGuard.findConflict(
            id = null,
            name = " casa ",
            latitude = -10.181,
            longitude = -48.33,
            live = listOf(place("a", "Casa", -10.18, -48.33))
        )
        assertNotNull(conflict)
        assertEquals("a", conflict!!.row.id)
    }

    @Test
    fun `different name nearby does not conflict`() {
        val conflict = PlaceDuplicateGuard.findConflict(
            id = null,
            name = "Trabalho",
            latitude = -10.1805,
            longitude = -48.3302,
            live = listOf(place("a", "Casa", -10.18, -48.33))
        )
        assertNull(conflict)
    }

    @Test
    fun `same name beyond 500 m does not conflict`() {
        val conflict = PlaceDuplicateGuard.findConflict(
            id = null,
            name = "Casa",
            latitude = -10.185,
            longitude = -48.33,
            live = listOf(place("a", "Casa", -10.18, -48.33))
        )
        assertNull(conflict)
    }

    @Test
    fun `updating the conflicting row by its own id does not conflict`() {
        val conflict = PlaceDuplicateGuard.findConflict(
            id = "a",
            name = "Casa",
            latitude = -10.182,
            longitude = -48.331,
            live = listOf(place("a", "Casa", -10.18, -48.33))
        )
        assertNull(conflict)
    }

    @Test
    fun `tombstoned rows are skipped when callers pass them anyway`() {
        val conflict = PlaceDuplicateGuard.findConflict(
            id = null,
            name = "casa",
            latitude = -10.18,
            longitude = -48.33,
            live = listOf(place("dead", "Casa", -10.1801, -48.33, deletedAt = 5000L))
        )
        assertNull(conflict)
    }

    @Test
    fun `unnamed candidate never conflicts`() {
        val conflict = PlaceDuplicateGuard.findConflict(
            id = null,
            name = "   ",
            latitude = -10.18,
            longitude = -48.33,
            live = listOf(place("a", "", -10.18, -48.33))
        )
        assertNull(conflict)
    }

    @Test
    fun `message names the place, the metres and both ways out`() {
        assertEquals(
            "Ja existe 'Casa' a 111 m — use raio maior ou mescle",
            PlaceDuplicateGuard.conflictMessage(" Casa ", 110.9)
        )
    }
}
