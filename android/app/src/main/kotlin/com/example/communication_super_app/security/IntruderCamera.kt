package com.example.communication_super_app.security

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.example.communication_super_app.hidden.HiddenNumbers
import com.example.communication_super_app.smscrypto.SealedBox
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * «عکس از ورود ناموفق» (matrix row 32): on every third wrong PIN in a row,
 * one photo from each camera, taken without a preview or a sound, sealed to
 * the secure section's own public key ([SealedBox], the same key the hidden
 * phonebook seals to) and written to `noBackupFilesDir/intruder/`. Only the
 * open section can read them; Dart moves them into `secure.db` (`ip_photos`).
 *
 * A sealed file is `[u32 header length] ‖ header JSON ‖ JPEG` inside the box;
 * the header is `{takenAt, camera, failures}`. When no photo could be taken
 * (no camera permission, camera busy) the attempt is still recorded, with
 * no JPEG, so the report at the next successful entry tells the truth.
 *
 * The report itself — how many failed entries, the last one's time — is
 * kept in plain preferences: it holds no secret and must be readable before
 * the section is opened. The system's camera indicator (Android 12+) may
 * still light up for the second it takes; nothing an app can hide.
 */
object IntruderCamera {
    private const val TAG = "IntruderCamera"
    private const val PREFS = "hamresan_intruder"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_EVENTS = "events"
    private const val KEY_LAST = "last_at"
    private const val DIR = "intruder"

    /** Every this many wrong entries in a row. */
    const val EVERY = 3

    private val random = SecureRandom()
    private val busy = AtomicInteger(0)

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun hasCamera(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    /** `{events, lastAt}` since the report was last shown. */
    fun pendingReport(context: Context): Map<String, Any> = mapOf(
        "events" to prefs(context).getInt(KEY_EVENTS, 0),
        "lastAt" to prefs(context).getLong(KEY_LAST, 0L),
    )

    fun clearReport(context: Context) {
        prefs(context).edit().remove(KEY_EVENTS).remove(KEY_LAST).apply()
    }

    /** A wrong PIN; [failures] in a row so far. */
    fun onWrongPin(context: Context, failures: Int) {
        val app = context.applicationContext
        if (!isEnabled(app) || failures <= 0 || failures % EVERY != 0) return
        val now = System.currentTimeMillis()
        val p = prefs(app)
        p.edit()
            .putInt(KEY_EVENTS, p.getInt(KEY_EVENTS, 0) + 1)
            .putLong(KEY_LAST, now)
            .apply()
        if (busy.getAndIncrement() > 0) {
            busy.decrementAndGet()
            return // still taking the previous pair
        }
        thread(name = "intruder") {
            try {
                capture(app, now, failures)
            } catch (e: Exception) {
                Log.w(TAG, "Capture failed: ${e.javaClass.simpleName}")
            } finally {
                busy.decrementAndGet()
            }
        }
    }

    private fun capture(context: Context, at: Long, failures: Int) {
        val key = HiddenNumbers.sealingKey(context)
        if (key == null) {
            Log.i(TAG, "No secure section key yet; nothing can be sealed")
            return
        }
        val photos = if (hasCamera(context)) shootBoth(context) else emptyMap()
        if (photos.isEmpty()) {
            write(context, key, at, "none", failures, null)
            return
        }
        for ((camera, jpeg) in photos) write(context, key, at, camera, failures, jpeg)
    }

    private fun write(
        context: Context,
        key: com.example.communication_super_app.smscrypto.PublicIdentity,
        at: Long,
        camera: String,
        failures: Int,
        jpeg: ByteArray?,
    ) {
        val header = JSONObject()
            .put("takenAt", at)
            .put("camera", camera)
            .put("failures", failures)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val plain = ByteArrayOutputStream().apply {
            write(header.size ushr 24)
            write(header.size ushr 16)
            write(header.size ushr 8)
            write(header.size)
            write(header)
            if (jpeg != null) write(jpeg)
        }.toByteArray()
        val sealed = SealedBox.seal(key, plain, random)
        val dir = File(context.noBackupFilesDir, DIR).apply { mkdirs() }
        File(dir, "$at-$camera.sealed").writeBytes(sealed)
    }

    /** The sealed files waiting for the section, by name. */
    fun files(context: Context): List<Pair<String, ByteArray>> {
        val dir = File(context.noBackupFilesDir, DIR)
        return dir.listFiles()?.filter { it.name.endsWith(".sealed") }?.sortedBy { it.name }
            ?.mapNotNull { f -> runCatching { f.name to f.readBytes() }.getOrNull() }
            .orEmpty()
    }

    fun delete(context: Context, names: List<String>) {
        val dir = File(context.noBackupFilesDir, DIR)
        for (n in names) {
            if (n.contains('/') || n.contains('\\')) continue
            File(dir, n).delete()
        }
    }

    /** Everything taken (the section was wiped). */
    fun deleteAll(context: Context) {
        File(context.noBackupFilesDir, DIR).deleteRecursively()
        clearReport(context)
    }

    private fun shootBoth(context: Context): Map<String, ByteArray> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val out = LinkedHashMap<String, ByteArray>()
        val ids = try {
            manager.cameraIdList.toList()
        } catch (e: Exception) {
            return out
        }
        for ((facing, name) in listOf(
            CameraCharacteristics.LENS_FACING_FRONT to "front",
            CameraCharacteristics.LENS_FACING_BACK to "back",
        )) {
            val id = ids.firstOrNull {
                runCatching {
                    manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing
                }.getOrDefault(false)
            } ?: continue
            shoot(manager, id)?.let { out[name] = it }
        }
        return out
    }

    /**
     * One JPEG from camera [id]: a short repeating request to let the auto
     * exposure settle, then the newest frame. No preview surface, no shutter
     * sound (Camera2 plays none unless asked).
     */
    @Suppress("DEPRECATION")
    private fun shoot(manager: CameraManager, id: String): ByteArray? {
        val worker = HandlerThread("intruder-camera").apply { start() }
        val handler = Handler(worker.looper)
        val done = CountDownLatch(1)
        var result: ByteArray? = null
        var device: CameraDevice? = null
        var reader: ImageReader? = null
        try {
            val chars = manager.getCameraCharacteristics(id)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return null
            val sizes = map.getOutputSizes(ImageFormat.JPEG) ?: return null
            val size = sizes.filter { it.width <= 1280 && it.height <= 1280 }
                .maxByOrNull { it.width * it.height }
                ?: sizes.minByOrNull { it.width * it.height }
                ?: return null
            val orientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val r = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
            reader = r
            val frames = AtomicInteger(0)
            val started = System.currentTimeMillis()
            r.setOnImageAvailableListener({ source ->
                val image = source.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val n = frames.incrementAndGet()
                    if (result == null && (n >= 6 || System.currentTimeMillis() - started > 1500)) {
                        val buffer = image.planes[0].buffer
                        result = ByteArray(buffer.remaining()).also { buffer.get(it) }
                        done.countDown()
                    }
                } finally {
                    image.close()
                }
            }, handler)
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    device = camera
                    try {
                        camera.createCaptureSession(
                            listOf(r.surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    try {
                                        val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                            .apply {
                                                addTarget(r.surface)
                                                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                                                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                                                set(CaptureRequest.JPEG_ORIENTATION, orientation)
                                                set(CaptureRequest.JPEG_QUALITY, 75.toByte())
                                            }
                                            .build()
                                        session.setRepeatingRequest(request, null, handler)
                                    } catch (e: Exception) {
                                        done.countDown()
                                    }
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    done.countDown()
                                }
                            },
                            handler,
                        )
                    } catch (e: Exception) {
                        done.countDown()
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    done.countDown()
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    done.countDown()
                }
            }, handler)
            done.await(5, TimeUnit.SECONDS)
        } catch (e: SecurityException) {
            Log.i(TAG, "No camera permission")
        } catch (e: Exception) {
            Log.w(TAG, "Camera $id failed: ${e.javaClass.simpleName}")
        } finally {
            runCatching { device?.close() }
            runCatching { reader?.close() }
            worker.quitSafely()
        }
        return result
    }
}
