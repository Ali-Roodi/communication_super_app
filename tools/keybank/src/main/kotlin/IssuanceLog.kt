package ir.hamrasan.keybank

import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * «دفتر صدور»: `issuance-log.csv` in the authority's folder — every issue
 * (a member added, edited, given a new key, removed) and every delivery the
 * operator recorded, one line each, appended and never rewritten.
 *
 * It is also where "who has not got their key yet" comes from: the panel
 * cannot see a phone, so it knows only what the operator recorded here
 * ([Action.DELIVERED]). Only a member's own file matters to their phone.
 *
 * A line the parser cannot read is skipped, never fatal: the file is plain
 * CSV and may be opened (and saved) in Excel.
 */
class IssuanceLog(val file: File) {

    enum class Action(val code: String) {
        ADD("add"),
        EDIT("edit"),
        NEW_KEY("new-key"),
        REMOVE("remove"),

        /** The operator handed a member their key file. */
        DELIVERED("delivered");

        val isIssue get() = this == ADD || this == EDIT || this == NEW_KEY || this == REMOVE

        companion object {
            fun of(code: String) = entries.firstOrNull { it.code == code }
        }
    }

    class Entry(
        val time: LocalDateTime,
        val action: Action,
        val member: String,
        /** The member's first number — the one their key is derived from. */
        val phone: String,
        val generation: Int,
        /** How many members the roster had after this line. */
        val members: Int,
        val note: String = "",
    )

    fun read(): List<Entry> {
        if (!file.isFile) return emptyList()
        return file.readText(Charsets.UTF_8).removePrefix(BOM).lines().drop(1).mapNotNull(::parse)
    }

    fun append(entries: List<Entry>) {
        if (entries.isEmpty()) return
        val text = entries.joinToString("") { line(it) + "\r\n" }
        if (!file.isFile || file.length() == 0L) {
            file.writeText(BOM + HEADER + "\r\n" + text, Charsets.UTF_8)
        } else {
            val existing = file.readText(Charsets.UTF_8)
            val sep = if (existing.endsWith("\n")) "" else "\r\n"
            file.appendText(sep + text, Charsets.UTF_8)
        }
    }

    private fun line(e: Entry) = listOf(
        e.time.format(TIME),
        e.action.code,
        e.member,
        e.phone,
        e.generation.toString(),
        e.members.toString(),
        e.note,
    ).joinToString(",") { csv(it) }

    private fun parse(line: String): Entry? {
        if (line.isBlank()) return null
        val f = splitCsv(line)
        if (f.size < 6) return null
        return try {
            Entry(
                time = LocalDateTime.parse(f[0], TIME),
                action = Action.of(f[1]) ?: return null,
                member = f[2],
                phone = f[3],
                generation = f[4].toInt(),
                members = f[5].toInt(),
                note = f.getOrElse(6) { "" },
            )
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        const val FILE = "issuance-log.csv"
        private const val BOM = "﻿"
        private const val HEADER = "time,action,member,phone,generation,members,note"
        private val TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss")

        private fun csv(value: String) =
            if (value.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) {
                "\"" + value.replace("\"", "\"\"").replace("\r", " ").replace("\n", " ") + "\""
            } else {
                value
            }

        /** One CSV line into fields; quotes as Excel writes them. */
        internal fun splitCsv(line: String): List<String> {
            val fields = ArrayList<String>()
            val cur = StringBuilder()
            var quoted = false
            var i = 0
            while (i < line.length) {
                val c = line[i]
                when {
                    quoted && c == '"' && line.getOrNull(i + 1) == '"' -> { cur.append('"'); i++ }
                    c == '"' -> quoted = !quoted
                    c == ',' && !quoted -> { fields += cur.toString(); cur.clear() }
                    else -> cur.append(c)
                }
                i++
            }
            fields += cur.toString().trimEnd('\r')
            return fields
        }
    }
}
