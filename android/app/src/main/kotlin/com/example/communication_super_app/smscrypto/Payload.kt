package com.example.communication_super_app.smscrypto

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * What goes inside a sealed message: one **kind** byte, then its content.
 *
 * Text is written in whichever of two encodings is shorter, because every
 * byte saved here is 1⅓ characters less SMS:
 *
 * - [KIND_TEXT_UTF8] — plain UTF-8; Persian costs 2 bytes a letter.
 * - [KIND_TEXT_FA] — [PersianCodePage]: ASCII and the Persian repertoire in
 *   one byte each, anything else escaped. A Persian message is half the size.
 *
 * A text kind with [FLAG_DELETE_AFTER_SEEN] set is «حذف پس از دیدن»: the
 * receiver removes it once it has been shown (the sender's choice, per
 * message). Control kinds carry no text and are never shown as bubbles:
 *
 * - [KIND_SEEN] `sid ‖ counter` — "I have seen every message you sent me in
 *   session `sid` up to and including `counter`" (one for many: each costs
 *   an SMS).
 * - [KIND_DELETE] `sid ‖ counter` — "delete the message I sent you as
 *   `counter` in session `sid`" («حذف برای هر دو»).
 * - [KIND_GROUP_INFO] — a group's name, mode and members, from its creator
 *   ([GroupInfo]); sent before a member's first group message and whenever
 *   the group changes.
 *
 * A text kind with [FLAG_GROUP] set is a **group message**: an 8-byte group
 * id follows the kind byte, then the text. SMS has no multicast — a group
 * message is sealed once per member, over each member's own session — so the
 * id is all that makes it a group's.
 *
 * A message is named by the session and counter it travelled with — unique,
 * known to both sides, and free (no id on the wire).
 *
 * Kinds are append-only: a number, once shipped, keeps its meaning for ever,
 * because old messages are decrypted by newer builds. An unknown kind is
 * [SmsCryptoException.Code.BAD_PAYLOAD] — it was sealed by a newer build.
 */
object Payload {
    const val KIND_TEXT_UTF8 = 0x01
    const val KIND_TEXT_FA = 0x02
    const val KIND_SEEN = 0x10
    const val KIND_DELETE = 0x11
    const val KIND_GROUP_INFO = 0x12

    /** On a text kind: delete once seen. */
    const val FLAG_DELETE_AFTER_SEEN = 0x80

    /** On a text kind: a group message; [GROUP_ID_BYTES] of group id follow. */
    const val FLAG_GROUP = 0x40
    const val GROUP_ID_BYTES = 8

    /** Every member reply goes to all members. */
    const val GROUP_MODE_CHAT = 0

    /** Members reply to the creator only (an announcement list). */
    const val GROUP_MODE_ANNOUNCE = 1

    private const val MAX_GROUP_MEMBERS = 100
    private const val MAX_PHONE_DIGITS = 15
    private const val MAX_GROUP_NAME_BYTES = 200

    sealed class Decoded

    class Text(
        val text: String,
        val deleteAfterSeen: Boolean = false,
        /** Set for a group message. */
        val groupId: ByteArray? = null,
    ) : Decoded()

    class GroupMember(val phone: String, val keyId: ByteArray)

    /**
     * A group as its creator defines it. [version] grows with every change,
     * so a receiver keeps only the newest; [members] carry key ids so each
     * phone can find itself (it may not know its own number).
     */
    class GroupInfo(
        val groupId: ByteArray,
        val version: Long,
        val mode: Int,
        val name: String,
        val members: List<GroupMember>,
    ) : Decoded()

    /** Every message up to [upTo] in session [sid] was seen. */
    class Seen(val sid: Int, val upTo: Long) : Decoded()

    /** Delete the message [counter] of session [sid]. */
    class Delete(val sid: Int, val counter: Long) : Decoded()

    fun text(text: String, deleteAfterSeen: Boolean = false): ByteArray {
        val flag = if (deleteAfterSeen) FLAG_DELETE_AFTER_SEEN else 0
        val utf8 = text.toByteArray(Charsets.UTF_8)
        val compact = PersianCodePage.encode(text)
        return if (compact.size < utf8.size) {
            byteArrayOf((KIND_TEXT_FA or flag).toByte()) + compact
        } else {
            byteArrayOf((KIND_TEXT_UTF8 or flag).toByte()) + utf8
        }
    }

    fun groupText(groupId: ByteArray, text: String, deleteAfterSeen: Boolean = false): ByteArray {
        require(groupId.size == GROUP_ID_BYTES) { "group id must be $GROUP_ID_BYTES bytes" }
        val plain = text(text, deleteAfterSeen)
        return byteArrayOf(((plain[0].toInt() and 0xFF) or FLAG_GROUP).toByte()) +
            groupId + plain.copyOfRange(1, plain.size)
    }

    fun groupInfo(info: GroupInfo): ByteArray {
        require(info.groupId.size == GROUP_ID_BYTES) { "group id must be $GROUP_ID_BYTES bytes" }
        require(info.mode == GROUP_MODE_CHAT || info.mode == GROUP_MODE_ANNOUNCE) { "unknown mode" }
        require(info.members.size in 1..MAX_GROUP_MEMBERS) { "bad member count" }
        require(info.version in 0..Wire.MAX_COUNTER) { "bad version" }
        val name = PersianCodePage.encode(info.name)
        require(name.size <= MAX_GROUP_NAME_BYTES) { "group name too long" }
        val out = ByteArrayOutputStream()
        out.write(KIND_GROUP_INFO)
        out.write(info.groupId)
        out.write(Wire.writeVarint(info.version))
        out.write(info.mode)
        out.write(Wire.writeVarint(name.size.toLong()))
        out.write(name)
        out.write(info.members.size)
        for (m in info.members) {
            require(m.keyId.size == PublicIdentity.KEY_ID_BYTES) { "bad key id" }
            out.write(packDigits(m.phone))
            out.write(m.keyId)
        }
        return out.toByteArray()
    }

    /** A phone as its digit count and packed BCD (`0x0F` pads an odd count). */
    private fun packDigits(phone: String): ByteArray {
        require(phone.isNotEmpty() && phone.length <= MAX_PHONE_DIGITS && phone.all { it in '0'..'9' }) {
            "a member phone must be 1..$MAX_PHONE_DIGITS ASCII digits"
        }
        val out = ByteArray(1 + (phone.length + 1) / 2)
        out[0] = phone.length.toByte()
        for (i in phone.indices step 2) {
            val hi = phone[i] - '0'
            val lo = if (i + 1 < phone.length) phone[i + 1] - '0' else 0x0F
            out[1 + i / 2] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    fun seen(sid: Int, upTo: Long): ByteArray = reference(KIND_SEEN, sid, upTo)

    fun delete(sid: Int, counter: Long): ByteArray = reference(KIND_DELETE, sid, counter)

    private fun reference(kind: Int, sid: Int, counter: Long): ByteArray {
        require(sid in 0..0xFFFF && counter in 0..Wire.MAX_COUNTER)
        return byteArrayOf(kind.toByte()) + Wire.writeSid(sid) + Wire.writeVarint(counter)
    }

    fun parse(payload: ByteArray): Decoded {
        if (payload.isEmpty()) badPayload()
        val kind = payload[0].toInt() and 0xFF
        val body = payload.copyOfRange(1, payload.size)
        val flagged = kind and FLAG_DELETE_AFTER_SEEN != 0
        val group = kind and FLAG_GROUP != 0
        val base = kind and (FLAG_DELETE_AFTER_SEEN or FLAG_GROUP).inv()
        if (group && base != KIND_TEXT_UTF8 && base != KIND_TEXT_FA) badPayload()
        val (groupId, textBytes) = if (group) {
            if (body.size < GROUP_ID_BYTES) badPayload()
            body.copyOf(GROUP_ID_BYTES) to body.copyOfRange(GROUP_ID_BYTES, body.size)
        } else {
            null to body
        }
        return when (base) {
            KIND_TEXT_UTF8 -> Text(strictUtf8(textBytes) ?: badPayload(), flagged, groupId)
            KIND_TEXT_FA -> Text(PersianCodePage.decode(textBytes) ?: badPayload(), flagged, groupId)
            KIND_SEEN -> if (flagged) badPayload() else parseReference(body) { sid, n -> Seen(sid, n) }
            KIND_DELETE -> if (flagged) badPayload() else parseReference(body) { sid, n -> Delete(sid, n) }
            KIND_GROUP_INFO -> if (flagged) badPayload() else parseGroupInfo(body)
            else -> badPayload()
        }
    }

    private fun parseGroupInfo(body: ByteArray): GroupInfo {
        var at = 0
        fun need(n: Int) {
            if (at + n > body.size) badPayload()
        }
        fun varint(): Long {
            val (value, length) = Wire.readVarint(body, at) ?: badPayload()
            at += length
            return value
        }
        need(GROUP_ID_BYTES)
        val groupId = body.copyOfRange(at, at + GROUP_ID_BYTES)
        at += GROUP_ID_BYTES
        val version = varint()
        if (version > Wire.MAX_COUNTER) badPayload()
        need(1)
        val mode = body[at++].toInt() and 0xFF
        if (mode != GROUP_MODE_CHAT && mode != GROUP_MODE_ANNOUNCE) badPayload()
        val nameLength = varint()
        if (nameLength > MAX_GROUP_NAME_BYTES) badPayload()
        need(nameLength.toInt())
        val name = PersianCodePage.decode(body.copyOfRange(at, at + nameLength.toInt())) ?: badPayload()
        at += nameLength.toInt()
        need(1)
        val count = body[at++].toInt() and 0xFF
        if (count !in 1..MAX_GROUP_MEMBERS) badPayload()
        val members = ArrayList<GroupMember>(count)
        repeat(count) {
            need(1)
            val digits = body[at++].toInt() and 0xFF
            if (digits !in 1..MAX_PHONE_DIGITS) badPayload()
            val packed = (digits + 1) / 2
            need(packed + PublicIdentity.KEY_ID_BYTES)
            val phone = StringBuilder(digits)
            for (i in 0 until digits) {
                val b = body[at + i / 2].toInt() and 0xFF
                val nibble = if (i % 2 == 0) b shr 4 else b and 0x0F
                if (nibble > 9) badPayload()
                phone.append('0' + nibble)
            }
            // The pad nibble of an odd count must be the pad, nothing else.
            if (digits % 2 == 1 && (body[at + packed - 1].toInt() and 0x0F) != 0x0F) badPayload()
            at += packed
            members.add(GroupMember(phone.toString(), body.copyOfRange(at, at + PublicIdentity.KEY_ID_BYTES)))
            at += PublicIdentity.KEY_ID_BYTES
        }
        if (at != body.size) badPayload()
        return GroupInfo(groupId, version, mode, name, members)
    }

    private fun parseReference(body: ByteArray, make: (Int, Long) -> Decoded): Decoded {
        if (body.size < 3) badPayload()
        val sid = ((body[0].toInt() and 0xFF) shl 8) or (body[1].toInt() and 0xFF)
        val (counter, length) = Wire.readVarint(body, 2) ?: badPayload()
        if (2 + length != body.size || counter > Wire.MAX_COUNTER) badPayload()
        return make(sid, counter)
    }

    /** UTF-8 that refuses malformed input instead of substituting U+FFFD. */
    internal fun strictUtf8(bytes: ByteArray): String? =
        try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (e: CharacterCodingException) {
            null
        }

    private fun badPayload(): Nothing =
        cryptoError(SmsCryptoException.Code.BAD_PAYLOAD, "unknown payload")
}

/**
 * A one-byte encoding of Persian text («هم‌رسان code page 1»).
 *
 * - `0x00–0x7F` — ASCII, unchanged.
 * - `0x80–0xE0` — [TABLE], in order: the Persian letters, the Arabic forms a
 *   Persian keyboard still produces (ي ك ة …), ZWNJ/ZWJ, both digit sets,
 *   Persian punctuation, the harakat and the typographic marks that
 *   commonly appear in Persian text.
 * - `0xFF` — escape: the next bytes are one character in UTF-8 (an emoji, a
 *   Latin accent), so one such character does not push the whole message
 *   back to two bytes a letter.
 * - anything else — invalid.
 *
 * **The table is frozen.** Messages already sent are decoded through it; a
 * change means a new kind in [Payload], never an edit here.
 */
internal object PersianCodePage {
    private const val FIRST = 0x80
    private const val ESCAPE = 0xFF

    /** 97 characters, `0x80` upward. Written as escapes: the source must not depend on bidi rendering. */
    private const val TABLE =
        // Persian letters (32): ا ب پ ت ث ج چ ح خ د ذ ر ز ژ س ش ص ض ط ظ ع غ ف ق ک گ ل م ن و ه ی
        "\u0627\u0628\u067E\u062A\u062B\u062C\u0686\u062D\u062E\u062F\u0630\u0631\u0632\u0698" +
            "\u0633\u0634\u0635\u0636\u0637\u0638\u0639\u063A\u0641\u0642\u06A9\u06AF\u0644\u0645" +
            "\u0646\u0648\u0647\u06CC" +
            // Other letter forms (9): آ ء أ ؤ إ ئ ة ي ك
            "\u0622\u0621\u0623\u0624\u0625\u0626\u0629\u064A\u0643" +
            // ZWNJ, ZWJ (2)
            "\u200C\u200D" +
            // Persian digits ۰–۹ (10), Arabic-Indic digits ٠–٩ (10)
            "\u06F0\u06F1\u06F2\u06F3\u06F4\u06F5\u06F6\u06F7\u06F8\u06F9" +
            "\u0660\u0661\u0662\u0663\u0664\u0665\u0666\u0667\u0668\u0669" +
            // Punctuation (9): ، ؛ ؟ « » ٪ ٫ ٬ ـ
            "\u060C\u061B\u061F\u00AB\u00BB\u066A\u066B\u066C\u0640" +
            // Harakat (9): fathatan … sukun, superscript alef
            "\u064B\u064C\u064D\u064E\u064F\u0650\u0651\u0652\u0670" +
            // Typography (14): … – — NBSP “ ” ‘ ’ LRM RLM ﷼ • × ÷
            "\u2026\u2013\u2014\u00A0\u201C\u201D\u2018\u2019\u200E\u200F\uFDFC\u2022\u00D7\u00F7" +
            // ۀ, hamza above (2)
            "\u06C0\u0654"

    private val codes: Map<Char, Int> = TABLE.withIndex().associate { (i, c) -> c to FIRST + i }

    init {
        check(TABLE.length == 97 && codes.size == TABLE.length) { "code page table is corrupt" }
    }

    fun encode(text: String): ByteArray {
        val out = ByteArrayOutputStream(text.length)
        var i = 0
        while (i < text.length) {
            val c = text[i]
            val code = if (c.code < FIRST) c.code else codes[c]
            if (code != null) {
                out.write(code)
                i++
                continue
            }
            val cp = text.codePointAt(i)
            val count = Character.charCount(cp)
            out.write(ESCAPE)
            out.write(text.substring(i, i + count).toByteArray(Charsets.UTF_8))
            i += count
        }
        return out.toByteArray()
    }

    /** The text, or null for bytes no [encode] produced. */
    fun decode(bytes: ByteArray): String? {
        val out = StringBuilder(bytes.size)
        var i = 0
        while (i < bytes.size) {
            val b = bytes[i].toInt() and 0xFF
            when {
                b < FIRST -> {
                    out.append(b.toChar())
                    i++
                }
                b - FIRST < TABLE.length -> {
                    out.append(TABLE[b - FIRST])
                    i++
                }
                b == ESCAPE -> {
                    val lead = bytes.getOrNull(i + 1)?.toInt()?.and(0xFF) ?: return null
                    val length = when {
                        lead < 0x80 -> 1
                        lead in 0xC2..0xDF -> 2
                        lead in 0xE0..0xEF -> 3
                        lead in 0xF0..0xF4 -> 4
                        else -> return null
                    }
                    if (i + 1 + length > bytes.size) return null
                    out.append(Payload.strictUtf8(bytes.copyOfRange(i + 1, i + 1 + length)) ?: return null)
                    i += 1 + length
                }
                else -> return null
            }
        }
        return out.toString()
    }
}
