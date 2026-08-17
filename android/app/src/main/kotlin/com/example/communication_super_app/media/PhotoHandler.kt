package com.example.communication_super_app.media

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
// The platform ExifInterface, not the AndroidX one: reading a stream is
// supported from API 24 and this module's minSdk is 24, so the extra dependency
// would buy nothing but a longer build.
import android.media.ExifInterface
import android.net.Uri
import android.provider.ContactsContract
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Contact photos: pick one (gallery or camera), then crop/rotate it.
 *
 * **The UI is Dart, the pixels are here.** The crop screen needs to show a big
 * enough image to frame accurately, but a contact photo ends up at
 * [OUTPUT_MAX]; decoding, EXIF-correcting, rotating, cropping and re-encoding
 * are all one `Bitmap` call each here and would be several megabytes of
 * `dart:ui` work and a PNG round-trip on the other side.
 *
 * **Stateless on purpose.** `pick` hands the preview bytes to Dart and forgets
 * them; `crop` takes those bytes back with a rectangle. Keeping the source Uri
 * across the two calls would mean owning a lifetime that survives the activity
 * being recreated behind the camera app — which is exactly when it would leak.
 *
 * **No CAMERA permission is declared, and that is deliberate.** `ACTION_IMAGE_CAPTURE`
 * hands the work to the camera app, which holds its own permission; declaring
 * `android.permission.CAMERA` here would make the platform *require* a grant
 * this app never needs, and every runtime grant in this app goes through
 * `PermissionGate` (see the "no permission-requesting plugins" rule).
 */
class PhotoHandler(private val activity: Activity) {

    companion object {
        private const val TAG = "PhotoHandler"

        // **These must not collide with any other startActivityForResult code in
        // the app**, and one of them did: the camera used to be 9002, which is
        // `SmsHandler.REQUEST_DEFAULT_SMS_ROLE`. `MainActivity.onActivityResult`
        // offers the result to the role handlers first, that one claimed it and
        // returned, and the capture arrived nowhere — the sheet simply closed
        // and the photo never changed, with nothing in the log to say why.
        // 92xx is this handler's block; the roles own 90xx and contact extras
        // 91xx.
        const val REQUEST_GALLERY = 9201
        const val REQUEST_CAMERA = 9202

        /**
         * Longest edge of the image the crop screen works on.
         *
         * Three times the output, so a tight crop still has pixels to spare,
         * and small enough that the JPEG crosses the platform channel twice
         * (out to Dart, back in to crop) without coming near the Binder
         * transaction limit.
         */
        private const val PREVIEW_MAX = 1536

        /**
         * Longest edge of the saved contact photo.
         *
         * `ContactsContract` keeps a small thumbnail inline and a display photo
         * in its own file store; 512 is comfortably above the thumbnail size on
         * every device and well under the display-photo maximum, so nothing
         * re-compresses what is written.
         */
        private const val OUTPUT_MAX = 512
    }

    private var pending: MethodChannel.Result? = null

    /**
     * The file the camera app is told to write into.
     *
     * A fixed path, not a remembered Uri: the camera is a heavyweight activity
     * and the system routinely stops — and may destroy — this one behind it, so
     * anything held only in memory across that round trip is a coin flip. A
     * deterministic path can always be rebuilt on the way back.
     */
    private fun captureFile(): File {
        val dir = File(activity.cacheDir, "contact_photos").apply { mkdirs() }
        return File(dir, "capture.jpg")
    }

    private fun captureUri(): Uri = FileProvider.getUriForFile(
        activity,
        "${activity.packageName}.fileprovider",
        captureFile()
    )

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "pickImage" -> {
                // `source` is optional so the old call site keeps working.
                pick(call.argument<String>("source") ?: "gallery", result)
                return true
            }
            "cropImage" -> {
                crop(call, result)
                return true
            }
            "deleteContactPhoto" -> {
                deletePhoto(call.argument<String>("contactId"), result)
                return true
            }
        }
        return false
    }

    /**
     * Removes every photo row of [contactId]'s raw contacts.
     *
     * `flutter_contacts` cannot do it: setting `contact.photo = null` and
     * updating writes nothing, so «حذف عکس» cleared the avatar on screen and the
     * old picture came straight back on the next read. The provider keeps the
     * photo as an ordinary Data row, and deleting the row is the whole
     * operation.
     */
    private fun deletePhoto(contactId: String?, result: MethodChannel.Result) {
        if (contactId.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENTS", "contactId required", null)
            return
        }
        try {
            val resolver = activity.contentResolver
            // The contact id is the *aggregate*; photo rows hang off the raw
            // contacts underneath it, and a linked contact has several.
            val rawIds = ArrayList<String>()
            resolver.query(
                ContactsContract.RawContacts.CONTENT_URI,
                arrayOf(ContactsContract.RawContacts._ID),
                "${ContactsContract.RawContacts.CONTACT_ID} = ?",
                arrayOf(contactId),
                null
            )?.use { cursor ->
                while (cursor.moveToNext()) rawIds.add(cursor.getString(0))
            }
            if (rawIds.isEmpty()) {
                result.success(false)
                return
            }
            var deleted = 0
            for (rawId in rawIds) {
                deleted += resolver.delete(
                    ContactsContract.Data.CONTENT_URI,
                    "${ContactsContract.Data.RAW_CONTACT_ID} = ? AND " +
                        "${ContactsContract.Data.MIMETYPE} = ?",
                    arrayOf(
                        rawId,
                        ContactsContract.CommonDataKinds.Photo.CONTENT_ITEM_TYPE
                    )
                )
            }
            result.success(deleted > 0)
        } catch (e: Exception) {
            Log.e(TAG, "deleteContactPhoto failed: ${e.message}", e)
            result.error("DELETE_FAILED", e.message, null)
        }
    }

    // ── Picking ───────────────────────────────────────────────────────────

    private fun pick(source: String, result: MethodChannel.Result) {
        // One pick at a time. A stale request is answered with null rather than
        // left dangling — a MethodChannel.Result that is never replied to hangs
        // the Dart future for the life of the process.
        pending?.success(null)
        pending = result
        try {
            if (source == "camera") {
                startCamera()
            } else {
                startGallery()
            }
        } catch (e: Exception) {
            Log.e(TAG, "pick($source) failed: ${e.message}", e)
            pending = null
            result.error("PICK_FAILED", e.message, null)
        }
    }

    private fun startGallery() {
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        activity.startActivityForResult(
            Intent.createChooser(intent, "انتخاب عکس"),
            REQUEST_GALLERY
        )
    }

    private fun startCamera() {
        // One fixed file, overwritten each time: the bytes are read out
        // immediately and the file is only a hand-off buffer, so a fresh name
        // per capture would just accumulate.
        val file = captureFile()
        // Deleted first, so "did the camera write anything?" can be answered by
        // the file's own existence and size on the way back — a stale capture
        // from a previous, cancelled attempt would otherwise be indistinguishable
        // from a fresh one.
        if (file.exists()) file.delete()
        val uri = captureUri()
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            // The camera app is a different process: without this it cannot
            // write to the Uri it was handed.
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        // Resolved, not assumed: a device with no camera app must report that
        // rather than throw ActivityNotFoundException at the user. The manifest
        // carries the matching <queries> entry, or this returns null on
        // targetSdk 30+ even when a camera app is installed.
        if (intent.resolveActivity(activity.packageManager) == null) {
            throw IllegalStateException("NO_CAMERA_APP")
        }
        activity.startActivityForResult(intent, REQUEST_CAMERA)
    }

    /** Returns true when the result belonged to this handler. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_GALLERY && requestCode != REQUEST_CAMERA) {
            return false
        }
        val camera = requestCode == REQUEST_CAMERA
        // Logged at warn so it survives a release build: everything about this
        // path happens in another process, and "nothing came back" has three
        // different causes that look identical from the app's side.
        Log.w(TAG, "photo result camera=$camera code=$resultCode data=${data?.data}")

        val result = pending
        if (result == null) {
            Log.w(TAG, "photo result arrived with no pending request")
            return true
        }
        pending = null

        // `resultCode` is not trusted on the camera path. Several OEM camera
        // apps — Samsung's among them — answer an EXTRA_OUTPUT capture with
        // RESULT_CANCELED (or a null data Intent) *after* writing the file
        // perfectly well, which is why the capture looked like it did nothing.
        // The file the camera was told to write is the source of truth.
        if (camera) {
            val file = captureFile()
            Log.w(TAG, "capture file exists=${file.exists()} size=${file.length()}")
            if (file.length() <= 0) {
                // Nothing was written. That is either a cancelled capture (fine,
                // and silent) or a camera app that reported success and wrote
                // nothing (not fine, and it used to look identical — the sheet
                // simply closed and the photo never changed). The resultCode is
                // the only thing that tells them apart, so it decides which.
                if (resultCode == Activity.RESULT_OK) {
                    result.error("CAPTURE_EMPTY", "دوربین عکسی برنگرداند", null)
                } else {
                    result.success(null)
                }
                return true
            }
        }
        val uri = if (camera) {
            captureUri()
        } else {
            if (resultCode != Activity.RESULT_OK) null else data?.data
        }
        if (uri == null) {
            result.success(null)
            return true
        }
        try {
            val bitmap = decodeUpright(uri, PREVIEW_MAX)
            if (bitmap == null) {
                result.error("DECODE_FAILED", "تصویر خوانده نشد", null)
                return true
            }
            result.success(
                mapOf(
                    "bytes" to encode(bitmap, 90),
                    "width" to bitmap.width,
                    "height" to bitmap.height
                )
            )
        } catch (e: Exception) {
            Log.e(TAG, "decode failed: ${e.message}", e)
            result.error("DECODE_FAILED", e.message, null)
        }
        return true
    }

    // ── Cropping ──────────────────────────────────────────────────────────

    /**
     * Rotates [bytes] by `rotation` degrees, cuts the normalised rectangle out
     * of the **rotated** image and returns a square JPEG at most [OUTPUT_MAX]
     * on a side.
     *
     * The rectangle is normalised (0..1) rather than in pixels because the crop
     * screen works in its own layout units — passing pixels would make the
     * result depend on the preview size Dart happened to be given.
     */
    private fun crop(call: MethodCall, result: MethodChannel.Result) {
        try {
            val bytes = call.argument<ByteArray>("bytes")
            if (bytes == null || bytes.isEmpty()) {
                result.error("INVALID_ARGUMENTS", "bytes required", null)
                return
            }
            val rotation = call.argument<Int>("rotation") ?: 0
            val left = (call.argument<Double>("left") ?: 0.0)
            val top = (call.argument<Double>("top") ?: 0.0)
            val size = (call.argument<Double>("size") ?: 1.0)

            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: run {
                    result.error("DECODE_FAILED", "تصویر خوانده نشد", null)
                    return
                }
            val rotated = rotate(decoded, rotation)

            // Clamped, not trusted: a gesture can hand back a rectangle a pixel
            // outside the bitmap, and `createBitmap` throws on that.
            val side = (size * minOf(rotated.width, rotated.height))
                .toInt()
                .coerceAtLeast(1)
            val maxX = (rotated.width - side).coerceAtLeast(0)
            val maxY = (rotated.height - side).coerceAtLeast(0)
            val x = (left * rotated.width).toInt().coerceIn(0, maxX)
            val y = (top * rotated.height).toInt().coerceIn(0, maxY)
            val cropped = Bitmap.createBitmap(
                rotated,
                x,
                y,
                side.coerceAtMost(rotated.width - x),
                side.coerceAtMost(rotated.height - y)
            )

            val out = if (cropped.width > OUTPUT_MAX) {
                Bitmap.createScaledBitmap(cropped, OUTPUT_MAX, OUTPUT_MAX, true)
            } else {
                cropped
            }
            result.success(encode(out, 88))
        } catch (e: Exception) {
            Log.e(TAG, "crop failed: ${e.message}", e)
            result.error("CROP_FAILED", e.message, null)
        }
    }

    // ── Bitmap helpers ────────────────────────────────────────────────────

    /**
     * Decodes [uri] downscaled to [maxDimen] **with its EXIF orientation already
     * applied**.
     *
     * The EXIF step is not a nicety: a photo taken in portrait is stored by
     * almost every camera as a landscape frame plus an orientation tag, so
     * decoding it raw shows the person lying on their side. The previous
     * version of this code ignored the tag, which is why a camera photo came out
     * rotated and the only fix was to re-take it.
     */
    private fun decodeUpright(uri: Uri, maxDimen: Int): Bitmap? {
        val resolver = activity.contentResolver

        // First pass: bounds only, to pick a sample size.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sample = 1
        val largest = maxOf(bounds.outWidth, bounds.outHeight)
        while (largest / sample > maxDimen * 2) sample *= 2

        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts)
        } ?: return null

        val degrees = exifRotation(uri)
        val upright = rotate(decoded, degrees)

        val scale = maxDimen.toFloat() / maxOf(upright.width, upright.height)
        return if (scale < 1f) {
            Bitmap.createScaledBitmap(
                upright,
                (upright.width * scale).toInt().coerceAtLeast(1),
                (upright.height * scale).toInt().coerceAtLeast(1),
                true
            )
        } else {
            upright
        }
    }

    private fun exifRotation(uri: Uri): Int = try {
        activity.contentResolver.openInputStream(uri)?.use { stream ->
            when (
                ExifInterface(stream).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL
                )
            ) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_270 -> 270
                else -> 0
            }
        } ?: 0
    } catch (e: Exception) {
        // A PNG, a screenshot, a provider that will not re-open the stream:
        // an unreadable tag means "no rotation", never a failed pick.
        Log.d(TAG, "no EXIF for $uri: ${e.message}")
        0
    }

    private fun rotate(bitmap: Bitmap, degrees: Int): Bitmap {
        val normalized = ((degrees % 360) + 360) % 360
        if (normalized == 0) return bitmap
        val matrix = Matrix().apply { postRotate(normalized.toFloat()) }
        return Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true
        )
    }

    private fun encode(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        return out.toByteArray()
    }
}
