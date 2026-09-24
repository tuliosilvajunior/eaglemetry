package com.timhss.capyenergy.telemetry.sync

import java.util.concurrent.TimeUnit
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient

/**
 * Shared singleton [OkHttpClient] for cloud uploaders and control plane.
 *
 * Sharing a single [OkHttpClient] ensures that [HttpCloudSink] (telemetry + annotations)
 * and [com.timhss.capyenergy.telemetry.control.HttpPreferenceControlCloud] (Lane C control)
 * share one connection pool with persistent HTTP/1.1 and HTTP/2 multiplexing.
 */
object OkHttpProvider {
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .connectionPool(ConnectionPool(maxIdleConnections = 5, keepAliveDuration = 5, TimeUnit.MINUTES))
            .build()
    }
}
