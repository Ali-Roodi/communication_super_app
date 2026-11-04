package com.example.communication_super_app.contacts

import android.accounts.AccountManager
import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.concurrent.thread

/**
 * The contact file (`.vcf`) and the places a contact can be saved, over
 * `…/contact_file`.
 *
 * The system document pickers need **no permission** and offer every storage
 * provider on the phone, a cloud drive included, which is why this is not a
 * plugin.
 *
 * - `createFile` → the chosen file's uri, or null when cancelled.
 * - `writeFile` → `{written, failed}`. Each contact's vCard comes from the
 *   contacts provider, so the file holds what the phone itself would export.
 * - `pick` → the chosen file's bytes, or null when cancelled.
 * - `saveTargets` → the accounts a contact can be written to.
 */
class ContactFileHandler(private val activity: Activity) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/contact_file"
        private const val TAG = "ContactFile"

        /** 94xx is this handler's block (key files 93xx). */
        const val REQUEST_CREATE = 9401
        const val REQUEST_PICK = 9402

        /** Far above a real address book; the bytes also have to fit the channel. */
        const val MAX_BYTES = 48 * 1024 * 1024

        private const val LOOKUP_CHUNK = 400
    }

    private var pending: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "createFile" -> open(result, REQUEST_CREATE) {
                    Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "text/x-vcard"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                    }
                }
                "pick" -> open(result, REQUEST_PICK) {
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        // File managers label a .vcf several different ways.
                        type = "*/*"
                    }
                }
                "writeFile" -> writeFile(call, result)
                "saveTargets" -> saveTargets(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun open(
        result: MethodChannel.Result,
        request: Int,
        intent: () -> Intent,
    ) {
        if (pending != null) {
            result.error("BUSY", "a picker is already open", null)
            return
        }
        pending = result
        try {
            activity.startActivityForResult(intent(), request)
        } catch (e: Exception) {
            pending = null
            result.error("FAILED", e.javaClass.simpleName, null)
        }
    }

    /** True when [requestCode] was ours. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CREATE && requestCode != REQUEST_PICK) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
        } else if (requestCode == REQUEST_CREATE) {
            result.success(uri.toString())
        } else {
            read(uri, result)
        }
        return true
    }

    private fun read(uri: Uri, result: MethodChannel.Result) {
        thread(name = "contact-file-read") {
            try {
                val bytes = activity.contentResolver.openInputStream(uri)?.use { input ->
                    val buffer = ByteArrayOutputStream()
                    val chunk = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(chunk)
                        if (n < 0) break
                        buffer.write(chunk, 0, n)
                        if (buffer.size() > MAX_BYTES) {
                            main.post { result.error("TOO_LARGE", "file too large", null) }
                            return@thread
                        }
                    }
                    buffer.toByteArray()
                }
                main.post {
                    if (bytes == null) {
                        result.error("FAILED", "no stream", null)
                    } else {
                        result.success(bytes)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "read failed: ${e.javaClass.simpleName}")
                main.post { result.error("FAILED", e.javaClass.simpleName, null) }
            }
        }
    }

    private fun writeFile(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val ids = call.argument<List<String>>("ids").orEmpty()
        val extra = call.argument<List<String>>("extra").orEmpty()
        if (uri == null) {
            result.error("FAILED", "no uri", null)
            return
        }
        thread(name = "contact-file-write") {
            try {
                val resolver = activity.contentResolver
                var written = 0
                var failed = 0
                val keys = lookupKeys(resolver, ids)
                failed += ids.size - keys.size
                val output = resolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("no stream")
                output.use { out ->
                    for (key in keys) {
                        val copied = try {
                            val card = Uri.withAppendedPath(
                                ContactsContract.Contacts.CONTENT_VCARD_URI,
                                key,
                            )
                            // Into memory first: a card that breaks halfway must
                            // not leave half a contact in the file.
                            val bytes = resolver.openAssetFileDescriptor(card, "r")
                                ?.use { it.createInputStream().use { s -> s.readBytes() } }
                            if (bytes == null || bytes.isEmpty()) {
                                false
                            } else {
                                out.write(bytes)
                                true
                            }
                        } catch (e: java.io.IOException) {
                            // The file itself may be what failed; let that surface
                            // only if the next write fails too.
                            Log.w(TAG, "card failed: ${e.javaClass.simpleName}")
                            false
                        } catch (e: RuntimeException) {
                            Log.w(TAG, "card failed: ${e.javaClass.simpleName}")
                            false
                        }
                        if (copied) written++ else failed++
                    }
                    for (card in extra) {
                        out.write(card.toByteArray(Charsets.UTF_8))
                        written++
                    }
                    out.flush()
                }
                main.post {
                    result.success(mapOf("written" to written, "failed" to failed))
                }
            } catch (e: Exception) {
                Log.w(TAG, "write failed: ${e.javaClass.simpleName}")
                main.post { result.error("FAILED", e.javaClass.simpleName, null) }
            }
        }
    }

    /** Contact id → lookup key, in the order given. A deleted contact has none. */
    private fun lookupKeys(resolver: ContentResolver, ids: List<String>): List<String> {
        val found = HashMap<String, String>(ids.size)
        for (chunk in ids.chunked(LOOKUP_CHUNK)) {
            val marks = chunk.joinToString(",") { "?" }
            resolver.query(
                ContactsContract.Contacts.CONTENT_URI,
                arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.LOOKUP_KEY),
                "${ContactsContract.Contacts._ID} IN ($marks)",
                chunk.toTypedArray(),
                null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val key = c.getString(1) ?: continue
                    found[id] = key
                }
            }
        }
        return ids.mapNotNull { found[it] }
    }

    /**
     * Accounts whose contacts sync adapter uploads: a real cloud account. A
     * messenger's download-only copy of the address book is not somewhere to
     * save a contact, and the SIM and the phone are offered separately.
     *
     * [ContentResolver.getSyncAdapterTypes] needs no permission. An account with
     * no contacts yet is only known to [AccountManager], which shows contact
     * accounts to an app holding READ_CONTACTS; the raw contacts cover a phone
     * where it answers less.
     */
    private fun saveTargets(result: MethodChannel.Result) {
        thread(name = "contact-save-targets") {
            val out = LinkedHashSet<Pair<String, String>>()
            try {
                val uploading = ContentResolver.getSyncAdapterTypes()
                    .filter {
                        it.authority == ContactsContract.AUTHORITY &&
                            it.supportsUploading() &&
                            it.isUserVisible
                    }
                    .map { it.accountType }
                    .toSet()
                try {
                    for (account in AccountManager.get(activity).accounts) {
                        if (account.type in uploading) out.add(account.type to account.name)
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "accounts unavailable")
                }
                activity.contentResolver.query(
                    ContactsContract.RawContacts.CONTENT_URI,
                    arrayOf(
                        ContactsContract.RawContacts.ACCOUNT_TYPE,
                        ContactsContract.RawContacts.ACCOUNT_NAME,
                    ),
                    "${ContactsContract.RawContacts.DELETED} = 0",
                    null,
                    null,
                )?.use { c ->
                    while (c.moveToNext()) {
                        val type = c.getString(0) ?: continue
                        val name = c.getString(1) ?: continue
                        if (type in uploading) out.add(type to name)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "save targets failed: ${e.javaClass.simpleName}")
            }
            val rows = out.map { mapOf("type" to it.first, "name" to it.second) }
            main.post { result.success(rows) }
        }
    }
}
