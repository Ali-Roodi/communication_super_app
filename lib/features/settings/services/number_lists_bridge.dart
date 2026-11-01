import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/features/settings/models/number_lists.dart';

/// The native half of «فهرست سیاه و سفید» (`NumberLists` in Kotlin), over the
/// call channel where the other mirrored call/SMS rules already travel.
///
/// [allows] is the **same** decision every native path makes — Dart never
/// re-implements the matching, it asks. Kotlin enforces it anyway in each send
/// and receive path; asking first only means a refused send leaves no bubble
/// and a refused call no flash of the call screen.
class NumberListsBridge {
  const NumberListsBridge();

  static const _channel = MethodChannel(
    'com.example.communication_super_app/call',
  );

  /// Writes [lists] to the native mirror as one set.
  Future<void> mirror(NumberLists lists) async {
    try {
      await _channel.invokeMethod('setNumberLists', {
        'modes': {
          for (final c in ListChannel.values) c.key: lists.modeOf(c).key,
        },
        'black': lists.black,
        'white': lists.white,
        'contactsAllowed': lists.contactsAllowed,
      });
    } catch (e) {
      debugPrint('NumberListsBridge.mirror failed: $e');
    }
  }

  /// Whether [phone] may use [channel]. True when the platform cannot be
  /// asked (tests, a missing handler): the native paths still decide.
  Future<bool> allows(String phone, ListChannel channel) async {
    try {
      return await _channel.invokeMethod<bool>('numberAllowed', {
            'phone': phone,
            'channel': channel.key,
          }) ??
          true;
    } catch (_) {
      return true;
    }
  }
}
