package com.timhss.capyenergy.projection

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel

/**
 * One read-only binder probe: bind a service, ask it one question, read one int.
 *
 * The two protocols differ only in which service and which transaction, so they
 * share this class. Both replies are a single int with the same meaning — see
 * [ProjectionPresenceParser.stateFromReply].
 *
 * P1. This binds and reads. It registers no listener, ever. The session,
 * connection and devicelist services each hold their listener in one field,
 * already occupied by the OEM's own `ConnAdaptor`, and the OEM calls into that
 * listener for audio focus, the microphone, display activity and Bluetooth.
 * Registering ours would not add an observer; it would replace the OEM's and
 * this app implements none of that behaviour.
 *
 * P2. Binding here is not attaching. It never touches the render singleton,
 * which only `notifyMainSurfaceAttached`/`Detached` do, so it carries none of
 * the exposure the CarPlay card's R1 covers and may run before any card exists.
 *
 * Threading: [ensureBound] and [read] block on binder and must run on the
 * caller's worker thread. Only [dispose] is safe from anywhere.
 */
class ProjectionPresenceProbe(
    private val context: Context,
    private val action: String,
    private val servicePackage: String,
    private val descriptor: String,
    private val transaction: Int,
    /** Fired when the binder arrives or dies, so the owner can re-read. */
    private val onBindingChanged: () -> Unit,
) {
    private val lock = Any()

    @Volatile
    private var binder: IBinder? = null
    private var bindingActive = false
    private var disposed = false

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            synchronized(lock) { if (!disposed) binder = service }
            onBindingChanged()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // Keep the binding. BIND_AUTO_CREATE rebinds when the OEM process
            // comes back, and until it does the state is UNKNOWN, not
            // disconnected: a dead service says nothing about the phone.
            synchronized(lock) { binder = null }
            onBindingChanged()
        }

        override fun onNullBinding(name: ComponentName?) {
            synchronized(lock) { binder = null }
            onBindingChanged()
        }
    }

    /** The OEM app declares this service on this head unit. */
    fun available(): Boolean =
        context.packageManager.queryIntentServices(intent(), 0).isNotEmpty()

    fun ensureBound() {
        synchronized(lock) {
            if (disposed || bindingActive || binder != null) return
            val accepted = runCatching {
                context.bindService(intent(), connection, Context.BIND_AUTO_CREATE)
            }.getOrDefault(false)
            bindingActive = accepted
            if (!accepted) {
                // A failed bindService can still leave its registration record.
                runCatching { context.unbindService(connection) }
            }
        }
    }

    /**
     * One transaction. [PresenceState.UNKNOWN] whenever the question could not
     * be asked, which is a different fact from the answer being "no".
     *
     * The reply is read with a raw transaction rather than an AIDL stub. This
     * is the one place in the app where that is the better choice: the Android
     * Auto reply carries a custom parcelable after the int, and replicating its
     * `writeToParcel` layout from decompiled code would risk a silent misparse
     * for an object this app has no use for. The int before it is the whole
     * answer, and everything after it stays unread.
     */
    fun read(): PresenceState {
        val target = binder ?: return PresenceState.UNKNOWN
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(descriptor)
            val delivered = target.transact(transaction, data, reply, 0)
            if (!delivered) {
                PresenceState.UNKNOWN
            } else {
                reply.readException()
                ProjectionPresenceParser.stateFromReply(reply.readInt())
            }
        } catch (t: Throwable) {
            // R9's rule, applied here: a dead or hostile remote never escapes
            // into the app. An unreadable service is an unknown phone.
            PresenceState.UNKNOWN
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    fun dispose() {
        synchronized(lock) {
            if (disposed) return
            disposed = true
            binder = null
            if (bindingActive) {
                bindingActive = false
                runCatching { context.unbindService(connection) }
            }
        }
    }

    private fun intent() = Intent(action).setPackage(servicePackage)
}
