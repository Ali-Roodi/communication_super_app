import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/scheduled_message_model.dart';
import '../repositories/scheduled_message_repository.dart';
import 'sms_service.dart';

/// Outcome of one delivery sweep.
class DeliveryReport {
  final int sent;
  final int failed;

  const DeliveryReport({this.sent = 0, this.failed = 0});

  bool get changedAnything => sent > 0 || failed > 0;
}

/// Sends scheduled messages that are due, exactly once each.
///
/// Every sweep first *claims* the due rows with a random token
/// ([ScheduledMessageRepository.claimDue]), so a concurrent sweep — or the
/// native background worker — can never send the same message twice. A claimed
/// row is either advanced (success) or given a backoff retry (failure); if the
/// process dies mid-sweep the claim goes stale and the row is picked up again.
class ScheduledDeliveryService {
  final ScheduledMessageRepository _repository;
  final SmsService _smsService;
  final Random _random;

  ScheduledDeliveryService({
    ScheduledMessageRepository? repository,
    SmsService? smsService,
    Random? random,
  }) : _repository = repository ?? ScheduledMessageRepository(),
       _smsService = smsService ?? SmsService(),
       _random = random ?? Random();

  /// Sends every schedule due at [now]. Never throws.
  ///
  /// [force] names schedules that must go out regardless of their jitter
  /// window — «ارسال فوری» means now, not "somewhere in the next hour".
  Future<DeliveryReport> deliverDue({DateTime? now, Set<String>? force}) async {
    final at = now ?? DateTime.now();
    List<ScheduledMessage> claimed;
    try {
      // Rows whose time has come but whose jitter window hasn't elapsed are
      // left alone — claiming them would send at the exact scheduled instant
      // and defeat the spreading the user asked for.
      final due = await _repository.getDue(at);
      final ready = due
          .where((m) => m.isDueAt(at) || (force?.contains(m.id) ?? false))
          .map((m) => m.id)
          .toSet();
      if (ready.isEmpty) return const DeliveryReport();
      claimed = await _repository.claimDue(at, _newToken(), restrictTo: ready);
    } catch (e) {
      debugPrint('ScheduledDeliveryService: claim failed: $e');
      return const DeliveryReport();
    }
    if (claimed.isEmpty) return const DeliveryReport();

    var sent = 0;
    var failed = 0;
    for (final msg in claimed) {
      final ok = await _deliverOne(msg, at);
      ok ? sent++ : failed++;
    }
    return DeliveryReport(sent: sent, failed: failed);
  }

  /// Sends one claimed schedule and writes its next state back. Returns whether
  /// the SMS went out.
  ///
  /// A claimed row must always be written back — otherwise it stays `sending`
  /// until the stale-claim timeout — so every failure path ends in an upsert.
  Future<bool> _deliverOne(ScheduledMessage msg, DateTime now) async {
    try {
      final result = await _smsService.sendSms(
        msg.phoneNumber,
        msg.body,
        subscriptionId: msg.subscriptionId,
      );
      if (result.success) {
        await _repository.upsert(msg.advanceAfterSend(now: now));
        return true;
      }
      await _repository.upsert(
        msg.withFailedAttempt(
          errorCode: result.errorCode ?? 'SMS_SEND_FAILED',
          now: now,
        ),
      );
      return false;
    } catch (e) {
      debugPrint('ScheduledDeliveryService: send failed for ${msg.id}: $e');
      try {
        await _repository.upsert(
          msg.withFailedAttempt(errorCode: 'SMS_SEND_FAILED', now: now),
        );
      } catch (_) {
        // DB is gone; the stale-claim sweep will recover the row.
      }
      return false;
    }
  }

  String _newToken() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
}
