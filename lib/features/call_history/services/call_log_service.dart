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
      // 1) Try database cache first
      final cachedDbLogs = await _repository.getAllCallLogs();
      if (cachedDbLogs.isNotEmpty && !forceRefresh) {
        _cache = cachedDbLogs;
        return _cache!;
      }

      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        _cache = [];
        return _cache!;
      }

      // Preload contacts once to map numbers -> names/ids
      final contacts = await _contactRepository.getAllContacts();
      final contactMap = <String, Map<String, String>>{};
      for (var c in contacts) {
        final normalized = _normalizePhoneNumber(c.phoneNumber);
        contactMap[normalized] = {'id': c.id, 'name': c.name};
      }

      final Iterable<call_log.CallLogEntry> entries = await call_log.CallLog.get();

      // Serialize entries to make isolate-friendly data
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

      // Map on a background isolate to avoid UI jank
      final mapped = await Isolate.run<List<Map<String, dynamic>>>(() {
        return serialized.map((data) {
          final phoneNumber = data['number'] as String;
          final normalized = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');

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
            'phoneNumber': phoneNumber,
            'normalized': normalized,
            'callType': callType.index,
            'duration': data['duration'] as int?,
            'timestamp': (data['timestamp'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
            'simDisplayName': data['simDisplayName'],
          };
        }).toList()
          ..sort((a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int));
      });

      // Enrich with contact info on main isolate
      final enriched = mapped.map((data) {
        final normalized = data['normalized'] as String;
        final contact = contactMap[normalized];
        final callTypeIndex = data['callType'] as int;
        final callType = CallType.values[callTypeIndex];
        
        return CallLogModel(
          id: (data['id'] as String).isEmpty ? const Uuid().v4() : data['id'] as String,
          contactId: contact?['id'],
          contactName: contact?['name'],
          phoneNumber: data['phoneNumber'] as String,
          callType: callType,
          duration: data['duration'] as int?,
          timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
          simSlot: data['simDisplayName'] != null ? 1 : null,
        );
      }).toList();

      // Persist to DB in a single batch transaction instead of N individual
      // writes, which previously caused multi-second freezes when the device
      // call history contains thousands of entries.
      await _repository.saveCallLogsBatch(enriched);

      _cache = enriched;
      return _cache!;
    } catch (e) {
      _cache = [];
      return _cache!;
    } finally {
      _isLoading = false;
    }
  }

  /// Delegates to [PhoneNormalizer.toThreadId] — canonical national form.
  static String _normalizePhoneNumber(String phone) =>
      PhoneNormalizer.toThreadId(phone);
}

