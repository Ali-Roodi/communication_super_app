import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// An unsent conversation composer draft, keyed by thread id.
class ComposerDraft {
  final String text;
  final DateTime updatedAt;
  final String phoneNumber;
  final String? contactName;

  const ComposerDraft({
    required this.text,
    required this.updatedAt,
    required this.phoneNumber,
    this.contactName,
  });
}

/// Persists per-conversation unsent composer text so it survives leaving the
/// chat and can be surfaced in the inbox (draft row).
///
/// Backed by a process-wide in-memory cache that is updated **synchronously** on
/// [save]/[remove], so the inbox sees a change the instant you leave the chat
/// (the async [SharedPreferences] write only matters across app restarts).
class ComposerDraftStore {
  static const _prefix = 'composer_draft_';
  static final Map<String, ComposerDraft> _memory = {};
  static bool _hydrated = false;

  /// Updates only the in-memory cache, synchronously. Call this on every
  /// composer change so the inbox reflects the draft the instant the user
  /// leaves the chat (persistence to disk happens later via [save]).
  void cacheSync({
    required String threadId,
    required String text,
    required String phoneNumber,
    String? contactName,
  }) {
    if (text.trim().isEmpty) {
      _memory.remove(threadId);
      return;
    }
    _memory[threadId] = ComposerDraft(
      text: text,
      updatedAt: DateTime.now(),
      phoneNumber: phoneNumber,
      contactName: contactName,
    );
  }

  Future<void> save({
    required String threadId,
    required String text,
    required String phoneNumber,
    String? contactName,
  }) async {
    if (text.trim().isEmpty) {
      await remove(threadId);
      return;
    }
    // Synchronous cache update first — visible to the inbox immediately.
    _memory[threadId] = ComposerDraft(
      text: text,
      updatedAt: DateTime.now(),
      phoneNumber: phoneNumber,
      contactName: contactName,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_prefix$threadId',
      jsonEncode({
        'text': text,
        'ts': _memory[threadId]!.updatedAt.millisecondsSinceEpoch,
        'phone': phoneNumber,
        'name': contactName,
      }),
    );
  }

  Future<void> remove(String threadId) async {
    _memory.remove(threadId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$threadId');
  }

  Future<String?> loadText(String threadId) async {
    await _hydrate();
    return _memory[threadId]?.text;
  }

  /// All non-empty drafts, keyed by thread id.
  Future<Map<String, ComposerDraft>> loadAll() async {
    await _hydrate();
    return Map.of(_memory);
  }

  /// Loads persisted drafts into the in-memory cache once per process.
  Future<void> _hydrate() async {
    if (_hydrated) return;
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      final d = _decode(raw);
      if (d != null && d.text.trim().isNotEmpty) {
        _memory[key.substring(_prefix.length)] = d;
      }
    }
    _hydrated = true;
  }

  ComposerDraft? _decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return ComposerDraft(
        text: m['text'] as String? ?? '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch((m['ts'] as int?) ?? 0),
        phoneNumber: m['phone'] as String? ?? '',
        contactName: m['name'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
