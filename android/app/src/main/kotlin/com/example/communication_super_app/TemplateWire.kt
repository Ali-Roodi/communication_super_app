package com.example.communication_super_app

/**
 * Kotlin mirror of `lib/features/messages/models/template_wire.dart` and of
 * `TemplateEngine` in `lib/features/messages/models/message_template_model.dart`
 * (the non-preview half of `render`, plus `tokensOf`, the connector list and
 * `tidy`) together with the compiled-in catalogue from
 * `lib/features/messages/models/built_in_templates.dart`.
 *
 * **The two must be changed together** — the same contract [ScheduledSmsWorker]
 * has with `scheduled_message_model.dart`. The header regex, the version check,
 * the escaping, the segment splitting, the placeholder order and every template
 * body have to match the Dart character for character: a mismatch does not fail
 * loudly, it silently renders a *different* message than the sender wrote.
 *
 * Why this exists at all: ALL incoming-SMS notifications are posted natively by
 * [SmsNotifier], and a built-in template arrives as a compact payload
 * («[#T1:mtg:1]…»). Without decoding it here the shade would show the raw
 * payload while the chat showed the message.
 *
 * Only the *receive* half is ported. Encoding lives on the send side, which is
 * always Dart (the composer), so there is no Kotlin `encode`. And nothing here
 * rewrites data: what goes into `content://sms` and into the app DB stays the
 * body exactly as it came over the air — decoding is presentation only.
 */
object TemplateWire {
    /** Bumped only for a change older builds cannot parse. Mirrors the Dart. */
    private const val VERSION = 1

    /** Cheap pre-test before the regex — this runs per received SMS. */
    private const val SIGIL = "[#T"

    private val header = Regex("""^\[#T(\d{1,2}):([a-z0-9]{2,6}):(\d{1,3})\]""")

    /** Bit 0: the first payload segment is the «<نام> عزیز» greeting. */
    private const val FLAG_GREETING = 1

    /** `[...]`, no newline inside, capped exactly as in the Dart. */
    private val placeholder = Regex("""\[([^\[\]\n]{1,40})\]""")

    private val runOfSpaces = Regex("""[ \t]{2,}""")
    private val spaceBeforePunctuation = Regex(" +([.،؛:!؟])")

    /**
     * Prepositions that only exist to introduce a placeholder. Longest first, so
     * «در مورخه» is taken over the «در» inside it.
     */
    private val connectors = listOf(
        "در مورخه",
        "در تاریخ",
        "در ساعت",
        "در محل",
        "مورخه",
        "ساعت",
        "بابت",
        "برای",
        "مبلغ",
        "در",
        "به",
        "از",
        "با",
    )

    /** One compiled-in template. [tokens] derive from [body], as in the Dart. */
    private class BuiltIn(val code: String, val title: String, val body: String) {
        val tokens: List<String> by lazy { tokensOf(body) }
    }

    /**
     * The catalogue, byte-identical to `BuiltInTemplates.all`. A code is NEVER
     * reused or repurposed: an old message on someone's phone still decodes
     * through it.
     */
    private val catalogue = listOf(
        BuiltIn(
            "mtg",
            "دعوت‌نامه جلسه",
            "جلسه [عنوان] در مورخه [تاریخ] ساعت [زمان] در محل [مکان] برقرار می‌باشد.\n[توضیحات]",
        ),
        BuiltIn(
            "rmd",
            "یادآوری قرار",
            "یادآوری می‌شود [عنوان] در مورخه [تاریخ] ساعت [زمان] برگزار می‌شود.",
        ),
        BuiltIn(
            "pay",
            "اطلاع واریز",
            "مبلغ [مبلغ] تومان بابت [بابت] در تاریخ [تاریخ] واریز شد.\n[توضیحات]",
        ),
        BuiltIn("cng", "تبریک", "[مناسبت] را صمیمانه به شما تبریک می‌گویم."),
        BuiltIn("thx", "تشکر", "با سلام، از پیگیری و همراهی شما سپاسگزارم."),
        BuiltIn(
            "fup",
            "پیگیری",
            "با سلام، جهت پیگیری موضوع مطرح‌شده مزاحم شدم. ممنون می‌شوم در صورت امکان پاسخ بفرمایید.",
        ),
        BuiltIn("cal", "هماهنگی تماس", "با سلام، چه زمانی برای یک تماس کوتاه در دسترس هستید؟"),
        BuiltIn("apl", "عذرخواهی بابت تأخیر", "با سلام، بابت تأخیر پیش‌آمده پوزش می‌خواهم. [توضیحات]"),
    )

    private val byCode: Map<String, BuiltIn> = catalogue.associateBy { it.code }

    /**
     * What to *show* for a stored message body: the rebuilt message when [body]
     * is a payload this build can decode, otherwise [body] unchanged (ordinary
     * text, a newer format version, or a template this build does not know).
     */
    fun displayText(body: String): String {
        if (!body.startsWith(SIGIL)) return body
        val match = header.find(body) ?: return body
        if (match.groupValues[1].toIntOrNull() != VERSION) return body

        val builtIn = byCode[match.groupValues[2]] ?: return body
        val flags = match.groupValues[3].toIntOrNull() ?: return body
        val segments = splitSegments(body.substring(match.value.length))

        var at = 0
        var greeting: String? = null
        if (flags and FLAG_GREETING != 0 && segments.isNotEmpty()) {
            greeting = segments[at++]
        }

        val values = HashMap<String, String>()
        for (token in builtIn.tokens) {
            if (at >= segments.size) break
            val value = segments[at++]
            if (value.isNotEmpty()) values[token] = value
        }

        val name = if (greeting.isNullOrEmpty()) null else greeting
        return render(builtIn.body, values, name, name != null)
    }

    /** Distinct placeholder names, in the order they appear. */
    private fun tokensOf(body: String): List<String> {
        val names = mutableListOf<String>()
        for (m in placeholder.findAll(body)) {
            val name = m.groupValues[1].trim()
            if (name.isEmpty() || names.contains(name)) continue
            names.add(name)
        }
        return names
    }

    /**
     * Substitutes [values] into [body], dropping unanswered placeholders — the
     * `preview: false` branch of the Dart `TemplateEngine.render` (the preview
     * branch only exists for the fill screen, which has no native counterpart).
     */
    private fun render(
        body: String,
        values: Map<String, String>,
        contactName: String?,
        useContactName: Boolean,
    ): String {
        val filled = StringBuilder()
        var cursor = 0
        for (m in placeholder.findAll(body)) {
            filled.append(body, cursor, m.range.first)
            cursor = m.range.last + 1
            val value = values[m.groupValues[1].trim()]?.trim() ?: ""
            if (value.isNotEmpty()) {
                filled.append(value)
            } else {
                // Dropping the placeholder alone would leave the preposition
                // that introduced it stranded — «در محل برقرار می‌باشد.».
                val kept = dropDanglingConnector(filled.toString())
                filled.setLength(0)
                filled.append(kept)
            }
        }
        filled.append(body, cursor, body.length)

        val text = tidy(filled.toString())
        val name = contactName?.trim()
        if (!useContactName || name.isNullOrEmpty()) return text
        return if (text.isEmpty()) "$name عزیز" else "$name عزیز\n$text"
    }

    /**
     * Removes the preposition [text] ends with, when the placeholder it
     * introduced was dropped. Only an exact trailing word is taken, and only
     * when it stands on its own («…در محل» → «…», but «…مدیر» stays).
     */
    private fun dropDanglingConnector(text: String): String {
        val trimmed = text.trimEnd(' ', '\t')
        for (word in connectors) {
            if (!trimmed.endsWith(word)) continue
            val at = trimmed.length - word.length
            if (at > 0 && !trimmed[at - 1].isWhitespace()) continue
            return trimmed.substring(0, at)
        }
        return text
    }

    /**
     * Collapses the gaps a dropped placeholder leaves behind: doubled spaces, a
     * space before punctuation, and lines that became empty.
     */
    private fun tidy(input: String): String {
        val out = mutableListOf<String>()
        for (raw in input.split('\n')) {
            val line = raw
                .replace(runOfSpaces, " ")
                .replace(spaceBeforePunctuation) { it.groupValues[1] }
                .trim()
            if (line.isEmpty() && (out.isEmpty() || out.last().isEmpty())) continue
            out.add(line)
        }
        while (out.isNotEmpty() && out.last().isEmpty()) out.removeAt(out.size - 1)
        return out.joinToString("\n")
    }

    /**
     * Splits on unescaped `|`, unescaping each segment as it goes. `\` is the
     * escape, `\n` a newline; an escape this version does not define keeps both
     * characters rather than swallowing the backslash.
     */
    private fun splitSegments(payload: String): List<String> {
        if (payload.isEmpty()) return emptyList()
        val segments = mutableListOf<String>()
        val buffer = StringBuilder()
        var i = 0
        while (i < payload.length) {
            val ch = payload[i]
            if (ch == '\\' && i + 1 < payload.length) {
                when (val next = payload[i + 1]) {
                    'n' -> buffer.append('\n')
                    '|' -> buffer.append('|')
                    '\\' -> buffer.append('\\')
                    else -> buffer.append('\\').append(next)
                }
                i += 2
                continue
            }
            if (ch == '|') {
                segments.add(buffer.toString())
                buffer.setLength(0)
                i++
                continue
            }
            buffer.append(ch)
            i++
        }
        segments.add(buffer.toString())
        return segments
    }
}
