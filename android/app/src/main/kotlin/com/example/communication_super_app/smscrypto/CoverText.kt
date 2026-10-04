package com.example.communication_super_app.smscrypto

import java.security.MessageDigest

/**
 * «متن پوششی» (matrix row 31, organization edition): an encrypted SMS sent
 * as ordinary-looking words instead of `#E:` + Base64, and turned back
 * exactly on the other side.
 *
 * Every byte of the packet becomes one word of a fixed 256-word list
 * (Persian or English), two checksum words follow — the first two bytes of
 * SHA-256(`hamresan.cover.v1` ‖ packet) — and a full stop closes every
 * ninth word. A receiver needs no key to recognise one: every word must be
 * in one list and the checksum must hold (a 1-in-65 536 accident at most,
 * on a message of at least [MIN_WORDS] list words), so the native receivers
 * turn a cover text back into its `#E:` form ([uncover]) before anything
 * else looks at it, and the rest of the pipeline never knows.
 *
 * The lists are **frozen**: a change is a new format, not an edit
 * (`CoverTextTest` pins their hash). Words carry no ZWNJ and no Arabic
 * variants of letters, and a receiver folds those anyway.
 *
 * Cost: one word per byte. A short Persian message (~40 bytes) is 2–3 SMS
 * parts in English cover and 3–4 in Persian, against one as `#E:`, which
 * is why only messages and receipts are covered — never a handshake.
 */
object CoverText {
    private const val LABEL = "hamresan.cover.v1"
    private const val CHECK_BYTES = 2
    private const val SENTENCE = 9

    /** The smallest packet a cover can carry, plus its checksum. */
    const val MIN_WORDS = 20 + CHECK_BYTES

    /** Covers bigger than this are not tried (a handshake is ~1150 bytes). */
    private const val MAX_WORDS = 400

    val PERSIAN: List<String> = (
            "خانه کتاب آب نان باغ گل درخت کوه دریا رود شهر روستا خیابان کوچه مدرسه دانشگاه " +
            "کلاس معلم دانشجو پدر مادر برادر خواهر دوست همسایه مهمان سفر راه جاده ماشین قطار هواپیما " +
            "کشتی دوچرخه بازار مغازه پول قیمت کار شغل اداره شرکت کارگر مدیر جلسه نامه پیام تلفن " +
            "ساعت روز شب صبح ظهر عصر هفته ماه سال بهار تابستان پاییز زمستان باران برف باد " +
            "ابر آفتاب آسمان زمین ستاره دشت جنگل صحرا سنگ چوب آهن طلا نقره میز صندلی تخت " +
            "فرش پنجره در دیوار سقف اتاق آشپزخانه حمام چای قهوه شیر شکر نمک برنج گوشت مرغ " +
            "ماهی سیب پرتقال انگور هندوانه انار خرما گردو بادام پسته غذا سفره بشقاب قاشق چنگال لیوان " +
            "کاسه پیراهن کفش کلاه کیف لباس رنگ سبز آبی قرمز زرد سفید سیاه بزرگ کوچک خوب " +
            "زیبا تازه گرم سرد بلند کوتاه نزدیک دور شاد آرام تند سریع روشن تاریک قلم دفتر " +
            "کاغذ عکس فیلم آهنگ ساز شعر داستان قصه بازی ورزش توپ تیم مسابقه برنده جایزه دکتر " +
            "بیمار دارو بیمارستان سلامت قلب دست پا سر چشم گوش دهان صدا فکر خواب رویا امید " +
            "عشق مهر لبخند خنده گریه سوال جواب درس مشق امتحان نمره فردا امروز دیروز همیشه گاهی " +
            "هرگز اینجا آنجا بالا پایین جلو عقب کنار وسط اول آخر نیمه همه هیچ چند بسیار " +
            "کم زیاد کمی خیلی شاید باید باشد رفت آمد دید گفت خورد نشست ایستاد خواند نوشت " +
            "شنید ساخت داد گرفت برد آورد دوید پرید خندید پرسید ماند گذشت رسید افتاد شکست بست " +
            "کشید ریخت پخت شست دوخت صدف ماسه موج ساحل قایق بندر چراغ شمع کلید قفل جعبه"
        ).split(' ')

    val ENGLISH: List<String> = (
            "time year people way day man thing woman life child world school state family student group " +
            "country problem hand part place case week company system program question work government number night point " +
            "home water room mother area money story fact month lot right study book eye job word " +
            "business issue side kind head house service friend father power hour game line end member law " +
            "car city community name president team minute idea kid body information back parent face others level " +
            "office door health person art war history party result change morning reason research girl guy moment " +
            "air teacher force education foot boy age policy music market sense nation plan college interest death " +
            "experience effect class control care field development role effort rate heart drug show leader light voice " +
            "wife police mind price report decision son view relationship town road arm difference value building action " +
            "model season society tax director position player record paper space ground form event official matter center " +
            "couple site project activity star table need court oil situation cost industry figure street image phone " +
            "data picture practice piece land product doctor wall patient worker news test movie north love support " +
            "technology step baby computer type attention film tree source organization hair window evidence population truth song " +
            "camera garden river summer winter spring autumn island forest bridge flower letter coffee dinner lunch breakfast " +
            "village mountain ocean desert rain snow wind cloud sun moon planet animal bird horse fish dog " +
            "cat bread apple orange lemon sugar salt butter cheese milk tea juice glass plate spoon knife"
        ).split(' ')

    private val faIndex: Map<String, Int> = PERSIAN.withIndex().associate { (i, w) -> w to i }
    private val enIndex: Map<String, Int> = ENGLISH.withIndex().associate { (i, w) -> w to i }

    enum class Language { PERSIAN, ENGLISH }

    fun encode(packet: ByteArray, language: Language): String {
        val words = if (language == Language.PERSIAN) PERSIAN else ENGLISH
        val all = packet + check(packet)
        val out = StringBuilder()
        all.forEachIndexed { i, b ->
            if (i > 0) out.append(if (i % SENTENCE == 0) ". " else " ")
            out.append(words[b.toInt() and 0xFF])
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
        val bytes = ByteArray(tokens.size)
        for ((i, t) in tokens.withIndex()) {
            bytes[i] = (index[t] ?: return null).toByte()
        }
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

    private fun normalize(token: String): String {
        val t = token.trim('.', '،', ',', '!', '?', '؟', '؛', ';', ':')
        val sb = StringBuilder(t.length)
        for (ch in t) {
            when (ch) {
                '\u064A', '\u0649' -> sb.append('\u06CC')
                '\u0643' -> sb.append('\u06A9')
                '\u200C', '\u200D', '\u200E', '\u200F', '\u064B', '\u064C', '\u064D',
                '\u064E', '\u064F', '\u0650', '\u0651', '\u0652' -> Unit
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
