package com.example.communication_super_app.call

import com.example.communication_super_app.BlockedNumbers

/**
 * The «مسدود کردن تماس» rules beyond the blocked list — decided for a RINGING
 * call in `CallInCallService.onCallAdded`, before the user is shown anything.
 *
 * Pure: everything that needs Android (the contacts lookup, the call log) is
 * passed in as a function, so the decision itself is a JVM unit test
 * (`CallRulesTest`). The functions are only called when a rule could block the
 * call, which keeps a contacts query off the ringing path for everybody who
 * has not turned a rule on.
 *
 * What is never blocked by a rule, whatever is switched on:
 * - **a saved contact** (or a hidden-phonebook contact) — the user said who
 *   they want to hear from;
 * - **a number the user called in the last [RECENT_OUTGOING_DAYS] days** — the
 *   courier, the clinic, the plumber calling back. Blocking the call you are
 *   waiting for is the commonest way such a switch gets turned off again;
 * - **a service number** (fewer than [MIN_SUBSCRIBER_DIGITS] digits: 110, 115,
 *   125, 1818…) — emergency services call back from these.
 *
 * A caller with no number at all is not decided here: that is
 * «مسدود کردن تماس‌های ناشناس» (`isUnidentified`), which runs first.
 */
object CallRules {
    /** Shorter than this, a number is a service code, never a subscriber. */
    const val MIN_SUBSCRIBER_DIGITS = 7

    const val RECENT_OUTGOING_DAYS = 7

    /** The country this app's numbers are in; a call from any other is foreign. */
    private const val HOME_CODE = "98"

    data class Rules(
        val nonContacts: Boolean = false,
        val international: Boolean = false,
        val advertising: Boolean = false,
        /** Canonical prefixes (see [normalizePrefix]). */
        val adPrefixes: Set<String> = emptySet(),
    ) {
        val any: Boolean get() = nonContacts || international || advertising
    }

    enum class Verdict { ALLOW, NON_CONTACT, INTERNATIONAL, ADVERTISING }

    /**
     * [isKnown]: true for a saved or hidden contact, false for a stranger, null
     * when it could not be told (no contacts permission, provider error) — the
     * "not in my contacts" rule then lets the call through rather than block
     * every caller on a phone it cannot see the address book of.
     */
    fun decide(
        raw: String,
        rules: Rules,
        isKnown: () -> Boolean?,
        calledRecently: () -> Boolean,
    ): Verdict {
        if (!rules.any) return Verdict.ALLOW
        if (asciiDigits(raw).length < MIN_SUBSCRIBER_DIGITS) return Verdict.ALLOW

        val foreign = rules.international && isInternational(raw)
        val advertising = rules.advertising && matchesPrefix(raw, rules.adPrefixes)
        if (!rules.nonContacts && !foreign && !advertising) return Verdict.ALLOW

        val known = isKnown()
        if (known == true) return Verdict.ALLOW
        if (calledRecently()) return Verdict.ALLOW

        return when {
            rules.nonContacts && known == false -> Verdict.NON_CONTACT
            foreign -> Verdict.INTERNATIONAL
            advertising -> Verdict.ADVERTISING
            else -> Verdict.ALLOW
        }
    }

    /**
     * Whether [raw] is dialled from outside the country: an international
     * prefix (`+` or `00`) followed by anything but 98. A number without one is
     * domestic — that is how every operator here presents a local caller,
     * `09…`, `0…` or `98…` alike.
     */
    fun isInternational(raw: String): Boolean {
        val s = raw.trim()
        val digits = asciiDigits(s)
        return when {
            s.startsWith("+") -> digits.isNotEmpty() && !digits.startsWith(HOME_CODE)
            digits.startsWith("00") -> !digits.startsWith("00$HOME_CODE")
            else -> false
        }
    }

    /** Whether [raw]'s national form starts with one of [prefixes]. */
    fun matchesPrefix(raw: String, prefixes: Collection<String>): Boolean {
        if (prefixes.isEmpty()) return false
        val national = BlockedNumbers.normalizeToThreadId(asciiDigitsKeepPlus(raw))
        return prefixes.any { it.isNotEmpty() && national.startsWith(it) }
    }

    /**
     * A prefix as the user typed it (`0942`, `+98942`, `98942`, `۰۹۴۲`) in the
     * national form numbers are compared in (`0942`); null when it is not a
     * usable prefix. Mirrors `CallBlockRules.normalizePrefix` in Dart.
     */
    fun normalizePrefix(input: String): String? {
        val digits = asciiDigits(input)
        val national = when {
            digits.startsWith("00$HOME_CODE") -> "0" + digits.substring(4)
            digits.startsWith(HOME_CODE) -> "0" + digits.substring(2)
            digits.startsWith("9") -> "0$digits"
            else -> digits
        }
        // `0` + at least three digits: anything shorter matches half the country.
        return if (national.length >= 4 && national.startsWith("0")) national else null
    }

    /** The digits of [s], Persian/Arabic ones folded to ASCII. */
    fun asciiDigits(s: String): String = buildString {
        for (c in s) {
            val v = Character.digit(c, 10)
            if (v >= 0) append(('0'.code + v).toChar())
        }
    }

    private fun asciiDigitsKeepPlus(s: String): String {
        val t = s.trim()
        return (if (t.startsWith("+")) "+" else "") + asciiDigits(t)
    }
}
