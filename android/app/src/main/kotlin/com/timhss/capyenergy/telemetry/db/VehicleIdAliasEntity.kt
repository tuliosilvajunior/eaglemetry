package com.timhss.capyenergy.telemetry.db

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query

/**
 * Maps a retired vehicle id to the canonical one that replaced it.
 *
 * Written when the identity is upgraded — a synthetic id to the real VIN.
 * The rows recorded under the alias keep their own `vehicle_id`: history is
 * never rewritten, and consumers resolve an old id through this table.
 */
@Entity(tableName = "vehicle_id_aliases")
data class VehicleIdAliasEntity(
    @PrimaryKey val aliasId: String,
    val canonicalId: String,
    val createdAtUtcMillis: Long
)

@Dao
interface VehicleIdAliasDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insert(alias: VehicleIdAliasEntity)

    @Query("SELECT * FROM vehicle_id_aliases WHERE aliasId = :aliasId")
    fun find(aliasId: String): VehicleIdAliasEntity?

    @Query("SELECT COUNT(*) FROM vehicle_id_aliases")
    fun count(): Long
}
