import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/features/contacts/services/pinned_contacts.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure_sms/bloc/secure_messages_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Matrix row 23: each list pins at most [AppConstants.maxPinned] rows.
void main() {
  group('PinnedContacts', () {
    final pins = PinnedContacts.instance;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      pins.resetForTest();
    });

    test('pins in order and refuses a sixth whole', () async {
      expect(await pins.pin(['1', '2', '3']), isTrue);
      expect(await pins.pin(['3', '4']), isTrue);
      expect(pins.ids.value, ['1', '2', '3', '4']);
      // Two more would make six: neither is pinned.
      expect(await pins.pin(['5', '6']), isFalse);
      expect(pins.ids.value, hasLength(4));
      expect(await pins.pin(['5']), isTrue);
      expect(pins.ids.value, hasLength(AppConstants.maxPinned));
    });

    test('unpin and a deleted contact give the place back', () async {
      await pins.pin(['1', '2', '3']);
      await pins.unpin(['2']);
      expect(pins.ids.value, ['1', '3']);
      await pins.retainOnly({'3', '9'});
      expect(pins.ids.value, ['3']);
    });

    test('survives a restart', () async {
      await pins.pin(['7', '8']);
      pins.resetForTest();
      await pins.load();
      expect(pins.ids.value, ['7', '8']);
    });
  });

  group('secure pins', () {
    late Database db;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await SecureStore.createSchemaForTest(db);
    });

    tearDown(() => db.close());

    test('are kept in secure_meta, in pin order', () async {
      final store = SecureMessageStore(database: () => db);
      expect(await store.pins(), isEmpty);
      await store.setPins(['g:grp', 'c:09121111111', 'c:p:09122222222']);
      expect(await store.pins(), ['g:grp', 'c:09121111111', 'c:p:09122222222']);
      await store.setPins(const []);
      expect(await store.pins(), isEmpty);
    });

    test('the encrypted list and the plain one count apart', () {
      final pins = [
        SecureMessagesState.groupPin('grp'),
        SecureMessagesState.conversationPin('09121111111'),
        SecureMessagesState.conversationPin('p:09122222222'),
      ];
      expect(SecureMessagesState.pinsIn(pins, plain: false), 2);
      expect(SecureMessagesState.pinsIn(pins, plain: true), 1);
    });
  });
}
