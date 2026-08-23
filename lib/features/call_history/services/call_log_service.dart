import 'dart:isolate';

import 'dart:async';

import 'package:permission_handler/permission_handler.dart';
import '../models/call_log_model.dart';
import '../repositories/call_log_repository.dart';
import 'native_call_log_service.dart';
import 'package:communication_super_app/core/services/device_sync_queue.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:uuid/uuid.dart';

class CallLogService {
  final CallLogRepository _repository = CallLogRepository();
  final ContactRepository _contactRepository = ContactRepository();

  /// In-flight load/sync; concurrent callers await the same future instead of
  /// busy-waiting.
  static Completer<void>? _loading;

  Future<bool> requestPermissions() async {
    final status = await Permission.phone.request();
    return status.isGranted;
  }

  /// Drops the memoized phone→contact index so the next name resolution
  /// rebuilds it against the current address book.
  static void invalidateCache() {
    _indexSource = null;
    _phoneIndex = null;
  }

  /// Makes sure the local mirror is populated, **without materializing the
  /// whole table**.
  ///
  /// This replaced a `getCallLogs()` that read every stored call and resolved a
  /// contact name for each — only for [CallLogBloc] to throw the list away and
  /// re-read a 50-row page. On a phone with a long history that full read ran
  /// on the main isolate on every tab open *and* every app resume, which is the
  /// recents-tab stall. Rows themselves are read paginated by the bloc.
  /// Returns whether it actually touched the device — i.e. whether the caller
  /// has any reason to re-read the mirror. False means "the mirror was already
  /// populated and nothing was imported", which is the ordinary launch, and a
  /// caller that re-queried on it would repaint the list for nothing.
  Future<bool> ensureSynced({bool forceRefresh = false}) async {
    // Piggyback on an in-flight sync instead of starting a second one.
    final inFlight = _loading;
    if (inFlight != null) {
      await inFlight.future;
      if (!forceRefresh) return false;
    }

    final completer = Completer<void>();
    _loading = completer;
    var imported = false;
    try {
      if (forceRefresh || !await _repository.hasAnyCallLogs()) {
        await syncFromDevice(force: forceRefresh);
        imported = true;
      }
    } catch (_) {
      // Keep whatever the mirror already holds; the bloc still shows it.
    } finally {
      _loading = null;
      completer.complete();
    }
    return imported;
  }

  /// How far back the mirror reaches. Calls older than this were imported by an
  /// earlier pass and stay in the local DB untouched.
  static const Duration _syncWindow = Duration(days: 365);

  /// The first import walks the window in slices, yielding between them, so a
  /// ten-year call history can't block the UI thread in one shot.
  static const Duration _importChunk = Duration(days: 30);

  /// Overlap applied to the incremental fetch: a call that ended just before
  /// the last sync can land in the provider a moment later, so re-reading a
  /// short tail is cheaper than missing rows.
  static const Duration _deltaOverlap = Duration(minutes: 10);

  /// Mirror-syncs the local DB against the device call-log provider.
  ///
  /// Two halves, both deliberately incremental — the old version re-read *and
  /// re-wrote* every call inside [_syncWindow] on every pass, and since a pass
  /// runs on resume and on every ContentObserver fire (i.e. after each call and
  /// after each delete), that was the multi-second freeze on a long history:
  ///
  /// 1. **Content**: only rows newer than the newest stored call are fetched
  ///    and written (everything, chunked, when the mirror is still empty).
  /// 2. **Deletions**: the device's *ids* alone are read natively and diffed
  ///    against the stored ids, so nothing is re-written to spot a delete. If
  ///    the native side can't answer, the diff is skipped rather than guessed.
  Future<List<CallLogModel>?> syncFromDevice({bool force = false}) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) return null;

    final windowStart = DateTime.now().subtract(_syncWindow);
    final newestLocalMs = await _repository.newestTimestampMs();

    final List<CallLogModel> deviceLogs;
    if (newestLocalMs == null) {
      await _importWindow(windowStart);
      deviceLogs = const [];
    } else {
      final since = DateTime.fromMillisecondsSinceEpoch(
        newestLocalMs,
      ).subtract(_deltaOverlap);
      deviceLogs = await _fetchDeviceLogs(
        since: since.isBefore(windowStart) ? windowStart : since,
      );
      if (deviceLogs.isNotEmpty) {
        await _repository.saveCallLogsBatch(deviceLogs);
      }
    }

    await _reconcileDeletions(windowStart, force: force);

    invalidateCache();
    return deviceLogs;
  }

  /// First-run import: pulls [_syncWindow] a slice at a time, writing each
  /// slice and yielding so the frame loop keeps running.
  ///
  /// Nothing is accumulated — a whole call history held in a list while it is
  /// also being written is exactly the peak the low-memory phones die on.
  Future<void> _importWindow(DateTime windowStart) async {
    var chunkEnd = DateTime.now();
    while (chunkEnd.isAfter(windowStart)) {
      final chunkStart = chunkEnd.subtract(_importChunk);
      final slice = await _fetchDeviceLogs(
        since: chunkStart.isBefore(windowStart) ? windowStart : chunkStart,
        until: chunkEnd,
      );
      if (slice.isNotEmpty) {
        await _repository.saveCallLogsBatch(slice);
      }
      chunkEnd = chunkStart;
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// How often the deletion diff runs on its own. The observer fires after
  /// every call and every delete, and diffing reads an id per stored call on
  /// both sides — cheap, but not something to repeat seconds apart. A delete
  /// made in another app therefore shows up within this window; a delete made
  /// *here* is applied immediately by [deleteCallLogsGlobally].
  static const Duration _deletionReconcileInterval = Duration(minutes: 5);
  static DateTime? _lastDeletionReconcile;

  /// Drops local rows whose provider row is gone, scoped to [windowStart] (the
  /// same range the mirror covers) so older calls aren't purged as "missing".
  /// Only numeric ids can be provider rows; UUID fallbacks are left alone.
  Future<void> _reconcileDeletions(
    DateTime windowStart, {
    bool force = false,
  }) async {
    final last = _lastDeletionReconcile;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _deletionReconcileInterval) {
      return;
    }
    _lastDeletionReconcile = DateTime.now();

    final sinceMs = windowStart.millisecondsSinceEpoch;
    final deviceIds = await NativeCallLogService.instance.deviceCallLogIdsSince(
      sinceMs,
    );
    if (deviceIds == null) return; // can't tell — never guess a delete

    final localIds = await _repository.getIdsSince(sinceMs);
    final stale = localIds
        .where((id) => !deviceIds.contains(id) && _isNumeric(id))
        .toList();
    if (stale.isNotEmpty) {
      await _repository.deleteCallLogs(stale);
    }
  }

  /// Deletes call logs **globally**: from the device provider first, then the
  /// local mirror. Never delete local-only — the row would resurrect on the
  /// next device sync.
  Future<void> deleteCallLogsGlobally(List<String> ids) async {
    if (ids.isEmpty) return;
    await NativeCallLogService.instance.deleteDeviceCallLogs(ids);
    await _repository.deleteCallLogs(ids);
    invalidateCache();
  }

  /// «پاک کردن سابقه تماس» — empties the device provider, then the local
  /// mirror.
  ///
  /// Not `deleteCallLogsGlobally(everything on screen)`: the list is paged, so
  /// that cleared the rows the user could see and left the rest to reappear on
  /// the next scroll. Returns false when the provider refused (no
  /// WRITE_CALL_LOG), in which case **nothing** local is touched — the sync
  /// would bring it all back and the clear would look like it undid itself.
  Future<bool> clearAllCallLogsGlobally() async {
    final deleted = await NativeCallLogService.instance
        .deleteAllDeviceCallLogs();
    if (deleted < 0) return false;
    await _repository.deleteAllCallLogs();
    // The next sync must not treat the empty provider as "nothing new": the
    // deletion diff is what would otherwise be skipped for five minutes.
    _lastDeletionReconcile = null;
    invalidateCache();
    return true;
  }

  static bool _isNumeric(String s) =>
      s.isNotEmpty && s.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

  /// Overlays the current contact name/id onto each log, matching on the
  /// canonical national number against **all** of a contact's phone numbers.
  ///
  /// Public so the bloc can enrich the paginated rows it reads back from the DB
  /// (where `contact_name` is not stored).
  Future<List<CallLogModel>> resolveContactNames(
    List<CallLogModel> logs,
  ) async {
    final contactMap = await _contactIndex();
    if (contactMap.isEmpty) return logs;
    return [
      for (final log in logs)
        () {
          final c = contactMap[_normalizePhoneNumber(log.phoneNumber)];
          return c == null
              ? log
              : log.copyWith(contactId: c['id'], contactName: c['name']);
        }(),
    ];
  }

  /// Memoized normalized-number → {id, name} index, rebuilt only when the
  /// contact cache itself is replaced. Building it walks every number of every
  /// contact through [PhoneNormalizer]; doing that again for each 50-row page
  /// made scrolling recents O(address book) per page.
  static List<ContactModel>? _indexSource;
  static Map<String, Map<String, String>>? _phoneIndex;

  Future<Map<String, Map<String, String>>> _contactIndex() async {
    final contacts = await _contactRepository.getAllContacts();
    final cached = _phoneIndex;
    if (cached != null && identical(_indexSource, contacts)) return cached;

    final index = <String, Map<String, String>>{};
    for (final c in contacts) {
      for (final p in {...c.phoneNumbers, c.phoneNumber}) {
        final normalized = _normalizePhoneNumber(p);
        if (normalized.isEmpty) continue;
        index.putIfAbsent(normalized, () => {'id': c.id, 'name': c.name});
      }
    }
    _indexSource = contacts;
    _phoneIndex = index;
    return index;
  }

  /// Reads the device call log and maps it to models (contact fields left null;
  /// they are filled by [_resolveContactNames]).
  Future<List<CallLogModel>> _fetchDeviceLogs({
    DateTime? since,
    DateTime? until,
  }) async {
    // The SIM roster must exist BEFORE the rows are mapped: each row's
    // subscription is resolved from its PhoneAccount id and then persisted, so
    // running first would stamp "no SIM" on every call for good.
    await SimService.instance.ensureLoaded();

    // Queued: this read competes with the contacts and SMS imports on a cold
    // start, and each holds a large channel payload while it works.
    //
    // Native, not the `call_log` package: that plugin requests READ_CALL_LOG
    // itself and replies twice on one `MethodChannel.Result` when a second
    // call arrives while its permission dialog is up, which killed the app on
    // every fresh install. See `NativeCallLogService.deviceCallLogEntries`.
    final entries = await DeviceSyncQueue.run(
      () => NativeCallLogService.instance.deviceCallLogEntries(
        sinceMs: since?.millisecondsSinceEpoch,
        untilMs: until?.millisecondsSinceEpoch,
      ),
    );

    // Map on a background isolate to avoid UI jank.
    final mapped = await Isolate.run<List<Map<String, dynamic>>>(() {
      return entries.map((data) {
        // The raw `CallLog.Calls.TYPE` constant, mapped here rather than
        // natively so a value this build has never heard of still arrives.
        final callType = switch (data['callType'] as int? ?? 0) {
          1 => CallType.incoming,
          2 => CallType.outgoing,
          5 => CallType.rejected,
          6 => CallType.blocked,
          // 3 missed, 4 voicemail, 7 answered elsewhere, anything else → missed
          _ => CallType.missed,
        };

        return {
          'id': data['id'] as String? ?? '',
          'phoneNumber': data['number'] as String? ?? '',
          'callType': callType.index,
          'duration': data['duration'] as int?,
          'timestamp':
              (data['timestamp'] as int?) ??
              DateTime.now().millisecondsSinceEpoch,
          'phoneAccountId': data['phoneAccountId'],
        };
      }).toList()..sort(
        (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int),
      );
    });

    return mapped.map((data) {
      return CallLogModel(
        id: (data['id'] as String).isEmpty
            ? const Uuid().v4()
            : data['id'] as String,
        phoneNumber: data['phoneNumber'] as String,
        callType: CallType.values[data['callType'] as int],
        duration: data['duration'] as int?,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          data['timestamp'] as int,
        ),
        // The call log records the PhoneAccount id of the SIM that took the
        // call; SimService maps it back to a subscription. This replaced
        // `simDisplayName != null ? 1 : null`, which reported «سیم ۱» for
        // every call on either card — a fake, not a fallback.
        subscriptionId: SimService.subscriptionForAccountId(
          data['phoneAccountId'] as String?,
        ),
      );
    }).toList();
  }

  /// Delegates to [PhoneNormalizer.toThreadId] — canonical national form.
  static String _normalizePhoneNumber(String phone) =>
      PhoneNormalizer.toThreadId(phone);
}
