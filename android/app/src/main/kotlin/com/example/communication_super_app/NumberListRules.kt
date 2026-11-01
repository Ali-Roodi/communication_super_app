package com.example.communication_super_app

/**
 * «فهرست سیاه و سفید» (matrix row 10, every edition) — who may send this phone
 * an SMS, be sent one from it, call it, or be called from it.
 *
 * Each of the four [Channel]s has its own [Mode]:
 * - [Mode.BLACKLIST] «همه، به‌جز فهرست سیاه» — the default: everybody except a
 *   number matching the black list;
 * - [Mode.WHITELIST] «فقط فهرست سفید» — nobody except a number matching the
 *   white list (and, when [Config.contactsAllowed], a saved contact);
 * - [Mode.NOBODY] «هیچ‌کس».
 *
 * An entry is a number or a pattern ([normalizePattern]): `*` stands for any
 * run of digits, `?` for exactly one. The exact-number list of «هرزنامه و
 * مسدودشده» (`blocked_numbers`) is separate and is checked first, whatever the
 * mode.
 *
 * What no list refuses, in any mode:
 * - **a short number** (fewer than [MIN_SUBSCRIBER_DIGITS] digits) — emergency
 *   and service codes (110, 115, 1818…), USSD, and senders that are a name
 *   rather than a number («MCI»). A list that cut the phone off from the
 *   emergency services or the operator would be a list nobody could safely
 *   switch on; the caller adds the platform's own emergency check for calls;
 * - **a hidden-phonebook contact** — its number must not be written into a
 *   list kept outside the secure section, so it is never asked to be.
 *
 * Pure: the Android lookups are passed in, so the decision is a JVM unit test
 * (`NumberListRulesTest`). [normalizePattern] mirrors `NumberLists.normalizePattern`
 * in Dart — change the two together.
 */
object NumberListRules {
    /** Shorter than this, a number is a service code, never a subscriber. */
    const val MIN_SUBSCRIBER_DIGITS = 7

    /** Fewer digits than this and a pattern matches half the country. */
    private const val MIN_PATTERN_DIGITS = 3

    private const val MAX_PATTERN_LENGTH = 20

    enum class Channel(val key: String) {
        SMS_IN("sms_in"),
        SMS_OUT("sms_out"),
        CALL_IN("call_in"),
        CALL_OUT("call_out");

        companion object {
            fun of(key: String?): Channel? = values().firstOrNull { it.key == key }
        }
    }

    enum class Mode(val key: String) {
        BLACKLIST("blacklist"),
        WHITELIST("whitelist"),
        NOBODY("nobody");

        companion object {
            /** An unknown or missing key is the default, never a restriction. */
            fun of(key: String?): Mode = values().firstOrNull { it.key == key } ?: BLACKLIST
        }
    }

    data class Config(
        val modes: Map<Channel, Mode> = emptyMap(),
        /** Normalised entries ([normalizePattern]). */
        val black: List<String> = emptyList(),
        val white: List<String> = emptyList(),
        /** In [Mode.WHITELIST], a saved contact is allowed too. */
        val contactsAllowed: Boolean = false,
    ) {
        fun modeOf(channel: Channel): Mode = modes[channel] ?: Mode.BLACKLIST
    }

    /**
     * Whether [raw] may use [channel] under [config].
     *
     * [isContact]: true for a saved contact, false for a stranger, null when the
     * address book cannot be read — a whitelist that allows contacts then lets
     * the number through rather than refuse everybody on a phone it cannot see
     * the address book of. Only asked when the answer matters.
     */
    fun allows(
        raw: String,
        channel: Channel,
        config: Config,
        isHidden: () -> Boolean,
        isContact: () -> Boolean?,
    ): Boolean {
        val mode = config.modeOf(channel)
        if (mode == Mode.BLACKLIST && config.black.isEmpty()) return true
        val digits = asciiDigits(raw)
        if (digits.length < MIN_SUBSCRIBER_DIGITS) return true
        if (isHidden()) return true
        val number = BlockedNumbers.normalizeToThreadId(digits)
        return when (mode) {
            Mode.BLACKLIST -> config.black.none { matches(it, number) }
            Mode.WHITELIST -> config.white.any { matches(it, number) } ||
                (config.contactsAllowed && isContact() != false)
            Mode.NOBODY -> false
        }
    }

    /**
     * An entry as the user typed it, in the national form numbers are compared
     * in: `+98 912 *` → `0912*`, `۹۱۲۱۲۳۴۵۶۷` → `09121234567`. Null when it is not
     * usable: a character other than a digit, `*`, `?` or a separator; a foreign
     * number (that is the call rules' business); fewer than three digits; not
     * starting with `0` or a wildcard; or an exact number too short to be a
     * subscriber's (those are never refused anyway).
     */
    fun normalizePattern(input: String): String? {
        val out = StringBuilder()
        var plus = false
        for (c in input.trim()) {
            val d = Character.digit(c, 10)
            when {
                d >= 0 -> out.append('0' + d)
                c == '*' -> if (out.lastOrNull() != '*') out.append('*')
                c == '?' || c == '؟' -> out.append('?')
                c == '+' && out.isEmpty() && !plus -> plus = true
                isSeparator(c) -> Unit
                else -> return null
            }
        }
        val s = out.toString()
        val national = when {
            plus -> if (s.startsWith("98")) "0" + s.substring(2) else return null
            s.startsWith("0098") -> "0" + s.substring(4)
            s.startsWith("00") -> return null
            s.startsWith("98") -> "0" + s.substring(2)
            s.startsWith("9") -> "0$s"
            else -> s
        }
        val digitCount = national.count { it in '0'..'9' }
        if (digitCount < MIN_PATTERN_DIGITS || national.length > MAX_PATTERN_LENGTH) return null
        if (national[0] != '0' && national[0] != '*' && national[0] != '?') return null
        val wildcard = '*' in national || '?' in national
        if (!wildcard && digitCount < MIN_SUBSCRIBER_DIGITS) return null
        return national
    }

    /** Whether the national-form [number] matches the normalised [pattern] whole. */
    fun matches(pattern: String, number: String): Boolean {
        var p = 0
        var n = 0
        var star = -1
        var mark = 0
        while (n < number.length) {
            when {
                p < pattern.length && (pattern[p] == '?' || pattern[p] == number[n]) -> {
                    p++
                    n++
                }
                p < pattern.length && pattern[p] == '*' -> {
                    star = p++
                    mark = n
                }
                star >= 0 -> {
                    p = star + 1
                    n = ++mark
                }
                else -> return false
            }
        }
        while (p < pattern.length && pattern[p] == '*') p++
        return p == pattern.length
    }

    /** The digits of [s], Persian/Arabic ones folded to ASCII. */
    fun asciiDigits(s: String): String = buildString {
        for (c in s) {
            val v = Character.digit(c, 10)
            if (v >= 0) append(('0'.code + v).toChar())
        }
    }

    private fun isSeparator(c: Char): Boolean =
        c == ' ' || c == '-' || c == '(' || c == ')' || c == '.' ||
            c == ' ' || c == '‌' || c == '‎' || c == '‏' ||
            c in '‪'..'‮' || c in '⁦'..'⁩'
}
