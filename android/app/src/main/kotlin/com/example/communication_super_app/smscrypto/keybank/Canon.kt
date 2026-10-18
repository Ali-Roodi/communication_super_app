package com.example.communication_super_app.smscrypto.keybank

/**
 * The one spelling of what keys and files are derived from: a phone number
 * (a member's key is derived from their first number, a certificate names
 * one) and a key-file password as read out to a member. Two machines must
 * agree on it whatever keyboard typed it.
 *
 * **Frozen**: changing a rule changes every member's key. `KeyBankTest` pins
 * the output.
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
}
