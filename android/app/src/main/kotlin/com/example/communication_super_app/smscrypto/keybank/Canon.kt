package com.example.communication_super_app.smscrypto.keybank

import java.text.Normalizer
import java.util.Locale

/**
 * The one spelling of the text that keys are derived from.
 *
 * Two phones must derive **the same key** from what two people typed on two
 * different keyboards. A Persian keyboard, an Arabic one and a phone's
 * autocorrect disagree on ی/ي, ک/ك, digits, half-spaces and a capital first
 * letter; each disagreement would silently produce a different key and
 * messages that simply never decrypt. Everything derived from typed text goes
 * through here first.
 *
 * **Frozen**, like the code page: changing a rule changes every group key.
 * `KeyBankTest` pins the output of both functions.
 */
object Canon {
    /**
     * A phone number as the key derivation sees it: digits only (Persian and
     * Arabic digits folded), Iranian numbers in national form — `+98912…`,
     * `0098912…`, `98912…` and `912…` all become `0912…`. Other international
     * numbers keep their `00` prefix. Null for anything that is not a number.
     */
    fun phone(raw: String): String? {
        val digits = StringBuilder()
        var international = false
        for (c in raw) {
            val d = digit(c)
            when {
                d >= 0 -> digits.append(('0' + d))
                c == '+' && digits.isEmpty() -> international = true
            }
        }
        var number = if (international) "00$digits" else digits.toString()
        number = when {
            number.startsWith("0098") -> "0" + number.substring(4)
            number.startsWith("98") && number.length == 12 -> "0" + number.substring(2)
            number.length == 10 && number.startsWith("9") -> "0$number"
            else -> number
        }
        return if (number.length in 5..17) number else null
    }

    /**
     * A passphrase or group name: NFKC; Arabic letter forms folded to the
     * Persian ones (ي ى → ی, ك → ک, ة → ه, أ إ آ → ا, ؤ → و); every digit to
     * ASCII; half-spaces, bidi marks, tatweel and harakat dropped; Latin
     * lowercased (a keyboard capitalises the first letter on its own); runs of
     * white space to one space, trimmed.
     */
    fun text(raw: String): String {
        val normalized = Normalizer.normalize(raw, Normalizer.Form.NFKC)
        val out = StringBuilder(normalized.length)
        var pendingSpace = false
        for (c in normalized) {
            val code = c.code
            if (code in DROPPED || code in 0x064B..0x0652) continue
            if (Character.isWhitespace(c) || code == 0x00A0) {
                pendingSpace = out.isNotEmpty()
                continue
            }
            if (pendingSpace) {
                out.append(' ')
                pendingSpace = false
            }
            val d = digit(c)
            out.append(if (d >= 0) '0' + d else FOLD[code]?.toChar() ?: c)
        }
        return out.toString().lowercase(Locale.ROOT)
    }

    /**
     * A key-file password as typed: its letters and digits only (Persian
     * digits folded), uppercased — the tool prints it in dashed groups and
     * people read it out, so dashes, spaces and case must not matter.
     */
    fun keyFilePassword(raw: String): String {
        val out = StringBuilder(raw.length)
        for (c in raw) {
            val d = digit(c)
            when {
                d >= 0 -> out.append('0' + d)
                c in 'a'..'z' || c in 'A'..'Z' -> out.append(c.uppercaseChar())
            }
        }
        return out.toString()
    }

    private fun digit(c: Char): Int = when (c.code) {
        in 0x30..0x39 -> c.code - 0x30
        in 0x06F0..0x06F9 -> c.code - 0x06F0
        in 0x0660..0x0669 -> c.code - 0x0660
        else -> -1
    }

    /** ZWNJ, ZWJ, LRM, RLM, the bidi embeddings and isolates, tatweel, superscript alef, hamza above, BOM. */
    private val DROPPED: Set<Int> = setOf(
        0x200C, 0x200D, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
        0x0640, 0x0670, 0x0654, 0xFEFF,
    )

    private val FOLD: Map<Int, Int> = mapOf(
        0x064A to 0x06CC, // ي → ی
        0x0649 to 0x06CC, // ى → ی
        0x0643 to 0x06A9, // ك → ک
        0x0629 to 0x0647, // ة → ه
        0x0623 to 0x0627, // أ → ا
        0x0625 to 0x0627, // إ → ا
        0x0622 to 0x0627, // آ → ا
        0x0624 to 0x0648, // ؤ → و
    )
}
