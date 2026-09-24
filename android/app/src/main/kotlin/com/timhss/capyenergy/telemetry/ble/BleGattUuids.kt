package com.timhss.capyenergy.telemetry.ble

import java.util.UUID

/**
 * GATT UUIDs for the Capy Live Telemetry Service.
 *
 * The stream is one-way (car to phone) because the vendor Bluetooth stack of
 * the head unit never delivers ATT requests to this app. Only the telemetry
 * characteristic and its CCCD exist; there is no auth characteristic.
 */
object BleGattUuids {
    val SERVICE_UUID: UUID = UUID.fromString("0000cb01-0000-1000-8000-00805f9b34fb")
    val CHAR_TELEMETRY_UUID: UUID = UUID.fromString("0000cb02-0000-1000-8000-00805f9b34fb")
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
}
