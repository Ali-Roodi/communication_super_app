package com.example.communication_super_app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import kotlin.math.abs

/**
 * The round picture a notification carries next to its text.
 *
 * Why this exists: a notification's **small** icon is a one-colour silhouette
 * the system tints and shrinks into the status bar (`ic_stat_message`,
 * `ic_stat_call`), and on most OEM shades — the tester's included — what the
 * card actually shows at full size is the *app's* launcher icon unless the
 * notification supplies a large icon of its own. So every card this app posted
 * looked identical: the same هم‌رسان logo whether it was a message or a missed
 * call, with nothing to say which. Google Messages and Google Phone both answer
 * this the same way, and it is the answer here: the large icon is **who the
 * notification is about**, and the small icon rides it as the badge that says
 * **what kind** it is.
 *
 * When the contact has a photo, that is the large icon. When they do not — an
 * unsaved number, a bank's short code — this draws the same coloured circle
 * with an initial that the rest of the app draws for a contact with no picture,
 * so the shade matches the inbox.
 */
object NotificationAvatars {

    /** Rendered at the density-independent size Android asks large icons for. */
    private const val SIZE = 192

    /**
     * The app's avatar palette. Deliberately the same hues the Dart
     * `AvatarWidget` picks from, so one person is the same colour in the shade
     * as in the conversation list.
     */
    private val COLORS = intArrayOf(
        0xFF1A73E8.toInt(), // blue
        0xFF188038.toInt(), // green
        0xFFD93025.toInt(), // red
        0xFFF29900.toInt(), // amber
        0xFF8430CE.toInt(), // purple
        0xFF007B83.toInt(), // teal
        0xFFC5221F.toInt(), // deep red
        0xFF3949AB.toInt(), // indigo
    )

    /**
     * A circular avatar for [name] (falling back to [key] for its colour).
     *
     * [key] is what makes the colour stable — the normalized number — because
     * [name] can arrive as the number itself on one path and as the contact's
     * name on another, and a person whose circle changes colour between two
     * notifications reads as two people.
     */
    fun letterAvatar(name: String?, key: String): Bitmap {
        val bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val radius = SIZE / 2f

        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = COLORS[abs(key.hashCode()) % COLORS.size]
        canvas.drawCircle(radius, radius, radius, paint)

        val initial = initialOf(name)
        if (initial.isNotEmpty()) {
            val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                textSize = SIZE * 0.42f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
                textAlign = Paint.Align.CENTER
            }
            // Centred on the glyph's own bounds, not on the font's metrics: a
            // Persian letter and a Latin one have very different ascents, and
            // baseline arithmetic puts one of them visibly off-centre.
            val bounds = Rect()
            text.getTextBounds(initial, 0, initial.length, bounds)
            canvas.drawText(initial, radius, radius - bounds.exactCenterY(), text)
        }
        return bitmap
    }

    /**
     * The letter to draw: the first character of the name, unless the "name" is
     * really a phone number — a circle with «۰» in it says nothing, so those
     * get no letter and keep the plain coloured disc.
     */
    private fun initialOf(name: String?): String {
        val trimmed = name?.trim().orEmpty()
        if (trimmed.isEmpty()) return ""
        val first = trimmed.first()
        if (first.isDigit() || first == '+') return ""
        return first.uppercase()
    }
}
