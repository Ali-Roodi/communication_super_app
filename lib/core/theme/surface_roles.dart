import 'package:flutter/material.dart';

/// Semantic surface roles, mapped the way Google Phone / Google Messages use
/// them.
///
/// Both apps stack exactly three planes:
///
/// * the **page** — the tinted plane the whole screen sits on,
/// * the **card** — the list/settings groups, always *lighter* than the page,
/// * the **raised** plane — keypad panel, menus, dialogs, bottom sheets.
///
/// In light mode the page is a tinted grey and cards are near-white; in dark
/// mode the page is the darkest plane and cards are lifted above it. The M3
/// roles that produce that relationship differ per brightness, so the mapping
/// lives here instead of being repeated (and getting inconsistent) per screen.
extension SurfaceRoles on ColorScheme {
  bool get _light => brightness == Brightness.light;

  /// Scaffold background — the tinted plane everything sits on.
  Color get pageBackground => _light ? surfaceContainer : surface;

  /// List cards, settings groups, conversation sheet.
  Color get cardSurface => _light ? surfaceBright : surfaceContainerHigh;

  /// Keypad panel, menus, dialogs, bottom sheets — a tinted plane that reads as
  /// lifted off the page in light mode and as a lightened plane in dark mode.
  Color get raisedSurface => surfaceContainerHigh;

  /// Keys inside the keypad panel. Google inverts the relationship per
  /// brightness: white keys on a tinted panel in light mode, keys *darker*
  /// than the panel in dark mode.
  Color get keySurface => _light ? surfaceBright : surface;

  /// Tonal rows inside an expanded card (the «پیام / سابقه / حذف» actions).
  Color get tonalRow => _light ? surfaceContainer : surfaceContainerHighest;

  /// Filter-chip fill when unselected (transparent with an outline in Google's
  /// apps — exposed as a colour so callers don't branch).
  Color get chipUnselected => Colors.transparent;

  /// Received message bubble.
  Color get bubbleIncoming => _light ? surfaceContainer : surfaceContainerHigh;

  /// Sent message bubble — the tonal brand container, never a saturated fill.
  Color get bubbleOutgoing => primaryContainer;

  /// Text on the sent bubble.
  Color get onBubbleOutgoing => onPrimaryContainer;
}

/// Corner radii used by the grouped-list pattern both Google apps share:
/// a run of rows where the outer corners of the run are large and the seams
/// between rows are barely rounded.
abstract class GroupRadius {
  /// Outer corners of a group (also a standalone single-row card).
  static const double outer = 20;

  /// Corners facing a neighbouring row in the same group.
  static const double inner = 6;

  /// Vertical gap between rows of a group.
  static const double gap = 3;

  /// Builds the radius for a row at [index] of a [length]-row group.
  static BorderRadius forIndex(int index, int length) {
    final top = index == 0 ? outer : inner;
    final bottom = index == length - 1 ? outer : inner;
    return BorderRadius.vertical(
      top: Radius.circular(top),
      bottom: Radius.circular(bottom),
    );
  }
}
