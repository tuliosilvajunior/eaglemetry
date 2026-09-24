package com.timhss.capyenergy.telemetry.db

import com.timhss.capyenergy.telemetry.VehicleIdAliasStore

/**
 * [VehicleIdAliasStore] backed by the Room alias table.
 *
 * A new or re-pointed alias also re-marks that id's sessions dirty, once, here.
 * Those rows were uploaded under the retired id, and the next upload pass
 * rewrites them under the canonical one.
 *
 * Doing it at the alias's birth is what keeps the reconciliation from
 * repeating: the recorded rows keep their own `vehicle_id` (history is never
 * rewritten, see [VehicleIdAliasEntity]), so a per-boot sweep would find them
 * again on every boot and re-upload them forever. An alias whose mapping did
 * not change has already been reconciled, so it marks nothing.
 */
class RoomVehicleIdAliasStore(
    private val dao: VehicleIdAliasDao,
    private val sessionDao: SessionDao
) : VehicleIdAliasStore {
    override fun record(aliasId: String, canonicalId: String, atUtcMillis: Long) {
        val known = dao.find(aliasId)?.canonicalId
        dao.insert(VehicleIdAliasEntity(aliasId = aliasId, canonicalId = canonicalId, createdAtUtcMillis = atUtcMillis))
        if (known != canonicalId) sessionDao.markAliasedSessionsDirty()
    }

    override fun canonicalFor(aliasId: String): String? = dao.find(aliasId)?.canonicalId
}
