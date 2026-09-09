import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which conversations the user has already answered «نه» to when asked
/// «این شماره در مخاطبین شما نیست. هرزنامه است؟».
///
/// The dismissal used to be a field on the conversation's `State`, so it lasted
/// exactly as long as the screen: leaving the chat and coming back asked again,
/// and again, for ever. Answering a question and being asked it again is the
/// definition of nagging — Google Messages asks once per conversation and never
/// returns to it — and on an inbox full of unsaved senders it was the first
/// thing on screen every single time.
///
/// A [SharedPreferences] string list rather than a table: it is a UI dismissal,
/// not data — nothing joins on it, nothing else reads it, and losing it on a
/// reinstall costs one prompt. Kept in memory after the first read so the
/// conversation can answer inside `build` without flashing the banner in and
/// out while a future resolves.
class SpamPromptStore {
  SpamPromptStore._();

  static const String _key = 'set_spam_prompt_dismissed';

  /// The newest N dismissals are kept. A cap exists because this only ever
  /// grows — one entry per unsaved sender the user declined to report — and the
  /// oldest ones are conversations nobody is looking at any more.
  static const int _maxEntries = 500;

  static Set<String>? _memo;

  /// Answers from what has already been read, or null when nothing has been
  /// read yet — the same "unknown, not no" contract [ContactNameCache] uses.
  static Set<String>? get cached => _memo;

  /// Reads the set once per process. Never throws: a store that cannot be read
  /// simply means nothing was dismissed, which costs one prompt.
  static Future<Set<String>> load() async {
    final memo = _memo;
    if (memo != null) return memo;
    try {
      final prefs = await SharedPreferences.getInstance();
      return _memo = (prefs.getStringList(_key) ?? const <String>[]).toSet();
    } catch (e) {
      debugPrint('SpamPromptStore.load failed: $e');
      return _memo = <String>{};
    }
  }

  static bool isDismissed(String threadId) =>
      _memo?.contains(threadId) ?? false;

  /// Remembers that [threadId] was answered. Idempotent.
  static Future<void> dismiss(String threadId) async {
    if (threadId.isEmpty) return;
    final set = await load();
    if (!set.add(threadId)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Newest last, so the trim drops the oldest.
      final list = set.toList();
      final trimmed = list.length <= _maxEntries
          ? list
          : list.sublist(list.length - _maxEntries);
      if (trimmed.length != list.length) _memo = trimmed.toSet();
      await prefs.setStringList(_key, trimmed);
    } catch (e) {
      debugPrint('SpamPromptStore.dismiss failed: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() => _memo = null;
}
