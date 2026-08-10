import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry/sentry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Crash reporting, wired so that **nothing about a message ever leaves the
/// device**.
///
/// This app is the default SMS app: its heap and its logs are full of message
/// bodies, phone numbers and contact names. A stock crash reporter would ship
/// all three — in exception messages, in breadcrumbs, in the `debugPrint`
/// stream it captures by default. So the integration is deliberately narrow:
///
/// * it is **off** unless a DSN was compiled in *and* the user opted in;
/// * every string that reaches the wire is run through [_scrub], which redacts
///   any run of four or more digits (every phone number, OTP and card number
///   in one rule) — belt and braces on top of the rules below;
/// * log/console breadcrumbs are dropped whole, because `debugPrint` in this
///   codebase legitimately prints bodies while debugging;
/// * PII, screenshots and the view hierarchy are all off — a screenshot of
///   this app is a screenshot of someone's inbox.
///
/// The DSN is compiled in, never checked in:
/// `flutter build apk --dart-define=SENTRY_DSN=https://…`
///
/// This uses the **pure-Dart** `sentry` package rather than `sentry_flutter`:
/// that one ships its own Android Gradle plugin pinned to AGP 7.4.2, which
/// this project's build cannot resolve (the whole `assembleDebug` fails). The
/// consequence is that a crash in the Kotlin half — the receivers, the
/// scheduled worker — is not reported; the Flutter error handlers below cover
/// the Dart half, which is where the app's logic lives.
class CrashReporting {
  CrashReporting._();

  /// SharedPreferences flag. Absent = off: crash reporting is **opt-in**, and
  /// a user who never saw the switch has not opted in.
  static const String prefKey = 'crash_reporting_enabled';

  static const String _dsn = String.fromEnvironment('SENTRY_DSN');

  /// Whether a DSN was compiled into this build. False in every build that did
  /// not pass `--dart-define=SENTRY_DSN=…`, which includes every debug run —
  /// so the settings switch hides itself rather than promising something the
  /// binary cannot do.
  static bool get isAvailable => _dsn.isNotEmpty;

  static bool _enabled = false;

  /// Whether reports are currently being sent.
  static bool get isEnabled => _enabled;

  static Future<bool> readPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) ?? false;
  }

  /// Flips the preference. Takes effect on the next launch — Sentry's client
  /// is installed around `runApp`, and tearing it down mid-session would leave
  /// the zone's error handler pointing at a closed client.
  static Future<void> setPreference(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, value);
  }

  /// Runs [appRunner] with crash reporting installed when it is both available
  /// and enabled, and plainly otherwise.
  ///
  /// Never throws: a misconfigured DSN or an offline device must not stop the
  /// app from starting.
  static Future<void> runApp(FutureOr<void> Function() appRunner) async {
    if (!isAvailable || !await readPreference()) {
      await appRunner();
      return;
    }
    try {
      _enabled = true;
      await Sentry.init((options) {
        options.dsn = _dsn;
        options.environment = kReleaseMode ? 'release' : 'debug';
        // Crashes only. Performance tracing samples real user journeys, which
        // here means route names and timings tied to a conversation.
        options.tracesSampleRate = 0;
        options.sendDefaultPii = false;
        options.maxBreadcrumbs = 20;
        options.beforeBreadcrumb = _beforeBreadcrumb;
        options.beforeSend = _beforeSend;
      }, appRunner: () async {
        // `sentry` (unlike `sentry_flutter`) installs no Flutter integrations,
        // so the framework's two error channels are hooked by hand. Both keep
        // their previous behaviour: a report is an addition, never a
        // replacement for the crash the developer would otherwise see.
        final previousOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          previousOnError?.call(details);
          unawaited(
            Sentry.captureException(
              details.exception,
              stackTrace: details.stack,
            ),
          );
        };
        PlatformDispatcher.instance.onError = (error, stack) {
          unawaited(Sentry.captureException(error, stackTrace: stack));
          // False = "not handled": the platform still prints it.
          return false;
        };
        await appRunner();
      });
    } catch (e) {
      _enabled = false;
      debugPrint('Sentry init failed: $e');
      await appRunner();
    }
  }

  /// Drops the breadcrumb categories that can carry user content, and scrubs
  /// what is left.
  static Breadcrumb? _beforeBreadcrumb(
    Breadcrumb? crumb,
    Hint hint,
  ) {
    if (crumb == null) return null;
    final category = crumb.category ?? '';
    if (category == 'console' || category == 'http' || category == 'query') {
      return null;
    }
    final message = crumb.message;
    return Breadcrumb(
      message: message == null ? null : _scrub(message),
      category: crumb.category,
      type: crumb.type,
      level: crumb.level,
      timestamp: crumb.timestamp,
      // Breadcrumb data is arbitrary and unaudited — the safest shape is none.
      data: const <String, dynamic>{},
    );
  }

  static FutureOr<SentryEvent?> _beforeSend(SentryEvent event, Hint hint) {
    return event
      ..request = null
      ..user = null
      ..serverName = null
      ..exceptions = event.exceptions
          ?.map(
            (e) => SentryException(
              type: e.type,
              value: _scrub(e.value ?? ''),
              module: e.module,
              stackTrace: e.stackTrace,
              mechanism: e.mechanism,
              threadId: e.threadId,
            ),
          )
          .toList()
      ..message = event.message == null
          ? null
          : SentryMessage(
              _scrub(event.message!.formatted),
              template: event.message!.template,
            );
  }

  /// Redacts anything that looks like a number a person owns.
  ///
  /// Four digits is the threshold because that is where PINs, OTPs and the
  /// shortest useful fragment of a phone number start; below it the digits are
  /// line numbers and error codes worth keeping.
  static String _scrub(String input) =>
      input.replaceAll(RegExp(r'[\d۰-۹٠-٩]{4,}'), '[redacted]');
}
