package com.example.communication_super_app.smscrypto

import android.app.Activity
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Picks a key file (`.hkb`) through the system document picker, over
 * `…/key_file`, and hands its bytes to Dart.
 *
 * `ACTION_OPEN_DOCUMENT` needs **no permission** — the picker grants access
 * to the one file chosen — which is why this is not a plugin (see the "no
 * permission-requesting plugins" rule). The bytes go straight to the key
 * bank; nothing is copied to storage.
 *
 * - `pick` → Uint8List, or null when cancelled. `TOO_LARGE` above
 *   [MAX_BYTES] (a real key file is a few hundred KB for a large
 *   organization), `BUSY` while a pick is already open, `FAILED` otherwise.
 */
class KeyFilePicker(private val activity: Activity) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/key_file"
        private const val TAG = "KeyFilePicker"

        /** 93xx is this handler's block (roles 90xx, contact extras 91xx, photos 92xx). */
        const val REQUEST_PICK = 9301

        const val MAX_BYTES = 8 * 1024 * 1024
    }

    private var pending: MethodChannel.Result? = null

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "pick" -> pick(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "a pick is already open", null)
            return
        }
        pending = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // Key files have no registered MIME type; let the user pick any
            // file and let the key bank refuse what is not one.
            type = "*/*"
        }
        try {
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            pending = null
            result.error("FAILED", e.javaClass.simpleName, null)
        }
    }

    /** True when [requestCode] was ours. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        // Small file, read once on the main thread: the picker has just
        // returned and nothing is drawn behind it.
        try {
            val bytes = activity.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    buffer.write(chunk, 0, n)
                    if (buffer.size() > MAX_BYTES) {
                        result.error("TOO_LARGE", "not a key file", null)
                        return true
                    }
                }
                buffer.toByteArray()
            }
            if (bytes == null) result.error("FAILED", "unreadable", null) else result.success(bytes)
        } catch (e: Exception) {
            Log.e(TAG, "Reading the key file failed: ${e.javaClass.simpleName}")
            result.error("FAILED", e.javaClass.simpleName, null)
        }
        return true
    }
}
