package com.example.communication_super_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * One-shot location read for «موقعیت» in the composer's attachment sheet.
 *
 * Deliberately built on the platform `LocationManager` rather than a plugin:
 * the app needs a single coordinate pair on one tap, not a location library,
 * and every plugin here drags in the Kotlin Gradle Plugin the build already
 * warns about.
 *
 * Nothing is stored, nothing is tracked, and the result never leaves the phone
 * except as the text the user chooses to send.
 */
class LocationHandler(private val context: Context) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/location"
        private const val TAG = "LocationHandler"

        /** A fix older than this is stale enough to be somewhere else. */
        private const val MAX_AGE_MS = 2 * 60 * 1000L
    }

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getCurrentLocation" -> getCurrentLocation(result)
                "isLocationEnabled" -> result.success(isLocationEnabled())
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** Location services switched off system-wide — a permission grant cannot
     *  fix that, so the caller says so instead of spinning for ever. */
    private fun isLocationEnabled(): Boolean = try {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    } catch (e: Exception) {
        false
    }

    /**
     * Resolves to `{latitude, longitude, accuracy}`, or an error code the Dart
     * side turns into a Persian message: `PERMISSION_DENIED`,
     * `LOCATION_DISABLED`, `NO_LOCATION`.
     *
     * `getCurrentLocation` (API 30+) asks for a *fresh* fix and is the only
     * call that will turn the radio on; `getLastKnownLocation` is the fallback
     * and is only trusted while it is recent — an hour-old fix from another
     * city is worse than admitting there is none.
     */
    private fun getCurrentLocation(result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("PERMISSION_DENIED", "دسترسی موقعیت داده نشده است", null)
            return
        }
        if (!isLocationEnabled()) {
            result.error("LOCATION_DISABLED", "موقعیت مکانی خاموش است", null)
            return
        }
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = when {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ->
                LocationManager.GPS_PROVIDER
            else -> LocationManager.NETWORK_PROVIDER
        }

        // Answer at most once: a fresh fix arriving after the fallback already
        // replied would crash on a second Result call.
        var replied = false
        fun reply(block: () -> Unit) {
            if (replied) return
            replied = true
            block()
        }

        fun succeed(location: Location) = reply {
            result.success(
                mapOf(
                    "latitude" to location.latitude,
                    "longitude" to location.longitude,
                    "accuracy" to location.accuracy.toDouble(),
                ),
            )
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                lm.getCurrentLocation(
                    provider,
                    CancellationSignal(),
                    context.mainExecutor,
                ) { location ->
                    if (location != null) {
                        succeed(location)
                    } else {
                        lastKnown(lm)?.let(::succeed)
                            ?: reply {
                                result.error(
                                    "NO_LOCATION",
                                    "موقعیت مکانی پیدا نشد",
                                    null,
                                )
                            }
                    }
                }
                return
            }
            lastKnown(lm)?.let(::succeed)
                ?: reply { result.error("NO_LOCATION", "موقعیت مکانی پیدا نشد", null) }
        } catch (e: SecurityException) {
            reply { result.error("PERMISSION_DENIED", e.message, null) }
        } catch (e: Exception) {
            Log.e(TAG, "location read failed: ${e.message}")
            reply { result.error("NO_LOCATION", e.message, null) }
        }
    }

    /** The newest recent fix across providers, or null when they are all stale. */
    private fun lastKnown(lm: LocationManager): Location? = try {
        val now = System.currentTimeMillis()
        listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { now - it.time <= MAX_AGE_MS }
            .maxByOrNull { it.time }
    } catch (e: SecurityException) {
        null
    }
}
