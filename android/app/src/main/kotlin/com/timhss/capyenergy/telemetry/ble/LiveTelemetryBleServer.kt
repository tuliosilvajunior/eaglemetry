package com.timhss.capyenergy.telemetry.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.ParcelUuid
import android.util.Log
import com.timhss.capyenergy.telemetry.LiveTelemetrySnapshot
import com.timhss.capyenergy.telemetry.sync.CompanionDeviceManager

/**
 * Vehicle-side BLE GATT Server and Advertiser for the Capy Live Telemetry Stream.
 *
 * The vendor Bluetooth stack accepts connections and serves discovery, but never
 * delivers ATT requests to this app, so challenge-response auth over GATT cannot
 * work on this hardware (measured on IHU629G, see issue 101). The stream is
 * therefore a one-way car-to-phone push: snapshots are notified to every connected
 * client as [LiveTelemetryStreamCipher] frames, one frame variant per paired
 * companion secret. Clients keep only the frames that decrypt under their own key.
 */
class LiveTelemetryBleServer(
    private val context: Context,
    companionDeviceManager: CompanionDeviceManager,
    private val pairedSecretCiphers: PairedSecretCiphers = PairedSecretCiphers(companionDeviceManager),
    /**
     * Read at each decision rather than latched, so switching the setting takes
     * hold without restarting the app.
     */
    private val keepBluetoothOn: () -> Boolean = { false }
) {
    private val tag = "CapyBleServer"
    private val connectedAddresses = java.util.concurrent.CopyOnWriteArraySet<String>()

    fun hasConnectedClients(): Boolean = connectedAddresses.isNotEmpty()

    private val bluetoothManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager?.adapter

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var telemetryCharacteristic: BluetoothGattCharacteristic? = null

    @Volatile
    private var running = false

    private var adapterStateReceiver: BroadcastReceiver? = null

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(tag, "BLE advertising started successfully")
        }

        override fun onStartFailure(errorCode: Int) {
            Log.w(tag, "BLE advertising failed with error code: $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val address = device.address ?: return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.i(tag, "BLE client connected: $address")
                connectedAddresses.add(address)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.i(tag, "BLE client disconnected: $address")
                connectedAddresses.remove(address)
                restartAdvertising()
            }
        }
    }

    /**
     * Starts the GATT server and the advertiser, and keeps watching the
     * adapter.
     *
     * The car radio can be switched off and on at any time, and the vendor
     * stack brings nothing back by itself: the server has to open again. The
     * watch stays registered even when the adapter is off at this moment, so
     * a later switch-on still starts the stream.
     */
    @Synchronized
    fun start() {
        watchAdapterState()
        if (running) return
        val adapter = bluetoothAdapter
        if (adapter == null) {
            Log.w(tag, "Bluetooth adapter unavailable; BLE live stream inactive")
            return
        }
        if (!adapter.isEnabled) {
            // The switch-on is asynchronous, so this call does not continue.
            // ACTION_STATE_CHANGED brings start() back when the radio is up,
            // and the watch above is already registered.
            if (!enableAdapterIfAsked(adapter)) {
                Log.w(tag, "Bluetooth adapter disabled; BLE live stream inactive")
            }
            return
        }

        try {
            val server = bluetoothManager?.openGattServer(context, gattServerCallback)
            if (server == null) {
                Log.w(tag, "Failed to open BluetoothGattServer")
                return
            }
            gattServer = server

            val service = BluetoothGattService(
                BleGattUuids.SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY
            )

            // Notify only. A read property would invite an ATT read this app
            // never receives an answer for, and the central would then tear
            // the link down after the 30 s ATT timeout.
            val telemetryChar = BluetoothGattCharacteristic(
                BleGattUuids.CHAR_TELEMETRY_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            val cccd = BluetoothGattDescriptor(
                BleGattUuids.CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            )
            telemetryChar.addDescriptor(cccd)
            service.addCharacteristic(telemetryChar)
            telemetryCharacteristic = telemetryChar

            server.addService(service)

            startAdvertising(adapter)

            running = true
            Log.i(tag, "LiveTelemetryBleServer started successfully")
        } catch (e: SecurityException) {
            Log.w(tag, "Missing Bluetooth permissions to start BLE server", e)
        } catch (e: Exception) {
            Log.e(tag, "Error starting LiveTelemetryBleServer", e)
        }
    }

    @Synchronized
    fun broadcastSnapshot(snapshot: LiveTelemetrySnapshot) {
        val server = gattServer ?: return
        val char = telemetryCharacteristic ?: return
        val addresses = connectedAddresses.toSet()
        if (addresses.isEmpty()) return

        val plaintext = snapshot.toBinaryPayload()
        for (frame in pairedSecretCiphers.framesForPairedSecrets(plaintext)) {
            char.value = frame
            for (address in addresses) {
                notifyOne(server, char, address)
            }
        }
    }

    @Synchronized
    fun stop() {
        unwatchAdapterState()
        stopRadio()
    }

    /**
     * Releases the radio but keeps the adapter watch, so a switch-off can be
     * followed by a switch-on.
     */
    @Synchronized
    private fun stopRadio() {
        if (!running) return
        running = false
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }
        advertiser = null

        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        telemetryCharacteristic = null
        connectedAddresses.clear()
        Log.i(tag, "LiveTelemetryBleServer stopped")
    }

    /**
     * Switches the car radio back on when the reader has asked for it.
     *
     * Returns true when the request was made, not when the radio is up:
     * [BluetoothAdapter.enable] is asynchronous, and the answer arrives as
     * ACTION_STATE_CHANGED. The call is a no-op for a normal app on API 33 and
     * above; it works here because this build carries the platform signature.
     */
    private fun enableAdapterIfAsked(adapter: BluetoothAdapter): Boolean {
        if (!keepBluetoothOn()) return false
        if (adapter.isEnabled) return false
        return try {
            @Suppress("DEPRECATION")
            val requested = adapter.enable()
            Log.i(tag, "Keep Bluetooth on: switch-on requested, accepted=$requested")
            requested
        } catch (e: SecurityException) {
            Log.w(tag, "Keep Bluetooth on: not permitted to switch the radio on", e)
            false
        } catch (e: Exception) {
            Log.w(tag, "Keep Bluetooth on: failed to switch the radio on", e)
            false
        }
    }

    /**
     * Applies the setting the moment the reader changes it, rather than at the
     * next adapter event. Switching it off never switches the radio off: the
     * app took the radio, and giving it back is the driver's call.
     */
    @Synchronized
    fun applyKeepBluetoothOn() {
        val adapter = bluetoothAdapter ?: return
        if (enableAdapterIfAsked(adapter)) return
        if (adapter.isEnabled) start()
    }

    private fun watchAdapterState() {
        if (adapterStateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_ON -> {
                        Log.i(tag, "Bluetooth switched on; restarting BLE live stream")
                        start()
                    }
                    BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                        Log.i(tag, "Bluetooth switched off; releasing BLE live stream")
                        stopRadio()
                        // Only from STATE_OFF. Asking during TURNING_OFF races
                        // the stack and the radio comes back down again.
                        val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                        if (state == BluetoothAdapter.STATE_OFF) {
                            bluetoothAdapter?.let { enableAdapterIfAsked(it) }
                        }
                    }
                }
            }
        }
        try {
            context.registerReceiver(
                receiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
            )
            adapterStateReceiver = receiver
        } catch (e: Exception) {
            Log.w(tag, "Failed to watch Bluetooth adapter state", e)
        }
    }

    private fun unwatchAdapterState() {
        val receiver = adapterStateReceiver ?: return
        try {
            context.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        adapterStateReceiver = null
    }

    /**
     * The vendor stack does not resume LE advertising after a central disconnects,
     * so restart it explicitly. Called from the GATT callback thread.
     */
    private fun restartAdvertising() {
        if (!running) return
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled) return
        startAdvertising(adapter)
    }

    private fun startAdvertising(adapter: BluetoothAdapter) {
        val adv = adapter.bluetoothLeAdvertiser
        if (adv == null) {
            Log.w(tag, "BluetoothLeAdvertiser not supported on this device")
            return
        }
        advertiser = adv
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()

        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(BleGattUuids.SERVICE_UUID))
            .setIncludeDeviceName(true)
            .build()

        try {
            adv.startAdvertising(settings, data, advertiseCallback)
        } catch (e: SecurityException) {
            Log.w(tag, "Missing Bluetooth permissions to advertise", e)
        }
    }

    private fun notifyOne(server: BluetoothGattServer, char: BluetoothGattCharacteristic, address: String) {
        try {
            val device = bluetoothAdapter?.getRemoteDevice(address) ?: return
            server.notifyCharacteristicChanged(device, char, false)
        } catch (e: SecurityException) {
            Log.w(tag, "Security exception while notifying BLE device $address", e)
        } catch (e: Exception) {
            Log.w(tag, "Failed to notify BLE device $address", e)
        }
    }
}
