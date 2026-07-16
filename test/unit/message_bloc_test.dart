import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/message_event.dart';
import 'package:communication_super_app/features/messages/bloc/message_state.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/services/sms_service.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';

class _MockMessageRepository extends Mock implements MessageRepository {}

class _MockSmsService extends Mock implements SmsService {}

class _MockContactRepository extends Mock implements ContactRepository {}

MessageModel _msg(
  String id,
  String threadId, {
  String body = 'سلام',
  bool isRead = false,
}) => MessageModel(
  id: id,
  threadId: threadId,
  phoneNumber: threadId,
  body: body,
  type: MessageType.received,
  status: MessageStatus.delivered,
  timestamp: DateTime(2026, 1, 1, 12),
  isRead: isRead,
);

void main() {
  late _MockMessageRepository repo;
  late _MockSmsService sms;
  late _MockContactRepository contacts;

  setUp(() {
    repo = _MockMessageRepository();
    sms = _MockSmsService();
    contacts = _MockContactRepository();
  });

  MessageBloc build() => MessageBloc(
    repository: repo,
    smsService: sms,
    contactRepository: contacts,
  );

  group('MessageBloc._onLoadThreads (state guard)', () {
    blocTest<MessageBloc, MessageState>(
      'does NOT emit MessageLoading when already showing ThreadsLoaded '
      '(no flash-to-loading on background refresh)',
      setUp: () {
        when(
          () => sms.syncDeviceMessages(
            forceRefresh: any(named: 'forceRefresh'),
          ),
        ).thenAnswer((_) async {});
        when(() => sms.isListening).thenReturn(true);
        when(
          () => repo.getAllThreads(
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            archived: any(named: 'archived'),
          ),
        ).thenAnswer((_) async => const <MessageThread>[]);
        when(() => contacts.getAllContacts()).thenAnswer((_) async => const []);
      },
      build: build,
      // Seed with hasMore:true so the refreshed (hasMore:false) result is a
      // distinct state — otherwise BLoC de-dupes the identical empty result and
      // emits nothing, which would mask whether MessageLoading was skipped.
      seed: () => const ThreadsLoaded([], hasMore: true),
      act: (bloc) => bloc.add(const LoadThreads()),
      // The only emission is the refreshed ThreadsLoaded — never MessageLoading.
      expect: () => [isA<ThreadsLoaded>()],
    );
  });

  group('MessageBloc._onReceiveMessage (state guard)', () {
    // An unread message landing in the OPEN conversation is marked read.
    setUp(() {
      when(() => repo.markThreadAsRead(any())).thenAnswer((_) async {});
    });

    blocTest<MessageBloc, MessageState>(
      'appends an incoming message to the open conversation (same thread) '
      'and marks it read (the user is looking at it)',
      build: build,
      seed: () => MessagesLoaded([_msg('m1', 't1')], threadId: 't1'),
      act: (bloc) => bloc.add(ReceiveMessage(_msg('m2', 't1', body: 'خوبی؟'))),
      expect: () => [
        MessagesLoaded([
          _msg('m1', 't1'),
          _msg('m2', 't1', body: 'خوبی؟', isRead: true),
        ], threadId: 't1'),
      ],
      verify: (_) {
        verify(() => repo.markThreadAsRead('t1')).called(1);
      },
    );

    blocTest<MessageBloc, MessageState>(
      'ignores a duplicate (same id) incoming message',
      build: build,
      seed: () => MessagesLoaded([_msg('m1', 't1')], threadId: 't1'),
      act: (bloc) => bloc.add(ReceiveMessage(_msg('m1', 't1'))),
      expect: () => const <MessageState>[],
    );

    blocTest<MessageBloc, MessageState>(
      'does not replace the open conversation when the message is for another '
      'thread',
      build: build,
      seed: () => MessagesLoaded([_msg('m1', 't1')], threadId: 't1'),
      act: (bloc) => bloc.add(ReceiveMessage(_msg('m2', 't2'))),
      expect: () => const <MessageState>[],
    );
  });
}
