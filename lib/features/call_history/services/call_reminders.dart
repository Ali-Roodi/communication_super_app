import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a reminder takes the user to: the keypad or the composer.
enum CallReminderKind { call, sms }

/// One pending «یادآور», as `reminders/CallReminders.kt` holds it.
class CallReminder {
  const CallReminder({
    required this.id,
    required this.number,
    required this.kind,
    required this.at,
    this.name,
  });

  final String id;
  final String number;
  final CallReminderKind kind;
  final DateTime at;
  final String? name;

  static CallReminder fromMap(Map<Object?, Object?> map) => CallReminder(
    id: map['id']! as String,
    number: map['number']! as String,
    kind: map['kind'] == 'sms' ? CallReminderKind.sms : CallReminderKind.call,
    at: DateTime.fromMillisecondsSinceEpoch((map['at']! as num).toInt()),
    name: map['name'] as String?,
  );
}

/// «یادآور تماس / پیامک» (matrix row 39). Kotlin owns the list and the alarm,
/// because they have to work with no engine; this mirrors the list for the
/// «اخیر» tab.
class CallReminders {
  CallReminders._();

  static final CallReminders instance = CallReminders._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/call_reminders',
  );

  /// The pending reminders, soonest first; empty until [refresh] has run.
  final ValueNotifier<List<CallReminder>> pending = ValueNotifier(const []);

  bool _listening = false;

  /// Listens for changes made natively (one fired, or was snoozed) and reads
  /// the list. Called on launch; later calls only re-read.
  Future<void> start() {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'changed') await refresh();
      });
    }
    return refresh();
  }

  /// Reads the list. Natively this also re-arms the alarm, which the OS can
  /// drop at any time, so it runs on every return to the app too.
  Future<void> refresh() async {
    try {
      final rows = await _channel.invokeListMethod<Object?>('list');
      pending.value = List.unmodifiable([
        for (final row in rows ?? const <Object?>[])
          CallReminder.fromMap((row! as Map).cast<Object?, Object?>()),
      ]);
    } catch (e) {
      debugPrint('call reminders: list failed: $e');
    }
  }

  /// Sets a reminder. Null when it could not be saved.
  Future<CallReminder?> add({
    required String number,
    required CallReminderKind kind,
    required DateTime at,
    String? name,
  }) async {
    try {
      final row = await _channel.invokeMapMethod<Object?, Object?>('add', {
        'number': number,
        'kind': kind.name,
        'at': at.millisecondsSinceEpoch,
        'name': name,
      });
      await refresh();
      return row == null ? null : CallReminder.fromMap(row);
    } catch (e) {
      debugPrint('call reminders: add failed: $e');
      return null;
    }
  }

  Future<void> remove(String id) async {
    try {
      await _channel.invokeMethod<void>('remove', {'id': id});
    } catch (e) {
      debugPrint('call reminders: remove failed: $e');
    }
    await refresh();
  }

  /// False when notifications are off, so a reminder would never be seen.
  Future<bool> alertsEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('alertsEnabled') ?? true;
    } catch (e) {
      debugPrint('call reminders: alertsEnabled failed: $e');
      return true;
    }
  }
}
