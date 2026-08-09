# R8 / ProGuard rules for «هم‌رسان» (Hamrasan).
#
# Read this before changing anything in the release buildType. Almost every
# class in this app is an ENTRY POINT: the system instantiates it by name from
# the manifest, or telecom/telephony binds it, or it exists only to answer a
# Dart MethodChannel. R8's reachability analysis starts from the manifest and
# from Flutter's registrant, and everything it cannot see a call to is a
# candidate for removal.
#
# Symptom of a missing rule: the build succeeds, the app launches, and then a
# single feature is dead — an SMS never arrives, a call has no UI, a scheduled
# message never fires — with a ClassNotFoundException / NoSuchMethodError in
# `adb logcat` at the moment the system tries to reach the class. It will NOT
# show up in `flutter analyze` or in a debug build.

# ---------------------------------------------------------------------------
# Manifest-declared components
# ---------------------------------------------------------------------------
# AGP feeds aapt2's generated keep rules into R8, so every class named in
# AndroidManifest.xml is already kept. These rules are belt-and-braces and,
# more importantly, DOCUMENTATION of what must never disappear — the manifest
# is the only thing keeping them, so a stray `tools:node="remove"` or a
# refactor that drops a manifest entry silently makes the class strippable.
#
# One wildcard covers the whole app package; the components live at its root
# and in .call / .scheduled / .calllog / .contacts. Keeping them by name only
# (not their members) still lets R8 shrink method bodies it can prove unused,
# while guaranteeing the class + its no-arg constructor survive.
-keep class com.example.communication_super_app.MainActivity { *; }

# Default-SMS-app role: all four role-required components. Losing any one of
# them makes the app ineligible for ROLE_SMS, which silently breaks two-way
# device sync (see CLAUDE.md, "Default SMS app role & device sync").
-keep class com.example.communication_super_app.SmsDeliverReceiver { *; }
-keep class com.example.communication_super_app.MmsReceiver { *; }
-keep class com.example.communication_super_app.HeadlessSmsSendService { *; }
# (the SENDTO/SEND intent-filter lives on MainActivity, kept above)

# Cold-start SMS receive + notification actions. These run with the Flutter
# engine DEAD, so nothing in Dart or in the registrant references them —
# the manifest is their only inbound edge.
-keep class com.example.communication_super_app.IncomingSmsReceiver { *; }
-keep class com.example.communication_super_app.SmsNotificationActionReceiver { *; }

# Default-dialer role. NEVER let CallInCallService be stripped: while the app
# holds ROLE_DIALER it is the ONLY call UI on the device, so an absent class
# means incoming calls have no UI at all.
-keep class com.example.communication_super_app.call.CallInCallService { *; }
-keep class com.example.communication_super_app.call.CallConnectionService { *; }
-keep class com.example.communication_super_app.call.CallConnection { *; }
-keep class com.example.communication_super_app.call.CallActionReceiver { *; }

# Scheduled-SMS background delivery (AlarmManager broadcast + boot re-arm).
# ScheduledSmsAlarmReceiver is reached ONLY from a PendingIntent the system
# stored earlier — an alarm armed by a previous install can name a class that
# this build no longer contains.
-keep class com.example.communication_super_app.scheduled.ScheduledSmsAlarmReceiver { *; }
-keep class com.example.communication_super_app.scheduled.BootReceiver { *; }
-keep class com.example.communication_super_app.scheduled.ScheduledSmsScheduler { *; }
-keep class com.example.communication_super_app.scheduled.ScheduledSmsWorker { *; }

# ---------------------------------------------------------------------------
# Channel handlers — reachable only from Dart
# ---------------------------------------------------------------------------
# These are registered from MainActivity.configureFlutterEngine, so R8 *can*
# see them; they are kept anyway because their public surface is called across
# the platform boundary by string name, and R8's optimizer is free to inline or
# drop a method whose only "caller" is a `when (call.method)` branch it proved
# unreachable after some other rewrite. Keeping them whole costs a few KB and
# removes a whole class of invisible breakage.
-keep class com.example.communication_super_app.SmsHandler { *; }
-keep class com.example.communication_super_app.SmsNotifier { *; }
-keep class com.example.communication_super_app.BlockedNumbers { *; }
-keep class com.example.communication_super_app.call.CallHandler { *; }
-keep class com.example.communication_super_app.call.CallEventStreamHandler { *; }
-keep class com.example.communication_super_app.call.CallEvent { *; }
-keep class com.example.communication_super_app.calllog.CallLogSyncHandler { *; }
-keep class com.example.communication_super_app.contacts.ContactExtrasHandler { *; }
-keep class com.example.communication_super_app.scheduled.ScheduledSmsChannel { *; }

# ---------------------------------------------------------------------------
# Flutter embedding & plugins
# ---------------------------------------------------------------------------
# The engine loads these reflectively; GeneratedPluginRegistrant reflects over
# plugin classes by name.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# flutter_local_notifications serialises scheduled notifications to
# SharedPreferences with Gson. Gson reads the generic signature off the field
# at runtime, so a stripped Signature attribute turns a restored notification
# into a ClassCastException — and the plugin ships NO consumer rules, so this
# has to live here.
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-dontwarn com.google.gson.**
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# ---------------------------------------------------------------------------
# AndroidX / NotificationCompat.CallStyle
# ---------------------------------------------------------------------------
# The incoming-call notification is a NotificationCompat.CallStyle. Compat
# styles are re-instantiated FROM A BUNDLE by name
# (Notification.extras -> androidx.core.app.extra.COMPAT_TEMPLATE), i.e. by
# reflection — a renamed Style class means the notification loses its call
# treatment and its پاسخ/رد buttons on the lock screen, which is precisely the
# path a locked phone depends on.
-keep class androidx.core.app.NotificationCompat$* { *; }
-keep class androidx.core.app.CoreComponentFactory { *; }
-keep class androidx.core.app.RemoteActionCompatParcelizer { *; }
-keep class androidx.versionedparcelable.** { *; }

# ---------------------------------------------------------------------------
# Kotlin coroutines
# ---------------------------------------------------------------------------
# The service loader for the Main dispatcher, plus the atomic-field-updater
# fields coroutines patches reflectively. Without the ServiceLoader entry a
# `Dispatchers.Main` use throws at runtime ("Module with the Main dispatcher is
# missing").
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}
-dontwarn kotlinx.coroutines.**
-dontwarn kotlinx.atomicfu.**

# Kotlin metadata + intrinsics: Kotlin reflection and `Intrinsics` error
# messages read these.
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
-keepclassmembers class **$WhenMappings {
    <fields>;
}
# Deliberately NOT stripping kotlin.jvm.internal.Intrinsics null checks
# (`-assumenosideeffects`). It is a popular size tweak, but it converts a
# precise "parameter X is null" failure into an NPE thrown somewhere further
# down — on a sideloaded build whose only diagnostic is `adb logcat` from the
# user's phone, that trade is not worth the few KB.

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# Keep the desugared-library shims quiet.
-dontwarn j$.**
-dontwarn java.lang.invoke.**
-dontwarn **$$Lambda$*

# Line numbers in a release stack trace, without leaking the original file
# names. Needed to make sense of a crash report from a sideloaded build.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
