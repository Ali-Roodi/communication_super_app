import 'dart:isolate';

import 'package:call_log/call_log.dart' as call_log;
import 'package:permission_handler/permission_handler.dart';
import '../models/call_log_model.dart';
import '../repositories/call_log_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:uuid/uuid.dart';

class CallLogService {
  final CallLogRepository _repository = CallLogRepository();
  final ContactRepository _contactRepository = ContactRepository();
  static List<CallLogModel>? _cache;
  static bool _isLoading = false;

  Future<bool> requestPermissions() async {
    final status = await Permission.phone.request();
    return status.isGranted;
  }

  Future<List<CallLogModel>> getCallLogs({bool forceRefresh = false}) async {
    if (!forceRefresh && _cache != null && _cache!.isNotEmpty) {
      return _cache!;
    }

    // Avoid duplicate concurrent loads
    if (_isLoading) {
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (_cache != null) return _cache!;
    }

    _isLoading = true;
    try {
      // Source the raw logs: DB cache first, else read from the device.
      // `contact_name` is NOT stored in the DB, so it is resolved fresh below
      // from the current contacts on every load — this way a call shows the
      // saved name even for cached rows and updates the moment a contact is
      // added/renamed.
      List<CallLogModel> logs;
      final cachedDbLogs = await _repository.getAllCallLogs();
      if (cachedDbLogs.isNotEmpty && !forceRefresh) {
        logs = cachedDbLogs;
      } else {
        final hasPermission = await requestPermissions();
        if (!hasPermission) {
          _cache = [];
          return _cache!;
        }
        logs = await _fetchDeviceLogs();
        await _repository.saveCallLogsBatch(logs);
      }

      _cache = await resolveContactNames(logs);
      return _cache!;
    } catch (e) {
      _cache = [];
      return _cache!;
    } finally {
      _isLoading = false;
    }
  }

  /// Overlays the current contact name/id onto each log, matching on the
  /// canonical national number against **all** of a contact's phone numbers.
  ///
  /// Public so the bloc can enrich the paginated rows it reads back from the DB
  /// (where `contact_name` is not stored).
  Future<List<CallLogModel>> resolveContactNames(
    List<CallLogModel> logs,
  ) async {
    final contacts = await _contactRepository.getAllContacts();
    final contactMap = <String, Map<String, String>>{};
    for (final c in contacts) {
      for (final p in {...c.phoneNumbers, c.phoneNumber}) {
        final normalized = _normalizePhoneNumber(p);
        if (normalized.isEmpty) continue;
        contactMap.putIfAbsent(normalized, () => {'id': c.id, 'name': c.name});
      }
    }
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

  /// Reads the device call log and maps it to models (contact fields left null;
  /// they are filled by [_resolveContactNames]).
  Future<List<CallLogModel>> _fetchDeviceLogs() async {
    final Iterable<call_log.CallLogEntry> entries = await call_log.CallLog.get();

    // Serialize entries to make isolate-friendly data.
    final serialized = entries.map((e) {
      return {
        'id': e.id?.toString(),
        'number': e.number ?? '',
        'callType': e.callType?.name ?? call_log.CallType.unknown.name,
        'duration': e.duration,
        'timestamp': e.timestamp,
        'simDisplayName': e.simDisplayName,
      };
    }).toList();

    // Map on a background isolate to avoid UI jank.
    final mapped = await Isolate.run<List<Map<String, dynamic>>>(() {
      return serialized.map((data) {
        CallType callType;
        final ct = data['callType'] as String;
        if (ct == call_log.CallType.incoming.name) {
          callType = CallType.incoming;
        } else if (ct == call_log.CallType.outgoing.name) {
          callType = CallType.outgoing;
        } else if (ct == call_log.CallType.rejected.name) {
          callType = CallType.rejected;
        } else if (ct == call_log.CallType.blocked.name) {
          callType = CallType.blocked;
        } else {
          // missed, voiceMail, answeredExternally, wifi*, unknown → missed
          callType = CallType.missed;
        }

        return {
          'id': data['id'] as String? ?? '',
          'phoneNumber': data['number'] as String,
          'callType': callType.index,
          'duration': data['duration'] as int?,
          'timestamp':
              (data['timestamp'] as int?) ??
              DateTime.now().millisecondsSinceEpoch,
          'simDisplayName': data['simDisplayName'],
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
        timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
        simSlot: data['simDisplayName'] != null ? 1 : null,
      );
    }).toList();
  }

  /// Delegates to [PhoneNormalizer.toThreadId] — canonical national form.
  static String _normalizePhoneNumber(String phone) =>
      PhoneNormalizer.toThreadId(phone);
}
