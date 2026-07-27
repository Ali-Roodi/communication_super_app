package com.example.communication_super_app.contacts

import android.accounts.AccountManager
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * The per-contact settings Google Contacts exposes under «تنظیمات مخاطب», none
 * of which `flutter_contacts` reaches: the custom ringtone, the
 * send-straight-to-voicemail flag, sharing the contact as a vCard, pinning it to
 * the launcher, the owning account, and the third-party «برنامه‌های متصل» rows.
 *
 * All of these live on [ContactsContract] columns rather than in the Data rows a
 * contact plugin models, so they need a channel of their own.
 */
class ContactExtrasHandler(
    private val context: Context,
    private val activity: Activity?,
) {
    /** Result waiting on the system ringtone picker, if one is open. */
    private var pendingRingtoneResult: MethodChannel.Result? = null

    /** Contact whose ringtone the open picker will write to. */
    private var pendingRingtoneContactId: String? = null

    companion object {
        const val CHANNEL = "com.example.communication_super_app/contact_extras"
        private const val REQUEST_PICK_RINGTONE = 9101

        /**
         * MIME types the contacts UI already renders itself. Anything else on a
         * contact was put there by another app and belongs under
         * «برنامه‌های متصل».
         */
        private val KNOWN_MIME_TYPES = setOf(
            ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Nickname.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Website.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Im.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Relation.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.GroupMembership.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Photo.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Identity.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.SipAddress.CONTENT_ITEM_TYPE,
        )
    }

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result -> onCall(call, result) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("contactId")
        try {
            when (call.method) {
                "getSettings" -> result.success(getSettings(id))
                "setSendToVoicemail" -> {
                    val value = call.argument<Boolean>("value") ?: false
                    result.success(setSendToVoicemail(id, value))
                }
                "pickRingtone" -> pickRingtone(id, result)
                "clearRingtone" -> result.success(writeRingtone(id, null))
                "shareContact" -> result.success(shareContact(id))
                "pinToHome" -> result.success(pinToHome(id))
                "getConnectedApps" -> result.success(getConnectedApps(id))
                "openConnectedAction" -> result.success(
                    openConnectedAction(
                        (call.argument<Any>("dataId") as? Number)?.toLong(),
                        call.argument<String>("mimeType"),
                        call.argument<String>("package"),
                    )
                )
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("CONTACT_EXTRAS_FAILED", e.message, null)
        }
    }

    // ── Reads ────────────────────────────────────────────────────────────────

    /**
     * Returns the contact's ringtone (uri + display title), the
     * send-to-voicemail flag, and the account it lives in.
     */
    private fun getSettings(contactId: String?): Map<String, Any?>? {
        if (contactId.isNullOrEmpty()) return null
        val out = HashMap<String, Any?>()

        context.contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(
                ContactsContract.Contacts.CUSTOM_RINGTONE,
                ContactsContract.Contacts.SEND_TO_VOICEMAIL,
                ContactsContract.Contacts.LOOKUP_KEY,
            ),
            "${ContactsContract.Contacts._ID} = ?",
            arrayOf(contactId),
            null,
        )?.use { c ->
            if (!c.moveToFirst()) return@use
            val ringtone = c.getString(0)
            out["ringtoneUri"] = ringtone
            out["ringtoneTitle"] = ringtoneTitle(ringtone)
            out["defaultRingtoneTitle"] = defaultRingtoneTitle()
            out["sendToVoicemail"] = c.getInt(1) == 1
            out["lookupKey"] = c.getString(2)
        }

        // The account of the first raw contact — what Google shows in the
        // footer card («دستگاه», a Google address, …).
        context.contentResolver.query(
            ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(
                ContactsContract.RawContacts.ACCOUNT_NAME,
                ContactsContract.RawContacts.ACCOUNT_TYPE,
            ),
            "${ContactsContract.RawContacts.CONTACT_ID} = ?",
            arrayOf(contactId),
            null,
        )?.use { c ->
            if (!c.moveToFirst()) return@use
            out["accountName"] = c.getString(0)
            out["accountType"] = c.getString(1)
            out["accountLabel"] = accountLabel(c.getString(1), c.getString(0))
        }

        return out
    }

    /** Human-readable title of a ringtone uri; null uri = the system default. */
    private fun ringtoneTitle(uri: String?): String? {
        if (uri.isNullOrEmpty()) return null
        return try {
            RingtoneManager.getRingtone(context, Uri.parse(uri))?.getTitle(context)
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Title of the phone's own ringtone, so a contact with no custom tone can
     * still name what it will actually ring with («پیش‌فرض (Galaxy Bells)»).
     */
    private fun defaultRingtoneTitle(): String? = try {
        val uri = RingtoneManager.getActualDefaultRingtoneUri(
            context, RingtoneManager.TYPE_RINGTONE,
        )
        uri?.let { RingtoneManager.getRingtone(context, it)?.getTitle(context) }
    } catch (_: Exception) {
        null
    }

    /**
     * Account types that mean "stored on this device", which every OEM spells
     * differently. They have no authenticator, so they'd otherwise surface as a
     * raw type string.
     */
    private val deviceAccountTypes = setOf(
        "vnd.sec.contact.phone",
        "com.android.localphone",
        "com.android.contacts.default",
        "com.android.huawei.phone",
        "Local Phone Account",
    )

    /**
     * Label for an account type, resolved from the authenticator that owns it
     * ("Google", "Samsung account", …). Device-local contacts get «دستگاه».
     */
    private fun accountLabel(type: String?, name: String?): String {
        if (type.isNullOrEmpty() || type in deviceAccountTypes) return "دستگاه"
        val pm = context.packageManager
        val descriptions = AccountManager.get(context).authenticatorTypes
        val match = descriptions.firstOrNull { it.type == type }
            ?: return name ?: "دستگاه"
        return try {
            pm.getResourcesForApplication(match.packageName)
                .getString(match.labelId)
        } catch (_: Exception) {
            name ?: "دستگاه"
        }
    }

    /**
     * Data rows on this contact with a MIME type no standard contacts UI
     * renders — i.e. rows another app wrote (a messenger's "call/chat with"
     * action). Grouped per app so each one appears once.
     *
     * A row is never dropped for being unresolvable: package visibility
     * (targetSdk 30+) can hide the owning app even with the manifest `<queries>`
     * entries, and an app whose name we can't read is still an app the user has
     * on this contact. The grouping key then degrades to the account type.
     */
    private fun getConnectedApps(contactId: String?): List<Map<String, Any?>> {
        if (contactId.isNullOrEmpty()) return emptyList()
        val byKey = LinkedHashMap<String, MutableMap<String, Any?>>()

        context.contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(
                ContactsContract.Data._ID,
                ContactsContract.Data.MIMETYPE,
                ContactsContract.Data.DATA1,
                ContactsContract.Data.DATA3,
                ContactsContract.Data.RES_PACKAGE,
                ContactsContract.RawContacts.ACCOUNT_TYPE,
            ),
            "${ContactsContract.Data.CONTACT_ID} = ?",
            arrayOf(contactId),
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                val mime = c.getString(1) ?: continue
                if (mime in KNOWN_MIME_TYPES) continue

                val accountType = c.getString(5)
                // The row's own package, then the authenticator that owns the
                // raw contact's account, then the package embedded in the custom
                // MIME type (`…/vnd.ir.eitaa.messenger.android.call`).
                val pkg = c.getString(4)
                    ?: packageForAccountType(accountType)
                    ?: packageFromMimeType(mime)
                val key = pkg ?: accountType ?: mime
                if (key == context.packageName) continue

                val entry = byKey.getOrPut(key) {
                    hashMapOf(
                        "package" to (pkg ?: ""),
                        "label" to appLabel(pkg, accountType, mime),
                        "icon" to pkg?.let { appIcon(it) },
                        "actions" to mutableListOf<Map<String, Any?>>(),
                    )
                }

                @Suppress("UNCHECKED_CAST")
                (entry["actions"] as MutableList<Map<String, Any?>>).add(
                    mapOf(
                        "dataId" to c.getLong(0),
                        "mimeType" to mime,
                        // DATA3 is the row's own summary line ("Call with X");
                        // DATA1 is usually the address it acts on.
                        "title" to (c.getString(3)?.takeIf { it.isNotBlank() }
                            ?: c.getString(2)),
                    )
                )
            }
        }
        return byKey.values.toList()
    }

    private fun packageForAccountType(type: String?): String? {
        if (type.isNullOrEmpty()) return null
        return AccountManager.get(context).authenticatorTypes
            .firstOrNull { it.type == type }
            ?.packageName
    }

    /**
     * Custom MIME types are conventionally
     * `vnd.android.cursor.item/vnd.<package>.<action>`, so the subtype carries
     * the writing app's package. Returns the longest prefix that is an installed
     * package, or null when none is visible to us.
     */
    private fun packageFromMimeType(mime: String): String? {
        val subtype = mime.substringAfter('/', "").removePrefix("vnd.")
        if (subtype.isEmpty()) return null
        val parts = subtype.split('.')
        for (size in parts.size downTo 2) {
            val candidate = parts.take(size).joinToString(".")
            if (isInstalled(candidate)) return candidate
        }
        return null
    }

    private fun isInstalled(pkg: String): Boolean = try {
        context.packageManager.getApplicationInfo(pkg, 0)
        true
    } catch (_: Exception) {
        false
    }

    /**
     * The app's own name when we can read it, otherwise a readable guess from
     * the account type / MIME type ("ir.eitaa.messenger" → "Eitaa") so the row
     * never renders as a raw identifier.
     */
    private fun appLabel(pkg: String?, accountType: String?, mime: String): String {
        if (pkg != null) {
            try {
                val pm = context.packageManager
                return pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
            } catch (_: Exception) {
                // Hidden by package visibility — fall through to the guess.
            }
        }
        val source = pkg
            ?: accountType
            ?: mime.substringAfter('/', "").removePrefix("vnd.")
        val parts = source.split('.').filter { it.isNotEmpty() }
        // Skip the leading TLD segment of a reverse-domain name.
        val name = parts.getOrNull(if (parts.size > 1) 1 else 0) ?: source
        return name.replaceFirstChar { it.uppercase() }
    }

    /** App icon as PNG bytes, so Flutter can draw it without a plugin. */
    private fun appIcon(pkg: String): ByteArray? = try {
        val drawable = context.packageManager.getApplicationIcon(pkg)
        val size = 96
        val bitmap = android.graphics.Bitmap.createBitmap(
            size, size, android.graphics.Bitmap.Config.ARGB_8888,
        )
        val canvas = android.graphics.Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        ByteArrayOutputStream().also {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }.toByteArray()
    } catch (_: Exception) {
        null
    }

    /**
     * Runs one «برنامه‌های متصل» row the way Google Contacts does: an ACTION_VIEW
     * on the Data row itself, typed with its custom MIME type, which the writing
     * app registered a handler for. False when nothing can handle it.
     */
    private fun openConnectedAction(
        dataId: Long?,
        mimeType: String?,
        packageName: String?,
    ): Boolean {
        if (dataId == null || mimeType.isNullOrEmpty()) return false
        val uri = ContentUris.withAppendedId(ContactsContract.Data.CONTENT_URI, dataId)
        val host = activity ?: context

        fun intentFor(pkg: String?) = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            if (!pkg.isNullOrEmpty()) setPackage(pkg)
            if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        // Resolve to a concrete component first. Messengers register several
        // activity-aliases for the same custom MIME type, so an implicit intent
        // — even one restricted with setPackage — pops an "Open with" sheet that
        // offers the same app twice. Only decide for the user while every
        // candidate belongs to one app.
        try {
            val probe = intentFor(packageName)
            val candidates = context.packageManager.queryIntentActivities(probe, 0)
            val owners = candidates.map { it.activityInfo.packageName }.distinct()
            if (candidates.isNotEmpty() && owners.size == 1) {
                val target = candidates.first().activityInfo
                host.startActivity(
                    probe.setClassName(target.packageName, target.name)
                )
                return true
            }
            if (!packageName.isNullOrEmpty()) {
                host.startActivity(intentFor(packageName))
                return true
            }
        } catch (_: Exception) {
            // Hidden by package visibility or gone: fall back to the chooser.
        }
        return try {
            host.startActivity(intentFor(null))
            true
        } catch (_: Exception) {
            false
        }
    }

    // ── Writes ───────────────────────────────────────────────────────────────

    private fun setSendToVoicemail(contactId: String?, value: Boolean): Boolean {
        if (contactId.isNullOrEmpty()) return false
        val values = ContentValues().apply {
            put(ContactsContract.Contacts.SEND_TO_VOICEMAIL, if (value) 1 else 0)
        }
        val rows = context.contentResolver.update(
            ContactsContract.Contacts.CONTENT_URI,
            values,
            "${ContactsContract.Contacts._ID} = ?",
            arrayOf(contactId),
        )
        return rows > 0
    }

    private fun writeRingtone(contactId: String?, uri: String?): Boolean {
        if (contactId.isNullOrEmpty()) return false
        val values = ContentValues().apply {
            if (uri == null) {
                putNull(ContactsContract.Contacts.CUSTOM_RINGTONE)
            } else {
                put(ContactsContract.Contacts.CUSTOM_RINGTONE, uri)
            }
        }
        val rows = context.contentResolver.update(
            ContactsContract.Contacts.CONTENT_URI,
            values,
            "${ContactsContract.Contacts._ID} = ?",
            arrayOf(contactId),
        )
        return rows > 0
    }

    private fun pickRingtone(contactId: String?, result: MethodChannel.Result) {
        val host = activity
        if (host == null || contactId.isNullOrEmpty()) {
            result.success(null)
            return
        }
        // Only one picker at a time; drop a stale pending request.
        pendingRingtoneResult?.success(null)
        pendingRingtoneResult = result
        pendingRingtoneContactId = contactId

        val current = (getSettings(contactId)?.get("ringtoneUri") as? String)
            ?.let { Uri.parse(it) }
        val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
            putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_RINGTONE)
            putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
            putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, current)
        }
        try {
            host.startActivityForResult(intent, REQUEST_PICK_RINGTONE)
        } catch (e: Exception) {
            pendingRingtoneResult = null
            pendingRingtoneContactId = null
            result.error("RINGTONE_PICKER_FAILED", e.message, null)
        }
    }

    /** Returns true when [requestCode] was ours (caller then stops dispatch). */
    fun handleActivityResult(requestCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_RINGTONE) return false
        val result = pendingRingtoneResult ?: return true
        val contactId = pendingRingtoneContactId
        pendingRingtoneResult = null
        pendingRingtoneContactId = null

        val picked: Uri? = data?.getParcelableExtra(
            RingtoneManager.EXTRA_RINGTONE_PICKED_URI
        )
        // A null pick means "Default ringtone", which is stored as a null column.
        writeRingtone(contactId, picked?.toString())
        result.success(
            mapOf(
                "ringtoneUri" to picked?.toString(),
                "ringtoneTitle" to ringtoneTitle(picked?.toString()),
            )
        )
        return true
    }

    /** Shares the contact as a vCard through the system share sheet. */
    private fun shareContact(contactId: String?): Boolean {
        if (contactId.isNullOrEmpty()) return false
        val lookupKey = (getSettings(contactId)?.get("lookupKey") as? String)
            ?: return false
        val shareUri = Uri.withAppendedPath(
            ContactsContract.Contacts.CONTENT_VCARD_URI,
            lookupKey,
        )
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = ContactsContract.Contacts.CONTENT_VCARD_TYPE
            putExtra(Intent.EXTRA_STREAM, shareUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(intent, null).apply {
            if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        (activity ?: context).startActivity(chooser)
        return true
    }

    /**
     * Asks the launcher to pin a shortcut that opens this contact. Returns false
     * on launchers that don't support pinning, so the UI can say so instead of
     * silently doing nothing.
     */
    private fun pinToHome(contactId: String?): Boolean {
        if (contactId.isNullOrEmpty()) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = ContextCompat.getSystemService(context, ShortcutManager::class.java)
            ?: return false
        if (!manager.isRequestPinShortcutSupported) return false

        val contactUri = ContentUris.withAppendedId(
            ContactsContract.Contacts.CONTENT_URI,
            contactId.toLong(),
        )
        val label = displayName(contactId) ?: return false
        val open = Intent(Intent.ACTION_VIEW, contactUri).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val shortcut = ShortcutInfo.Builder(context, "contact_$contactId")
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(Icon.createWithResource(context, android.R.drawable.sym_action_call))
            .setIntent(open)
            .build()
        return manager.requestPinShortcut(shortcut, null)
    }

    private fun displayName(contactId: String): String? {
        context.contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(ContactsContract.Contacts.DISPLAY_NAME),
            "${ContactsContract.Contacts._ID} = ?",
            arrayOf(contactId),
            null,
        )?.use { c -> if (c.moveToFirst()) return c.getString(0) }
        return null
    }
}
