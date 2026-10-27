package com.example.communication_super_app.contacts

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.example.communication_super_app.sim.SimRegistry
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The SIM address book (`content://icc/adn`).
 *
 * This exists because **SIM contacts are not in `ContactsContract`**. The
 * Contacts provider only carries them when the device's *default* contacts app
 * has registered a SIM account (`ContactsContract.SimAccount`, Android 12+) and
 * imported them; on most phones — and on every phone where this app is the
 * contacts surface — inserting a second SIM adds nothing to the provider, so
 * `flutter_contacts` returns exactly the same list as before and the SIM's
 * contacts are simply invisible. Google Contacts reads the ICC provider
 * directly for the same reason; so do we.
 *
 * The rows are **read-only in place**: an ADN record holds one name and one
 * number, has a hard length limit set by the card, and has no id that survives
 * a re-insert. So they are surfaced as their own contacts, editing them means
 * copying to the phone, and the only write offered is create/delete.
 */
class SimContactsHandler(private val context: Context) {

    companion object {
        const val CHANNEL = "com.example.communication_super_app/sim_contacts"
        private const val TAG = "SimContactsHandler"
        private val METHODS = setOf("getSimContacts", "insertSimContact", "deleteSimContact")

        /** Abbreviated-dialling-numbers table of the default SIM. */
        private val ADN_URI: Uri = Uri.parse("content://icc/adn")

        /**
         * Per-subscription ADN. The `subId` form is what makes SIM 2 readable
         * at all — the bare `content://icc/adn` always resolves to the default
         * subscription, which is why a naive implementation shows SIM 1's
         * contacts twice on a dual-SIM phone.
         */
        private fun adnUri(subscriptionId: Int): Uri =
            if (subscriptionId == SimRegistry.INVALID_SUBSCRIPTION_ID) {
                ADN_URI
            } else {
                Uri.parse("content://icc/adn/subId/$subscriptionId")
            }
    }

    /**
     * Every ICC call runs here, never on the main thread. A query of
     * `content://icc/adn` is answered by the phone process reading the card
     * itself, and the first one after boot — before anything has warmed the
     * telephony cache, which on a fresh install nothing has — takes seconds
     * per card. On the main thread that froze the whole app the first time the
     * address book was read, and only that time: «دفعه اول بعد از نصب، در
     * خواندن لیست مخاطبین، اپ هنگ کرد» (the mentor's dual-SIM phone,
     * 1405/08/05). One thread, so a write and a read of the same card never
     * overlap — process-wide, for the same reason and so a re-created
     * activity does not start another.
     */
    private val io get() = Shared.io
    private val main get() = Shared.main

    private object Shared {
        val io = Executors.newSingleThreadExecutor { r ->
            Thread(r, "sim-contacts").apply { isDaemon = true }
        }
        val main = Handler(Looper.getMainLooper())
    }

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            val method = call.method
            if (method !in METHODS) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val subId = call.argument<Int>("subscriptionId")
                ?: SimRegistry.INVALID_SUBSCRIPTION_ID
            val name = call.argument<String>("name").orEmpty()
            val number = call.argument<String>("number").orEmpty()
            io.execute {
                try {
                    val answer: Any = when (method) {
                        "getSimContacts" -> readAll()
                        "insertSimContact" -> insert(subId, name, number)
                        else -> delete(subId, name, number)
                    }
                    main.post { result.success(answer) }
                } catch (e: SecurityException) {
                    main.post { result.error("PERMISSION_DENIED", e.message, null) }
                } catch (e: Exception) {
                    Log.e(TAG, "sim contacts call failed: ${e.message}", e)
                    main.post { result.error("SIM_CONTACTS_ERROR", e.message, null) }
                }
            }
        }
    }

    /**
     * Every SIM's contacts, tagged with the subscription and slot they came
     * from. A card that cannot be read (no permission yet, an OEM that hides
     * the provider, a card still initialising) contributes nothing instead of
     * failing the whole read — one unreadable SIM must not hide the other's
     * contacts.
     */
    private fun readAll(): List<Map<String, Any?>> {
        val started = SystemClock.elapsedRealtime()
        val subs = SimRegistry.subscriptions(context)
        // No subscription list (permission refused, or a device that reports
        // none): still try the default ADN, which is the single-SIM case.
        val out = if (subs.isEmpty()) {
            read(SimRegistry.INVALID_SUBSCRIPTION_ID, slotIndex = 0)
        } else {
            subs.flatMap { read(it.subscriptionId, it.slotIndex) }
        }
        Log.i(TAG, "read ${subs.size} card(s) in ${SystemClock.elapsedRealtime() - started} ms")
        return out
    }

    private fun read(subscriptionId: Int, slotIndex: Int): List<Map<String, Any?>> {
        val rows = ArrayList<Map<String, Any?>>()
        try {
            context.contentResolver.query(adnUri(subscriptionId), null, null, null, null)
                ?.use { cursor ->
                    val nameIndex = cursor.getColumnIndex("name")
                    val numberIndex = cursor.getColumnIndex("number")
                    val emailsIndex = cursor.getColumnIndex("emails")
                    val idIndex = cursor.getColumnIndex("_id")
                    if (nameIndex < 0 && numberIndex < 0) return emptyList()

                    while (cursor.moveToNext()) {
                        val name = if (nameIndex >= 0) cursor.getString(nameIndex).orEmpty() else ""
                        val number =
                            if (numberIndex >= 0) cursor.getString(numberIndex).orEmpty() else ""
                        // A card is written with its full capacity of records;
                        // the unused ones come back blank.
                        if (name.isBlank() && number.isBlank()) continue
                        val recordId = if (idIndex >= 0) cursor.getLong(idIndex) else -1L
                        rows += mapOf(
                            // Stable within a session and prefixed so it can
                            // never collide with a ContactsContract id.
                            "id" to "sim:$subscriptionId:$recordId",
                            "name" to name,
                            "number" to number,
                            "email" to
                                (if (emailsIndex >= 0) cursor.getString(emailsIndex) else null),
                            "subscriptionId" to subscriptionId,
                            "slotIndex" to slotIndex,
                        )
                    }
                }
        } catch (e: SecurityException) {
            Log.w(TAG, "ADN read denied (sub=$subscriptionId): ${e.message}")
        } catch (e: Exception) {
            // Unsupported on this device / card busy. Not fatal.
            Log.w(TAG, "ADN read failed (sub=$subscriptionId): ${e.message}")
        }
        return rows
    }

    /**
     * Writes one ADN record. Returns false when the card refuses it — usually a
     * full card or a name longer than the record allows, both of which the
     * caller reports as «ذخیره روی سیم‌کارت ممکن نشد» rather than pretending
     * the contact was saved.
     */
    private fun insert(subscriptionId: Int, name: String, number: String): Boolean {
        if (number.isBlank()) return false
        return try {
            val values = ContentValues().apply {
                put("tag", name)
                put("number", number)
            }
            context.contentResolver.insert(adnUri(subscriptionId), values) != null
        } catch (e: Exception) {
            Log.w(TAG, "ADN insert failed: ${e.message}")
            false
        }
    }

    /**
     * ADN rows have no durable id — the provider deletes by matching the
     * record's contents, which is the only selection it accepts.
     */
    private fun delete(subscriptionId: Int, name: String, number: String): Boolean {
        return try {
            val deleted = context.contentResolver.delete(
                adnUri(subscriptionId),
                "tag=? AND number=?",
                arrayOf(name, number),
            )
            deleted > 0
        } catch (e: Exception) {
            Log.w(TAG, "ADN delete failed: ${e.message}")
            false
        }
    }
}
