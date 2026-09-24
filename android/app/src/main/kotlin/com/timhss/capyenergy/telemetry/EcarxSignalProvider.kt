package com.timhss.capyenergy.telemetry

import android.content.Context
import android.util.Log
import com.timhss.capyenergy.profile.ECARX_ID_TYPE_FUNCTION
import com.timhss.capyenergy.profile.ECARX_ID_TYPE_SENSOR

class EcarxSignalProvider(context: Context) {
    private val appContext = context.applicationContext
    // Keyed by (idType, logicalId): the same logical id can be resolved through
    // different wrapper domains (e.g. FUNCTION vs SENSOR), so idType is part of
    // the identity.
    private val cache = mutableMapOf<Long, WrappedPropertyRef>()

    data class WrappedPropertyRef(
        val logicalId: Int,
        val idType: Int,
        val propertyId: Int,
        val propertyIdObject: Any,
        val propertyIdInterface: Class<*>
    )

    fun resolve(logicalId: Int, idType: Int = ID_TYPE_FUNCTION): WrappedPropertyRef? {
        val cacheKey = (idType.toLong() shl 32) or (logicalId.toLong() and 0xFFFFFFFFL)
        cache[cacheKey]?.let { return it }
        return try {
            val ecarxCar = Class.forName("com.ecarx.xui.adaptapi.car.Car")
            val wrapper = ecarxCar
                .getMethod("createWrapper", Context::class.java)
                .invoke(null, appContext)
                ?: return null

            val iWrapper = Class.forName("com.ecarx.xui.adaptapi.car.IWrapper")
            val propertyIdObject = iWrapper
                .getMethod("getWrappedPropertyId", Integer.TYPE, Integer.TYPE)
                .invoke(wrapper, idType, logicalId)
                ?: return null

            val iPropertyId = Class.forName("com.ecarx.xui.adaptapi.car.IWrapper\$IPropertyId")
            val propertyId = iPropertyId.getMethod("getPropertyId").invoke(propertyIdObject) as? Int
            if (propertyId == null || propertyId == 0) {
                null
            } else {
                WrappedPropertyRef(logicalId, idType, propertyId, propertyIdObject, iPropertyId)
                    .also {
                        cache[cacheKey] = it
                        Log.i(TAG, "Resolved ECARX ${logicalId.toHexPropertyId()} (idType=$idType) to ${propertyId.toHexPropertyId()}")
                    }
            }
        } catch (e: Exception) {
            Log.w(TAG, "ECARX wrapper unavailable for ${logicalId.toHexPropertyId()}: ${e::class.java.simpleName}")
            null
        }
    }

    fun adaptValue(ref: WrappedPropertyRef, value: Any?): Any? {
        if (value !is Int) return value
        return try {
            ref.propertyIdInterface
                .getMethod("getPropertyAdaptValue", Integer.TYPE)
                .invoke(ref.propertyIdObject, value)
        } catch (_: Exception) {
            value
        }
    }

    companion object {
        private const val TAG = "EcarxSignalProvider"
        // com.ecarx.xui.adaptapi.car.IWrapper$WrappedIdType, declared in
        // layer 0 so a profile can name a domain without importing the wrapper.
        const val ID_TYPE_FUNCTION = ECARX_ID_TYPE_FUNCTION
        const val ID_TYPE_SENSOR = ECARX_ID_TYPE_SENSOR
    }
}

