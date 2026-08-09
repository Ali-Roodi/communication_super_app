package com.example.communication_super_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat

/**
 * Single notification pipeline for incoming SMS — used by BOTH receive paths
 * (cold-start [IncomingSmsReceiver] and the live [SmsHandler] dynamic
 * receiver), so every SMS notification has the same look and the same
 * fully-native actions:
 *
 * - **پاسخ** — inline RemoteInput reply, sent by [SmsNotificationActionReceiver]
 *   with SmsManager directly (works with the app dead, backgrounded or open).
 * - **خواندم** — marks the thread read straight in the DB.
 * - Tap — launches MainActivity with a `threadId` extra; the Dart side
 *   deep-links into the conversation.
 */
object SmsNotifier {
    private const val TAG = "SmsNotifier"
    private const val CHANNEL_ID = "sms_channel"

    fun notifySms(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        threadId: String,
    ) {
        try {
            // The user is LOOKING at this conversation right now — no
            // notification (Google Messages behavior). Backgrounded app
            // still notifies even for the "open" thread.
            if (MainActivity.isResumed && MainActivity.visibleThreadId == threadId) {
                Log.d(TAG, "Suppressed notification for visible thread")
                return
            }

            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            ensureChannel(nm)

            // Unique id per message: reusing one id per thread makes Samsung
            // treat rapid re-posts as silent in-place updates (no heads-up).
            val notifId = (timestamp and 0x7FFFFFFF).toInt()
            val title = lookupContactName(context, address) ?: address

            // A built-in template arrives as a compact payload; the shade must
            // show the rebuilt message, exactly like the chat does. Display
            // only — nothing that gets written (content://sms, app DB) is
            // touched, and a body that is not a payload comes back unchanged.
            val text = TemplateWire.displayText(body)

            val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra("threadId", threadId)
                }
            val contentIntent = PendingIntent.getActivity(
                context, threadId.hashCode(), launch ?: Intent(), piFlags,
            )

            // Inline reply (RemoteInput requires a MUTABLE PendingIntent on 31+).
            val remoteInput = androidx.core.app.RemoteInput
                .Builder(SmsNotificationActionReceiver.KEY_REPLY_TEXT)
                .setLabel("پاسخ…")
                .build()
            val mutableFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val replyIntent = PendingIntent.getBroadcast(
                context, notifId,
                Intent(SmsNotificationActionReceiver.ACTION_REPLY)
                    .setPackage(context.packageName)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_ADDRESS, address)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_THREAD_ID, threadId)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_NOTIF_ID, notifId),
                mutableFlags,
            )
            val replyAction = NotificationCompat.Action
                .Builder(0, "پاسخ", replyIntent)
                .addRemoteInput(remoteInput)
                .setAllowGeneratedReplies(false)
                .build()

            val markReadIntent = PendingIntent.getBroadcast(
                context, notifId + 1,
                Intent(SmsNotificationActionReceiver.ACTION_MARK_READ)
                    .setPackage(context.packageName)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_THREAD_ID, threadId)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_NOTIF_ID, notifId),
                piFlags,
            )

            // MessagingStyle + Person: the sender's name and contact photo
            // render in the notification exactly like Google Messages.
            val avatar = lookupContactPhoto(context, address)
            val sender = Person.Builder()
                .setName(title)
                .apply { if (avatar != null) setIcon(IconCompat.createWithBitmap(avatar)) }
                .build()
            val style = NotificationCompat.MessagingStyle(sender)
                .addMessage(text, timestamp, sender)

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(style)
                .apply { if (avatar != null) setLargeIcon(avatar) }
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setAutoCancel(true)
                .setContentIntent(contentIntent)
                .addAction(replyAction)
                .addAction(0, "خواندم", markReadIntent)
                .build()

            // Tagged with the threadId so opening the conversation can dismiss
            // every notification belonging to it (see [cancelThread]).
            nm.notify(threadId, notifId, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post SMS notification: ${e.message}", e)
        }
    }

    /** Dismisses every posted SMS notification tagged with [threadId]. */
    fun cancelThread(context: Context, threadId: String) {
        try {
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                nm.activeNotifications
                    .filter { it.tag == threadId }
                    .forEach { nm.cancel(it.tag, it.id) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "cancelThread failed: ${e.message}")
        }
    }

    private fun ensureChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "پیام‌های کوتاه", NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "اعلان‌های پیام‌های کوتاه دریافتی"
                    enableVibration(true)
                    enableLights(true)
                },
            )
        }
    }

    /** The contact's photo thumbnail (round-cropped by the system), or null. */
    private fun lookupContactPhoto(context: Context, phone: String): Bitmap? {
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone),
            )
            val photoUri = context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.PHOTO_THUMBNAIL_URI),
                null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                ?: return null
            context.contentResolver.openInputStream(Uri.parse(photoUri))?.use {
                BitmapFactory.decodeStream(it)
            }
        } catch (e: Exception) {
            null
        }
    }

    fun lookupContactName(context: Context, phone: String): String? {
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone),
            )
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (e: SecurityException) {
            null // READ_CONTACTS not granted
        } catch (e: Exception) {
            null
        }
    }
}
