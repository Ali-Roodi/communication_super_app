package ir.hamrasan.panel

import ir.hamrasan.keybank.Activation
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * The printable page handed to a member with their password (and activation
 * code) — the half of the delivery that must NOT travel with the key file.
 */
object DeliverySheet {
    fun write(dir: File, organization: String, d: KeysState.Delivery): File {
        dir.mkdirs()
        val file = File(dir, d.file.nameWithoutExtension + ".html")
        file.writeText(html(organization, d), Charsets.UTF_8)
        return file
    }

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    fun html(organization: String, d: KeysState.Delivery): String {
        val activation = d.activationCode?.let {
            """<div class="box"><div class="lbl">کد فعال‌سازی نسخهٔ بین‌سازمانی</div><div class="code">${Activation.display(it)}</div></div>"""
        } ?: ""
        val steps = listOf(
            "<b>نصب:</b> برنامهٔ هم‌رسان را نصب و باز کنید.",
            if (d.activationCode != null) {
                "<b>فعال‌سازی:</b> تنظیمات ← درباره برنامه ← نسخه بین‌سازمانی. کد فعال‌سازی بالا را وارد کنید."
            } else {
                "<b>فعال‌سازی:</b> برنامه باید نسخهٔ بین‌سازمانی باشد (تنظیمات ← درباره برنامه ← نسخه بین‌سازمانی). کد فعال‌سازی را از مسئول بگیرید."
            },
            "<b>فایل کلید:</b> فایل <span class=\"ltr\">${esc(d.file.name)}</span> را جداگانه دریافت کنید و در برنامه از مسیر " +
                "تنظیمات ← بانک کلید ← وارد کردن فایل کلید باز کنید. رمز بالا را وارد کنید (حروف بزرگ و کوچک و خط تیره مهم نیست).",
        ).mapIndexed { i, s -> "<li>${fa(i + 1)}. $s</li>" }.joinToString("\n  ")

        return """<!doctype html>
<html lang="fa" dir="rtl"><head><meta charset="utf-8">
<title>برگهٔ تحویل — ${esc(d.name)}</title>
<style>
  body { font-family: Vazirmatn, Tahoma, sans-serif; color: #1d2430; max-width: 640px; margin: 32px auto; padding: 0 16px; line-height: 1.9; }
  h1 { font-size: 20px; color: #023066; margin: 0; }
  .sub { color: #5a6474; font-size: 13px; margin-bottom: 20px; }
  table { border-collapse: collapse; width: 100%; margin: 12px 0 20px; }
  td { border-bottom: 1px solid #e1e6ee; padding: 8px 4px; }
  td:first-child { color: #5a6474; width: 34%; }
  .ltr { direction: ltr; unicode-bidi: embed; font-family: Consolas, monospace; }
  td.ltr { text-align: right; }
  .box { border: 2px solid #023066; border-radius: 10px; padding: 12px 16px; margin: 12px 0; }
  .lbl { color: #5a6474; font-size: 13px; }
  .code { direction: ltr; text-align: left; font-family: Consolas, monospace; font-size: 26px; font-weight: bold; color: #023066; letter-spacing: 1px; }
  ol { list-style: none; padding: 0; }
  .warn { background: #fff4e5; border-radius: 8px; padding: 10px 14px; font-size: 13px; margin-top: 20px; }
  button { font-family: inherit; font-size: 14px; padding: 6px 18px; margin-top: 16px; }
  @media print { button { display: none; } body { margin: 0 auto; } }
</style></head><body>
<h1>برگهٔ تحویل پیام رمز هم‌رسان</h1>
<div class="sub">${esc(organization)} · <span dir="ltr">${fa(jalaliNow())}</span></div>
<table>
  <tr><td>نام</td><td>${esc(d.name)}</td></tr>
  <tr><td>شماره</td><td class="ltr">${d.phones.joinToString(" · ")}</td></tr>
  <tr><td>نام فایل کلید</td><td class="ltr">${esc(d.file.name)}</td></tr>
</table>
<div class="box"><div class="lbl">رمز فایل کلید</div><div class="code">${esc(d.password ?: "—")}</div></div>
$activation
<ol>
  $steps
</ol>
<div class="warn">این برگه و فایل کلید را از دو راه جدا تحویل بگیرید. بعد از وارد کردن فایل، این برگه را از بین ببرید و فایل را از پیام‌رسان‌ها و حافظه‌های مشترک پاک کنید.</div>
<button onclick="window.print()">چاپ</button>
</body></html>
"""
    }
}

/**
 * Now in the Persian calendar, `1405/07/13 16:37` — the same conversion as
 * the app's `JalaliDate.fromGregorian` (lib/core/utils/jalali_date.dart).
 */
internal fun jalaliNow(now: LocalDateTime = LocalDateTime.now()): String {
    val gDays = intArrayOf(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    val jDays = intArrayOf(31, 31, 31, 31, 31, 31, 30, 30, 30, 30, 30, 29)
    val gy = now.year
    val gy2 = gy - 1600
    var gDayNo = 365 * gy2 + (gy2 + 3) / 4 - (gy2 + 99) / 100 + (gy2 + 399) / 400
    for (i in 0 until now.monthValue - 1) gDayNo += gDays[i]
    if (now.monthValue > 2 && ((gy % 4 == 0 && gy % 100 != 0) || gy % 400 == 0)) gDayNo++
    gDayNo += now.dayOfMonth - 1
    var jDayNo = gDayNo - 79
    val jNp = jDayNo / 12053
    jDayNo %= 12053
    var jy = 979 + 33 * jNp + 4 * (jDayNo / 1461)
    jDayNo %= 1461
    if (jDayNo >= 366) {
        jy += (jDayNo - 1) / 365
        jDayNo = (jDayNo - 1) % 365
    }
    var jm = 0
    while (jm < 11 && jDayNo >= jDays[jm]) {
        jDayNo -= jDays[jm]
        jm++
    }
    return "%d/%02d/%02d %s".format(jy, jm + 1, jDayNo + 1, now.format(DateTimeFormatter.ofPattern("HH:mm")))
}
