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
 * Kinds are append-only: a number, once shipped, keeps its meaning for ever,
 * because old messages are decrypted by newer builds. An unknown kind is
 * [SmsCryptoException.Code.BAD_PAYLOAD] — it was sealed by a newer build.
 */
object Payload {
    const val KIND_TEXT_UTF8 = 0x01
    const val KIND_TEXT_FA = 0x02

    /** A decoded payload. Only text exists so far. */
    class Text(val text: String)

    fun text(text: String): ByteArray {
        val utf8 = text.toByteArray(Charsets.UTF_8)
        val compact = PersianCodePage.encode(text)
        return if (compact.size < utf8.size) {
            byteArrayOf(KIND_TEXT_FA.toByte()) + compact
        } else {
            byteArrayOf(KIND_TEXT_UTF8.toByte()) + utf8
        }
    }

    fun parse(payload: ByteArray): Text {
        if (payload.isEmpty()) badPayload()
        val body = payload.copyOfRange(1, payload.size)
        return when (payload[0].toInt() and 0xFF) {
            KIND_TEXT_UTF8 -> Text(strictUtf8(body) ?: badPayload())
            KIND_TEXT_FA -> Text(PersianCodePage.decode(body) ?: badPayload())
            else -> badPayload()
        }
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
