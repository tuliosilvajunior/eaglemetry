package com.timhss.capyenergy.telemetry

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences

/**
 * An in-memory [SharedPreferences] behind a bare [Context].
 *
 * [TelemetrySettings] is a thin reader over preferences, so the interesting
 * behaviour is defaults, keys, and what survives a reopen. A real device or
 * Robolectric adds nothing to that and costs a framework to run it.
 *
 * One store per instance. Two [TelemetrySettings] built on the same instance
 * see the same rows, which is how a reopen is written.
 */
open class FakeSettingsContext : ContextWrapper(null) {
    // System services do not exist on the JVM rig: answer null instead of
    // delegating to the absent base context (which would NPE). Lets tests
    // build objects that only read services in start(), like
    // LocationSignalProvider, without a device or Robolectric.
    override fun getSystemService(name: String): Any? = null

    private val stored = mutableMapOf<String, Any?>()

    override fun getApplicationContext(): Context = this

    override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = prefs

    private val editor = object : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()
        private val removes = mutableSetOf<String>()

        private fun put(key: String, value: Any?): SharedPreferences.Editor {
            if (value == null) {
                removes.add(key)
                pending.remove(key)
            } else {
                removes.remove(key)
                pending[key] = value
            }
            return this
        }

        override fun putString(key: String, value: String?) = put(key, value)
        override fun putStringSet(key: String, values: Set<String>?) = put(key, values)
        override fun putInt(key: String, value: Int) = put(key, value)
        override fun putLong(key: String, value: Long) = put(key, value)
        override fun putFloat(key: String, value: Float) = put(key, value)
        override fun putBoolean(key: String, value: Boolean) = put(key, value)

        override fun remove(key: String): SharedPreferences.Editor {
            removes.add(key)
            pending.remove(key)
            return this
        }

        override fun clear(): SharedPreferences.Editor {
            removes.addAll(stored.keys)
            pending.clear()
            return this
        }

        override fun commit(): Boolean {
            apply()
            return true
        }

        override fun apply() {
            removes.forEach { stored.remove(it) }
            removes.clear()
            stored.putAll(pending)
            pending.clear()
        }
    }

    private val prefs = object : SharedPreferences {
        override fun getAll(): Map<String, *> = stored
        override fun getString(key: String, defValue: String?): String? =
            stored[key] as? String ?: defValue

        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: Set<String>?): Set<String>? =
            stored[key] as? Set<String> ?: defValues

        override fun getInt(key: String, defValue: Int): Int =
            (stored[key] as? Number)?.toInt() ?: defValue

        override fun getLong(key: String, defValue: Long): Long =
            (stored[key] as? Number)?.toLong() ?: defValue

        override fun getFloat(key: String, defValue: Float): Float =
            (stored[key] as? Number)?.toFloat() ?: defValue

        override fun getBoolean(key: String, defValue: Boolean): Boolean =
            stored[key] as? Boolean ?: defValue

        override fun contains(key: String): Boolean = stored.containsKey(key)
        override fun edit(): SharedPreferences.Editor = editor
        override fun registerOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?
        ) = Unit

        override fun unregisterOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?
        ) = Unit
    }
}
