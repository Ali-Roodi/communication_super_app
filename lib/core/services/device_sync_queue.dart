import 'dart:async';

/// Serializes the app's heavy reads of device data (address book, SMS
/// provider, call log).
///
/// On a fresh install every tab wakes at once: contacts, the SMS mirror-sync
/// and the call-log import all start on the same frame. Each marshals a large
/// payload over a platform channel and holds it in memory while writing it to
/// SQLite, so running them concurrently multiplies the peak heap — which is how
/// a phone with a big address book and a long history ends up hanging or being
/// killed on first launch. Running them one after another costs the same total
/// time but a third of the peak.
///
/// Nested calls (the SMS sync asking for contacts while it holds the queue)
/// run inline instead of deadlocking behind themselves.
abstract class DeviceSyncQueue {
  static Future<void> _tail = Future<void>.value();
  static bool _busy = false;

  /// Runs [task] after any queued device read has finished.
  static Future<T> run<T>(Future<T> Function() task) {
    // Only the task currently holding the queue can reach this re-entrantly:
    // the queue runs one task at a time and Dart is single-threaded.
    if (_busy) return task();

    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      _busy = true;
      try {
        completer.complete(await task());
      } catch (e, s) {
        completer.completeError(e, s);
      } finally {
        _busy = false;
      }
    });
    return completer.future;
  }
}
