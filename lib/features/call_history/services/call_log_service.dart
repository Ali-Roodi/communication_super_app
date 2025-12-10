import 'dart:isolate';

import 'package:call_log/call_log.dart' as call_log;
import 'package:permission_handler/permission_handler.dart';
import '../models/call_log_model.dart';
import '../repositories/call_log_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
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
      final contactMap = {
        for (var c in contacts) _normalizePhoneNumber(c.phoneNumber): c,
      };

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
      final mapped = await Isolate.run<List<CallLogModel>>(() {
        return serialized.map((data) {
          final phoneNumber = data['number'] as String;
          final normalized = _normalizePhoneNumber(phoneNumber);

          CallType callType;
          final ct = data['callType'] as String;
          if (ct == call_log.CallType.incoming.name) {
            callType = CallType.incoming;
          } else if (ct == call_log.CallType.outgoing.name) {
            callType = CallType.outgoing;
          } else {
            callType = CallType.missed;
          }

          final contact = contactMap[normalized];

          return CallLogModel(
            id: data['id'] as String? ?? const Uuid().v4(),
            contactId: contact?.id,
            contactName: contact?.name,
            phoneNumber: phoneNumber,
            callType: callType,
            duration: data['duration'] as int?,
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (data['timestamp'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
            ),
            simSlot: data['simDisplayName'] != null ? 1 : null,
          );
        }).toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      });

      // Persist to DB (not on isolate)
      for (final log in mapped) {
        await _repository.saveCallLog(log);
      }

      _cache = mapped;
      return _cache!;
    } catch (e) {
      _cache = [];
      return _cache!;
    } finally {
      _isLoading = false;
    }
  }

  static String _normalizePhoneNumber(String phone) {
    return phone.replaceAll(RegExp(r'[^\\d]'), '');
  }
}

