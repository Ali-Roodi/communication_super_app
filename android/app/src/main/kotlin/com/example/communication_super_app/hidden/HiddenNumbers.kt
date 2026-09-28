package com.example.communication_super_app.hidden

import android.content.Context
import android.util.Base64
import android.util.Log
import com.example.communication_super_app.BlockedNumbers
import com.example.communication_super_app.secure.KeystoreKeyWrapper
import com.example.communication_super_app.smscrypto.PublicIdentity
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Which numbers belong to the hidden phonebook «دفترچه مخفی» — answerable
 * while the secure section is **locked**, which is when every receiver and the
 * call service run.
 *
 * The phonebook itself lives only in `secure.db`. What Kotlin holds is a set
 * of **tags**: HMAC-SHA256 of each canonical number under a 32-byte tag key,
 * and that key is stored sealed by a non-exportable Android Keystore key. A
 * copy of the app's files therefore reveals how many numbers are hidden, not
 * which: the phone-number space is small enough to brute-force any unkeyed
 * hash, but not a keyed one whose key never leaves this device's Keystore.
 *
 * With no tags there is nothing to hide and [isHidden] answers false without
 * touching the Keystore — the commercial edition never pays for this.
 *
 * Names are different: they are known **only while the section is open**,
 * pushed from Dart into process memory ([setNames]) and dropped on lock
 * ([clearNames]). A hidden contact who calls while the section is locked is
 * shown as the bare number (owner's decision, 1405/07/06).
 *
 * Also kept here: the section's **sealing public key**, which [SealedInbox]
 * seals records to. Public, so plain storage is fine.
 */
object HiddenNumbers {
    private const val TAG = "HiddenNumbers"
    private const val PREFS = "hamresan_hidden"
    private const val KEY_TAG_KEY = "tag_key"
    private const val KEY_TAGS = "tags"
    private const val KEY_SEALING = "sealing_public"
    private const val KEYSTORE_ALIAS = "hamresan_hidden_tags_v1"
    private val TAG_LABEL = "hamresan.hidden.tag.v1".toByteArray(Charsets.US_ASCII)
    private const val TAG_BYTES = 16

    private val wrapper by lazy { KeystoreKeyWrapper(KEYSTORE_ALIAS) }

    @Volatile private var tagKey: ByteArray? = null
    @Volatile private var tags: Set<String>? = null
    @Volatile private var names: Map<String, String> = emptyMap()
    @Volatile private var sealing: PublicIdentity? = null

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun canonical(number: String): String = BlockedNumbers.normalizeToThreadId(number)

    private fun tags(context: Context): Set<String> =
        tags ?: (prefs(context).getStringSet(KEY_TAGS, null)?.toSet() ?: emptySet()).also { tags = it }

    /** True when at least one number is hidden (cheap: no Keystore). */
    fun any(context: Context): Boolean = tags(context).isNotEmpty()

    fun isHidden(context: Context, number: String?): Boolean {
        if (number.isNullOrBlank()) return false
        val known = tags(context)
        if (known.isEmpty()) return false
        val tag = tagOf(context, number, create = false) ?: return false
        return tag in known
    }

    /**
     * Replaces the hidden set with [numbers]. True when it changed — the
     * caller then sweeps the call log, since a newly hidden number's past
     * calls have to go too.
     */
    fun setNumbers(context: Context, numbers: List<String>): Boolean {
        val next = if (numbers.isEmpty()) {
            emptySet()
        } else {
            numbers.mapNotNull { tagOf(context, it, create = true) }.toSet()
        }
        val changed = next != tags(context)
        prefs(context).edit().putStringSet(KEY_TAGS, next).apply()
        tags = next
        return changed
    }

    fun setNames(names: Map<String, String>) {
        this.names = names.entries.associate { canonical(it.key) to it.value }
    }

    fun clearNames() {
        names = emptyMap()
    }

    /** The hidden contact's name — only while the section is open, else null. */
    fun nameFor(number: String?): String? =
        if (number.isNullOrBlank()) null else names[canonical(number)]

    fun setSealingKey(context: Context, public: ByteArray) {
        sealing = PublicIdentity.parse(public) // validates before it is stored
        prefs(context).edit()
            .putString(KEY_SEALING, Base64.encodeToString(public, Base64.NO_WRAP))
            .apply()
    }

    fun sealingKey(context: Context): PublicIdentity? {
        sealing?.let { return it }
        val stored = prefs(context).getString(KEY_SEALING, null) ?: return null
        return try {
            PublicIdentity.parse(Base64.decode(stored, Base64.NO_WRAP)).also { sealing = it }
        } catch (e: Exception) {
            Log.w(TAG, "Stored sealing key unreadable: ${e.javaClass.simpleName}")
            null
        }
    }

    /** The section was deleted: nothing is hidden any more, and nothing sealed can be opened. */
    fun forget(context: Context) {
        prefs(context).edit().clear().apply()
        wrapper.delete()
        tagKey = null
        tags = emptySet()
        names = emptyMap()
        sealing = null
    }

    private fun tagOf(context: Context, number: String, create: Boolean): String? {
        val key = key(context, create) ?: return null
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update(TAG_LABEL)
        val digest = mac.doFinal(canonical(number).toByteArray(Charsets.UTF_8))
        return digest.copyOf(TAG_BYTES).joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    private fun key(context: Context, create: Boolean): ByteArray? {
        tagKey?.let { return it }
        val prefs = prefs(context)
        val stored = prefs.getString(KEY_TAG_KEY, null)
        if (stored != null) {
            return try {
                wrapper.unwrap(Base64.decode(stored, Base64.NO_WRAP)).also { tagKey = it }
            } catch (e: Exception) {
                // The Keystore key is gone (data cleared, a broken Keystore):
                // the tags can never match again, so start over.
                Log.w(TAG, "Tag key lost: ${e.javaClass.simpleName}")
                prefs.edit().remove(KEY_TAG_KEY).remove(KEY_TAGS).apply()
                tags = emptySet()
                if (create) key(context, true) else null
            }
        }
        if (!create) return null
        val fresh = ByteArray(32).also(SecureRandom()::nextBytes)
        return try {
            val sealed = wrapper.wrap(fresh)
            prefs.edit().putString(KEY_TAG_KEY, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
            tagKey = fresh
            fresh
        } catch (e: Exception) {
            Log.e(TAG, "Could not create the tag key: ${e.javaClass.simpleName}")
            null
        }
    }
}
