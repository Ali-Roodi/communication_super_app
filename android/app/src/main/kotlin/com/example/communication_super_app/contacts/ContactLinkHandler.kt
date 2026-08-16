package com.example.communication_super_app.contacts

import android.content.ContentProviderOperation
import android.content.Context
import android.provider.ContactsContract
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Linking and unlinking duplicate contacts — «ادغام مخاطب‌های تکراری».
 *
 * This is **not** expressible through `flutter_contacts`, and it is not the same
 * thing as "write one contact and delete the others". A contact in
 * ContactsContract is an *aggregate* of raw contacts (one per account: the local
 * one, a Google one, a messenger's own), and linking is the platform's own
 * operation on that aggregate: `AggregationExceptions` with `TYPE_KEEP_TOGETHER`
 * over every pair of the raw contacts involved. Nothing is copied and nothing is
 * deleted, so:
 *
 * * no field is lost when two rows disagree (two numbers stay two numbers),
 * * each account keeps its own row, so the Google copy still syncs, and
 * * it is **reversible** — [unlink] writes `TYPE_KEEP_SEPARATE` and the contacts
 *   come apart again, which a merge-and-delete could never offer.
 *
 * The AggregationExceptions row is written with `newUpdate`, not `newInsert`:
 * the provider treats the (raw1, raw2) pair as the key and upserts it. That is
 * the documented call, and an insert throws.
 */
class ContactLinkHandler(private val context: Context) {

    companion object {
        const val CHANNEL = "com.example.communication_super_app/contact_link"
        private const val TAG = "ContactLinkHandler"
    }

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "link" -> {
                        val ids = call.argument<List<String>>("contactIds").orEmpty()
                        val primary = call.argument<String>("primaryContactId")
                        result.success(link(ids, primary))
                    }
                    "unlink" -> {
                        val id = call.argument<String>("contactId").orEmpty()
                        result.success(unlink(id))
                    }
                    "rawContactCount" -> {
                        val id = call.argument<String>("contactId").orEmpty()
                        result.success(rawContactIdsOf(id).size)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                Log.w(TAG, "contacts permission denied: ${e.message}")
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                Log.e(TAG, "contact link error: ${e.message}")
                result.error("LINK_FAILED", e.message, null)
            }
        }
    }

    /**
     * Links every raw contact behind [contactIds] into one aggregate.
     *
     * Returns the contact id the aggregate ended up under — which is *not*
     * necessarily any of the inputs, since the provider re-aggregates and may
     * pick a different one. The caller has to re-read rather than assume.
     */
    private fun link(contactIds: List<String>, primaryContactId: String?): String? {
        val rawIds = contactIds.flatMap(::rawContactIdsOf).distinct()
        if (rawIds.size < 2) return null
        // Read the winner's raw contacts BEFORE aggregating: afterwards every
        // input contact id resolves to the same aggregate and the choice can no
        // longer be told apart.
        val primaryRawIds = primaryContactId
            ?.takeIf { it.isNotBlank() }
            ?.let(::rawContactIdsOf)
            .orEmpty()
        applyExceptions(rawIds, ContactsContract.AggregationExceptions.TYPE_KEEP_TOGETHER)
        if (primaryRawIds.isNotEmpty()) setPrimaryIdentity(primaryRawIds.first())
        // The aggregate's id is whatever the first raw contact now belongs to.
        return contactIdOfRaw(rawIds.first())
    }

    /**
     * Makes [rawId]'s name and photo the ones the merged contact shows.
     *
     * Linking does not *pick* a name — the provider aggregates and then decides
     * the display name by its own priority rules, which is why merging two
     * contacts could leave the wrong one on screen with no way to say
     * otherwise. `IS_SUPER_PRIMARY` on a data row is the documented way to
     * override that: the provider takes the aggregate's display name from the
     * super-primary StructuredName row, and its photo from the super-primary
     * Photo row.
     *
     * Nothing is deleted or copied, so «جدا کردن» still takes the contact apart
     * exactly as before; the flag simply stops mattering once the rows are no
     * longer one aggregate.
     */
    private fun setPrimaryIdentity(rawId: Long) {
        val mimeTypes = listOf(
            ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Photo.CONTENT_ITEM_TYPE,
        )
        val ops = ArrayList<ContentProviderOperation>()
        for (mimeType in mimeTypes) {
            ops.add(
                ContentProviderOperation.newUpdate(ContactsContract.Data.CONTENT_URI)
                    .withSelection(
                        "${ContactsContract.Data.RAW_CONTACT_ID} = ? AND " +
                            "${ContactsContract.Data.MIMETYPE} = ?",
                        arrayOf(rawId.toString(), mimeType),
                    )
                    .withValue(ContactsContract.Data.IS_SUPER_PRIMARY, 1)
                    .withValue(ContactsContract.Data.IS_PRIMARY, 1)
                    .build(),
            )
        }
        try {
            context.contentResolver.applyBatch(ContactsContract.AUTHORITY, ops)
        } catch (e: Exception) {
            // A contact with no name row (a number-only entry), or a provider
            // that refuses the flag: the merge itself already succeeded, and
            // the aggregate keeps the provider's own choice of name.
            Log.w(TAG, "primary identity not applied: ${e.message}")
        }
    }

    /**
     * Breaks [contactId] back into one contact per raw contact.
     *
     * KEEP_SEPARATE rather than "remove the exception": an automatic
     * re-aggregation would otherwise put back together exactly what the user
     * just asked to separate — the two rows still look like the same person to
     * the provider's matcher, which is how they got linked in the first place.
     */
    private fun unlink(contactId: String): Int {
        val rawIds = rawContactIdsOf(contactId)
        if (rawIds.size < 2) return 0
        applyExceptions(rawIds, ContactsContract.AggregationExceptions.TYPE_KEEP_SEPARATE)
        return rawIds.size
    }

    /** Writes [type] for every unordered pair of [rawIds], in one batch. */
    private fun applyExceptions(rawIds: List<Long>, type: Int) {
        val ops = ArrayList<ContentProviderOperation>()
        for (i in rawIds.indices) {
            for (j in i + 1 until rawIds.size) {
                ops.add(
                    ContentProviderOperation
                        .newUpdate(ContactsContract.AggregationExceptions.CONTENT_URI)
                        .withValue(ContactsContract.AggregationExceptions.TYPE, type)
                        .withValue(
                            ContactsContract.AggregationExceptions.RAW_CONTACT_ID1,
                            rawIds[i],
                        )
                        .withValue(
                            ContactsContract.AggregationExceptions.RAW_CONTACT_ID2,
                            rawIds[j],
                        )
                        .build(),
                )
            }
        }
        if (ops.isEmpty()) return
        // Batched in chunks: the provider caps a single applyBatch, and a
        // contact aggregated from several accounts can produce a lot of pairs.
        ops.chunked(BATCH_SIZE).forEach { chunk ->
            context.contentResolver.applyBatch(
                ContactsContract.AUTHORITY,
                ArrayList(chunk),
            )
        }
    }

    private fun rawContactIdsOf(contactId: String): List<Long> {
        if (contactId.isBlank()) return emptyList()
        val ids = ArrayList<Long>()
        context.contentResolver.query(
            ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(ContactsContract.RawContacts._ID),
            "${ContactsContract.RawContacts.CONTACT_ID} = ?",
            arrayOf(contactId),
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(ContactsContract.RawContacts._ID)
            if (idIndex < 0) return ids
            while (cursor.moveToNext()) ids.add(cursor.getLong(idIndex))
        }
        return ids
    }

    private fun contactIdOfRaw(rawId: Long): String? {
        context.contentResolver.query(
            ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(ContactsContract.RawContacts.CONTACT_ID),
            "${ContactsContract.RawContacts._ID} = ?",
            arrayOf(rawId.toString()),
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(ContactsContract.RawContacts.CONTACT_ID)
            if (index >= 0 && cursor.moveToFirst()) return cursor.getString(index)
        }
        return null
    }
}

/** The provider caps one `applyBatch`; a heavily-aggregated contact exceeds it. */
private const val BATCH_SIZE = 100
