import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

MessageThread _thread({
  DateTime? last,
  DateTime? draft,
  DateTime? scheduled,
}) => MessageThread(
  threadId: '09120000000',
  phoneNumber: '09120000000',
  lastMessage: 'سلام',
  lastMessageTime: last ?? DateTime(2026, 1, 1),
  draftText: draft == null ? null : 'پیش‌نویس',
  draftTime: draft,
  scheduledText: scheduled == null ? null : 'زمان‌بندی‌شده',
  scheduledTime: scheduled,
);

void main() {
  group('MessageThread.sortTime', () {
    test('a bare thread sorts on its last message', () {
      expect(_thread().sortTime, DateTime(2026, 1, 1));
    });

    test('a queued send floats the row above its own history', () {
      // The reported bug: a schedule armed for somebody at the bottom of the
      // inbox left their row exactly where it was.
      final t = _thread(
        last: DateTime(2025, 1, 1),
        scheduled: DateTime(2026, 6, 1),
      );
      expect(t.hasScheduled, isTrue);
      expect(t.sortTime, DateTime(2026, 6, 1));
    });

    test('the newer of a draft and a schedule wins', () {
      expect(
        _thread(
          last: DateTime(2025, 1, 1),
          draft: DateTime(2026, 2, 1),
          scheduled: DateTime(2026, 3, 1),
        ).sortTime,
        DateTime(2026, 3, 1),
      );
      expect(
        _thread(
          last: DateTime(2025, 1, 1),
          draft: DateTime(2026, 4, 1),
          scheduled: DateTime(2026, 3, 1),
        ).sortTime,
        DateTime(2026, 4, 1),
      );
    });

    test('a schedule already in the past does not pull the row down', () {
      expect(
        _thread(
          last: DateTime(2026, 5, 1),
          scheduled: DateTime(2025, 1, 1),
        ).sortTime,
        DateTime(2026, 5, 1),
      );
    });

    test('copyWith carries the schedule', () {
      final t = _thread(scheduled: DateTime(2026, 6, 1));
      expect(t.copyWith(unreadCount: 2).hasScheduled, isTrue);
    });
  });
}
