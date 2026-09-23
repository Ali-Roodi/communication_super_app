import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/core/theme/app_theme.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';

/// Planes that are drawn on top of each other must never be the same colour —
/// a match does not fail loudly, the upper one simply disappears.
void main() {
  for (final entry in {
    'light': AppTheme.light,
    'dark': AppTheme.dark,
  }.entries) {
    final cs = entry.value.colorScheme;

    test('${entry.key}: a received bubble stands off the conversation sheet',
        () {
      // Dark mode drew both as surfaceContainerHigh: received messages were
      // bare text with no bubble.
      expect(cs.bubbleIncoming, isNot(cs.cardSurface));
    });

    test('${entry.key}: a sent bubble stands off the conversation sheet', () {
      expect(cs.bubbleOutgoing, isNot(cs.cardSurface));
    });

    test('${entry.key}: keypad keys stand off the keypad panel', () {
      expect(cs.keySurface, isNot(cs.raisedSurface));
    });

    test('${entry.key}: tonal action rows stand off their card', () {
      expect(cs.tonalRow, isNot(cs.cardSurface));
    });

    test('${entry.key}: cards stand off the page', () {
      expect(cs.cardSurface, isNot(cs.pageBackground));
    });
  }

  test('the two themes really are two brightnesses', () {
    expect(AppTheme.light.colorScheme.brightness, Brightness.light);
    expect(AppTheme.dark.colorScheme.brightness, Brightness.dark);
  });
}
