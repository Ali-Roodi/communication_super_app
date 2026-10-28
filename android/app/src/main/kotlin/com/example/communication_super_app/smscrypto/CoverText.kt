package com.example.communication_super_app.smscrypto

import java.security.MessageDigest

/**
 * «متن پوششی» (matrix row 31, organization edition): an encrypted SMS sent
 * as ordinary-looking words instead of `#E:` + Base64, and turned back
 * exactly on the other side.
 *
 * The packet is already encrypted and authenticated by its session; this is
 * only its spelling. Two checksum bytes follow it — the first two bytes of
 * SHA-256(`hamresan.cover.v2` ‖ packet) — then a single 1 bit and as many 0
 * bits as reach a multiple of [BITS], and every [BITS] bits become one word
 * of a frozen 4096-word list ([CoverWords], Persian or English). That is the
 * idea of the mentor's «یکتا» (n bits per word from a 2ⁿ-word bank) without
 * its own password layers, which the session already provides; the trailing
 * 1 bit is what lets a receiver drop the padding without a side symbol.
 *
 * Sentences end where a word's value says so ([sentenceEnds]), between
 * [MIN_SENTENCE] and [MAX_SENTENCE] words, and English ones open with a
 * capital: nothing a receiver needs, so it can only make the text read more
 * like text.
 *
 * A receiver needs no key to recognise one: every word must be in one list,
 * the padding must be there and the checksum must hold (a 1-in-65 536
 * accident at most, on at least [MIN_WORDS] list words), so the native
 * receivers turn a cover text back into its `#E:` form ([uncover]) before
 * anything else looks at it, and the rest of the pipeline never knows.
 *
 * Cost: 12 bits a word. A short Persian message (~40 bytes) is ~28 words —
 * 3 SMS parts in Persian cover, 2 in English — against one as `#E:`, which
 * is why only messages and receipts are covered — never a handshake.
 */
object CoverText {
    private const val LABEL = "hamresan.cover.v2"
    private const val CHECK_BYTES = 2

    /** Bits a word carries: the lists have 2^12 words. */
    private const val BITS = 12

    private const val MIN_SENTENCE = 5
    private const val MAX_SENTENCE = 12

    /** The smallest packet a cover carries (20 bytes) with its checksum and padding bit. */
    const val MIN_WORDS = ((20 + CHECK_BYTES) * 8 + 1 + BITS - 1) / BITS

    /** Covers bigger than this are not tried (a handshake is ~1150 bytes). */
    private const val MAX_WORDS = 300

    val PERSIAN: List<String> get() = CoverWords.PERSIAN
    val ENGLISH: List<String> get() = CoverWords.ENGLISH

    private val faIndex: Map<String, Int> by lazy { index(CoverWords.PERSIAN) }
    private val enIndex: Map<String, Int> by lazy { index(CoverWords.ENGLISH) }

    private fun index(words: List<String>): Map<String, Int> {
        check(words.size == 1 shl BITS) { "a cover list has ${1 shl BITS} words" }
        return HashMap<String, Int>(words.size * 2).apply { words.forEachIndexed { i, w -> put(w, i) } }
    }

    enum class Language { PERSIAN, ENGLISH }

    fun encode(packet: ByteArray, language: Language): String {
        val words = if (language == Language.PERSIAN) PERSIAN else ENGLISH
        val values = toValues(packet + check(packet))
        val out = StringBuilder()
        var run = 0
        values.forEachIndexed { i, v ->
            val word = words[v]
            if (i > 0) out.append(' ')
            out.append(if (run == 0 && language == Language.ENGLISH) word.replaceFirstChar(Char::uppercaseChar) else word)
            run++
            if (i < values.size - 1 && sentenceEnds(v, run)) {
                out.append('.')
                run = 0
            }
        }
        return out.append('.').toString()
    }

    /** The packet, or null when [text] is not a cover text. */
    fun decode(text: String): ByteArray? {
        val tokens = text.split(' ', '\n', '\t', '\r')
            .map { normalize(it) }
            .filter { it.isNotEmpty() }
        if (tokens.size < MIN_WORDS || tokens.size > MAX_WORDS) return null
        val index = when {
            faIndex.containsKey(tokens[0]) -> faIndex
            enIndex.containsKey(tokens[0]) -> enIndex
            else -> return null
        }
        val values = IntArray(tokens.size)
        for ((i, t) in tokens.withIndex()) values[i] = index[t] ?: return null
        val bytes = fromValues(values) ?: return null
        if (bytes.size <= CHECK_BYTES) return null
        val packet = bytes.copyOf(bytes.size - CHECK_BYTES)
        val got = bytes.copyOfRange(bytes.size - CHECK_BYTES, bytes.size)
        return if (got.contentEquals(check(packet))) packet else null
    }

    /** A cover text as the `#E:` wire it stands for; anything else as is. */
    fun uncover(text: String): String {
        if (text.startsWith(Wire.PREFIX)) return text
        val packet = decode(text) ?: return text
        return Wire.PREFIX + java.util.Base64.getEncoder().withoutPadding().encodeToString(packet)
    }

    /** Whether a sentence closes after a word of value [v], [run] words into it. */
    private fun sentenceEnds(v: Int, run: Int): Boolean =
        run >= MAX_SENTENCE || (run >= MIN_SENTENCE && v % 5 == 0)

    /** [bytes], then a 1 bit and 0 bits up to a whole word, as word values. */
    private fun toValues(bytes: ByteArray): IntArray {
        val totalBits = bytes.size * 8 + 1
        val count = (totalBits + BITS - 1) / BITS
        val values = IntArray(count)
        for (bit in 0 until totalBits) {
            val one = if (bit < bytes.size * 8) {
                (bytes[bit / 8].toInt() shr (7 - bit % 8)) and 1 == 1
            } else {
                true // the padding's leading 1
            }
            if (one) values[bit / BITS] = values[bit / BITS] or (1 shl (BITS - 1 - bit % BITS))
        }
        return values
    }

    /** The bytes [values] carry, or null when the padding is not a 1 then 0s. */
    private fun fromValues(values: IntArray): ByteArray? {
        val totalBits = values.size * BITS
        fun bitAt(i: Int) = (values[i / BITS] shr (BITS - 1 - i % BITS)) and 1
        var last = totalBits - 1
        while (last >= 0 && bitAt(last) == 0) last--
        // The 1 must sit in the last word, and what is before it must be whole bytes.
        if (last < totalBits - BITS || last % 8 != 0) return null
        val bytes = ByteArray(last / 8)
        for (i in 0 until last) {
            if (bitAt(i) == 1) bytes[i / 8] = (bytes[i / 8].toInt() or (1 shl (7 - i % 8))).toByte()
        }
        return bytes
    }

    private fun normalize(token: String): String {
        val t = token.trim('.', '،', ',', '!', '?', '؟', '؛', ';', ':')
        val sb = StringBuilder(t.length)
        for (ch in t) {
            when (ch) {
                'ي', 'ى' -> sb.append('ی')
                'ك' -> sb.append('ک')
                '‌', '‍', '‎', '‏', 'ً', 'ٌ', 'ٍ',
                'َ', 'ُ', 'ِ', 'ّ', 'ْ' -> Unit
                else -> sb.append(ch.lowercaseChar())
            }
        }
        return sb.toString()
    }

    private fun check(packet: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        md.update(LABEL.toByteArray(Charsets.US_ASCII))
        return md.digest(packet).copyOf(CHECK_BYTES)
    }
}
