package com.example.communication_super_app.contacts

import android.content.ContentProviderOperation
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.GroupMembership
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Contact labels («برچسب‌ها» — `Groups` + `GroupMembership` in ContactsContract
 * terms), written the way the provider actually requires.
 *
 * **A group belongs to an account, and so does a raw contact — and a membership
 * row is only valid when the two match.** That is the whole reason this file
 * exists. `flutter_contacts` inserts a group with *no* account
 * (`insertGroup` writes only `TITLE`), and this phone keeps its contacts in
 * three accounts (`vnd.sec.contact.phone` and two `com.google` ones). A label
 * made through the plugin therefore belonged to none of them, the membership
 * row written against it was meaningless, and the label came back empty every
 * time — which is exactly the "I save contacts into a label and the label is
 * empty" report.
 *
 * It also replaces the plugin's way of *writing* memberships. `Contact.update(
 * withGroups: true)` deletes every `GroupMembership` row of the whole aggregate
 * and re-adds the requested ones against the **first** raw contact only, so
 * editing a linked contact silently dropped the labels its other accounts
 * carried. Here each membership is added or removed on its own row, and the
 * platform's own groups («My Contacts», «Starred in Android») are never
 * touched.
 */
class ContactGroupsHandler(private val context: Context) {

    companion object {
        const val CHANNEL = "com.example.communication_super_app/contact_groups"
        private const val TAG = "ContactGroupsHandler"

        /** Groups the platform maintains for itself — mirrors the Dart
         *  `ContactGroupsService._internalNames`. Never added, never removed. */
        private val INTERNAL_TITLES = setOf("my contacts", "starred in android")

        private fun isInternal(title: String) =
            INTERNAL_TITLES.contains(title.trim().lowercase())
    }

    private data class GroupRow(
        val id: Long,
        val title: String,
        val accountName: String?,
        val accountType: String?,
    )

    private data class RawContact(
        val id: Long,
        val accountName: String?,
        val accountType: String?,
    )

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // The labels a contact should end up carrying, by NAME.
                    "applyLabels" -> {
                        val contactId = call.argument<String>("contactId").orEmpty()
                        val names = call.argument<List<String>>("names").orEmpty()
                        result.success(applyLabels(contactId, names))
                    }
                    // Add several contacts to one label at once («افزودن مخاطب»
                    // on the label page).
                    "addToLabel" -> {
                        val name = call.argument<String>("name").orEmpty()
                        val ids = call.argument<List<String>>("contactIds").orEmpty()
                        var added = 0
                        for (id in ids) if (addLabel(id, name)) added++
                        result.success(added)
                    }
                    "removeFromLabel" -> {
                        val name = call.argument<String>("name").orEmpty()
                        val ids = call.argument<List<String>>("contactIds").orEmpty()
                        var removed = 0
                        for (id in ids) if (removeLabel(id, name)) removed++
                        result.success(removed)
                    }
                    // Contact ids carrying a label, straight from the Data
                    // table — far cheaper than reading the whole address book
                    // with `withGroups: true` just to filter it.
                    "memberIds" -> {
                        val name = call.argument<String>("name").orEmpty()
                        result.success(memberIds(name))
                    }
                    // Creates the label in a real account, so contacts can
                    // actually be put in it.
                    "createLabel" -> {
                        val name = call.argument<String>("name").orEmpty()
                        result.success(createLabel(name))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                Log.w(TAG, "contacts permission denied: ${e.message}")
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                Log.e(TAG, "label operation failed: ${e.message}", e)
                result.error("LABEL_FAILED", e.message, null)
            }
        }
    }

    // ── Reads ───────────────────────────────────────────────────────────────

    private fun groups(): List<GroupRow> {
        val out = ArrayList<GroupRow>()
        context.contentResolver.query(
            ContactsContract.Groups.CONTENT_URI,
            arrayOf(
                ContactsContract.Groups._ID,
                ContactsContract.Groups.TITLE,
                ContactsContract.Groups.ACCOUNT_NAME,
                ContactsContract.Groups.ACCOUNT_TYPE,
            ),
            "${ContactsContract.Groups.DELETED} = 0",
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                out.add(
                    GroupRow(
                        id = c.getLong(0),
                        title = c.getString(1) ?: "",
                        accountName = c.getString(2),
                        accountType = c.getString(3),
                    ),
                )
            }
        }
        return out
    }

    private fun rawContactsOf(contactId: String): List<RawContact> {
        if (contactId.isBlank()) return emptyList()
        val out = ArrayList<RawContact>()
        context.contentResolver.query(
            ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(
                ContactsContract.RawContacts._ID,
                ContactsContract.RawContacts.ACCOUNT_NAME,
                ContactsContract.RawContacts.ACCOUNT_TYPE,
            ),
            "${ContactsContract.RawContacts.CONTACT_ID} = ? AND " +
                "${ContactsContract.RawContacts.DELETED} = 0",
            arrayOf(contactId),
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                out.add(RawContact(c.getLong(0), c.getString(1), c.getString(2)))
            }
        }
        return out
    }

    /** Contact ids carrying any group named [name]. */
    private fun memberIds(name: String): List<String> {
        val groupIds = groups()
            .filter { it.title.trim() == name.trim() }
            .map { it.id }
        if (groupIds.isEmpty()) return emptyList()
        val out = LinkedHashSet<String>()
        context.contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(ContactsContract.Data.CONTACT_ID),
            "${ContactsContract.Data.MIMETYPE} = ? AND " +
                "${GroupMembership.GROUP_ROW_ID} IN (${groupIds.joinToString(",")})",
            arrayOf(GroupMembership.CONTENT_ITEM_TYPE),
            null,
        )?.use { c ->
            while (c.moveToNext()) out.add(c.getString(0))
        }
        return out.toList()
    }

    // ── Writes ──────────────────────────────────────────────────────────────

    /**
     * The account a new label is created in when the contact does not name one:
     * the best *writable* account, and among equals the one most of the phone's
     * contacts already live in.
     *
     * A label nobody can be put into is worse than no label, and an
     * account-less one is exactly that. Plain "busiest" was not enough either:
     * a messenger that mirrors the whole address book into its own sync account
     * outnumbers the phone's real store (measured on the test device: 298 rows
     * in `ir.eitaa.messenger` against 158 in `vnd.sec.contact.phone`), so every
     * new label was created inside a read-only copy that its adapter is free to
     * wipe on the next sync.
     */
    private fun busiestAccount(): Pair<String?, String?>? {
        val counts = HashMap<Pair<String?, String?>, Int>()
        context.contentResolver.query(
            ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(
                ContactsContract.RawContacts.ACCOUNT_NAME,
                ContactsContract.RawContacts.ACCOUNT_TYPE,
            ),
            "${ContactsContract.RawContacts.DELETED} = 0",
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                val key = c.getString(0) to c.getString(1)
                if (key.second == null) continue
                if (isSimAccount(key.second)) continue
                counts[key] = (counts[key] ?: 0) + 1
            }
        }
        return counts.entries
            .maxWithOrNull(
                compareBy<Map.Entry<Pair<String?, String?>, Int>> {
                    accountRank(it.key.second)
                }.thenBy { it.value },
            )
            ?.key
    }

    /** An ADN record has no `Groups` row to belong to. */
    private fun isSimAccount(type: String?) =
        type != null && type.contains("sim", ignoreCase = true)

    /**
     * How good an account is as a home for a label — highest wins.
     *
     *  * `2` — no contacts sync adapter is registered for it, i.e. a
     *    device-local store («Phone»). Always writable, never synced away.
     *  * `1` — a sync adapter that **uploads**: a real cloud account (Google),
     *    which will carry the group to the server like any other client.
     *  * `0` — a download-only adapter: a messenger mirroring the address book.
     *    Its rows are a copy of someone else's data and it may replace them
     *    wholesale.
     *
     * [ContentResolver.getSyncAdapterTypes] needs no permission and is the only
     * public signal that separates the three.
     */
    private fun accountRank(type: String?): Int {
        if (type == null) return 2
        val adapter = contactsSyncAdapters[type] ?: return 2
        return if (adapter) 1 else 0
    }

    /** Account type → `supportsUploading`, for the contacts authority only. */
    private val contactsSyncAdapters: Map<String, Boolean> by lazy {
        try {
            ContentResolver.getSyncAdapterTypes()
                .filter { it.authority == ContactsContract.AUTHORITY }
                .associate { it.accountType to it.supportsUploading() }
        } catch (e: Exception) {
            Log.w(TAG, "sync adapter list unavailable: ${e.message}")
            emptyMap()
        }
    }

    /** Finds a non-deleted group named [title] in the given account, or makes one. */
    private fun ensureGroup(
        title: String,
        accountName: String?,
        accountType: String?,
    ): Long? {
        val existing = groups().firstOrNull {
            it.title.trim() == title.trim() &&
                it.accountName == accountName &&
                it.accountType == accountType
        }
        if (existing != null) return existing.id
        return try {
            val values = ContentValues().apply {
                put(ContactsContract.Groups.TITLE, title)
                put(ContactsContract.Groups.GROUP_VISIBLE, 1)
                if (accountName != null) {
                    put(ContactsContract.Groups.ACCOUNT_NAME, accountName)
                }
                if (accountType != null) {
                    put(ContactsContract.Groups.ACCOUNT_TYPE, accountType)
                }
            }
            context.contentResolver
                .insert(ContactsContract.Groups.CONTENT_URI, values)
                ?.lastPathSegment?.toLongOrNull()
        } catch (e: Exception) {
            Log.e(TAG, "group insert failed: ${e.message}")
            null
        }
    }

    /** Creates [name] in the account most contacts live in. Returns its id. */
    private fun createLabel(name: String): String? {
        if (name.isBlank()) return null
        val account = busiestAccount()
        return ensureGroup(name, account?.first, account?.second)?.toString()
    }

    /**
     * Makes the contact carry exactly [names] (plus whatever internal groups it
     * already had).
     *
     * Adds are written against a raw contact **in the group's own account**,
     * creating the group in that account when it does not exist there yet —
     * which is what makes the label stick for a contact that lives in Google
     * while the label was first made somewhere else.
     */
    private fun applyLabels(contactId: String, names: List<String>): Boolean {
        val raws = rawContactsOf(contactId)
        if (raws.isEmpty()) return false
        val wanted = names.map { it.trim() }.filter { it.isNotEmpty() && !isInternal(it) }

        val all = groups()
        val byId = all.associateBy { it.id }
        val current = currentMemberships(raws.map { it.id })

        val ops = ArrayList<ContentProviderOperation>()

        // Remove the labels that are no longer wanted. Internal groups and
        // groups we cannot even see are left exactly as they are.
        for ((dataId, groupId) in current) {
            val group = byId[groupId] ?: continue
            if (isInternal(group.title)) continue
            if (wanted.any { it == group.title.trim() }) continue
            ops.add(
                ContentProviderOperation.newDelete(ContactsContract.Data.CONTENT_URI)
                    .withSelection("${ContactsContract.Data._ID} = ?", arrayOf("$dataId"))
                    .build(),
            )
        }

        // Add the missing ones.
        val heldTitles = current.values
            .mapNotNull { byId[it]?.title?.trim() }
            .toSet()
        for (title in wanted) {
            if (heldTitles.contains(title)) continue
            // Prefer an account this contact already lives in that also has the
            // group; otherwise the contact's most writable account — the same
            // ranking [busiestAccount] uses, and for the same reason: a
            // membership row written into a mirroring messenger's copy is one
            // its adapter may drop.
            val raw = raws.firstOrNull { r ->
                all.any {
                    it.title.trim() == title &&
                        it.accountName == r.accountName &&
                        it.accountType == r.accountType
                }
            } ?: raws
                .filterNot { isSimAccount(it.accountType) }
                .maxByOrNull { accountRank(it.accountType) }
                ?: raws.first()
            val groupId = ensureGroup(title, raw.accountName, raw.accountType)
                ?: continue
            ops.add(
                ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                    .withValue(ContactsContract.Data.RAW_CONTACT_ID, raw.id)
                    .withValue(
                        ContactsContract.Data.MIMETYPE,
                        GroupMembership.CONTENT_ITEM_TYPE,
                    )
                    .withValue(GroupMembership.GROUP_ROW_ID, groupId)
                    .build(),
            )
        }

        if (ops.isEmpty()) return true
        return try {
            context.contentResolver.applyBatch(ContactsContract.AUTHORITY, ops)
            true
        } catch (e: Exception) {
            Log.e(TAG, "membership write failed: ${e.message}")
            false
        }
    }

    private fun addLabel(contactId: String, name: String): Boolean {
        val held = labelsOf(contactId)
        if (held.any { it == name.trim() }) return true
        return applyLabels(contactId, held + name.trim())
    }

    private fun removeLabel(contactId: String, name: String): Boolean =
        applyLabels(contactId, labelsOf(contactId).filter { it != name.trim() })

    /** The non-internal label names this contact currently carries. */
    private fun labelsOf(contactId: String): List<String> {
        val byId = groups().associateBy { it.id }
        return currentMemberships(rawContactsOf(contactId).map { it.id })
            .values
            .mapNotNull { byId[it]?.title?.trim() }
            .filter { it.isNotEmpty() && !isInternal(it) }
            .distinct()
    }

    /** `Data._ID` → `group_row_id` for every membership of these raw contacts. */
    private fun currentMemberships(rawIds: List<Long>): Map<Long, Long> {
        if (rawIds.isEmpty()) return emptyMap()
        val out = LinkedHashMap<Long, Long>()
        context.contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(ContactsContract.Data._ID, GroupMembership.GROUP_ROW_ID),
            "${ContactsContract.Data.MIMETYPE} = ? AND " +
                "${ContactsContract.Data.RAW_CONTACT_ID} IN " +
                "(${rawIds.joinToString(",")})",
            arrayOf(GroupMembership.CONTENT_ITEM_TYPE),
            null,
        )?.use { c ->
            while (c.moveToNext()) out[c.getLong(0)] = c.getLong(1)
        }
        return out
    }
}
