import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';

/// The app lock. It protected nothing: the "unlocked" flag was persisted and
/// never reset, so after the first PIN entry every launch — from the
/// background or cold — walked straight past it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_secure_storage, in memory.
  final store = <String, String>{};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    store.clear();
    AuthRepository.resetSessionForTest();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          store[key!] = args['value'] as String;
          return null;
        case 'read':
          return store[key];
        case 'delete':
          store.remove(key);
          return null;
        case 'containsKey':
          return store.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(store);
        case 'deleteAll':
          store.clear();
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('unlocked state', () {
    test('a new process starts locked', () async {
      expect(await AuthRepository().isAuthenticated(), isFalse);
    });

    test('unlocking lasts for the process and is never written to disk',
        () async {
      final repo = AuthRepository();
      await repo.setAuthenticated(true);
      expect(await repo.isAuthenticated(), isTrue);
      // Nothing that survives a restart may say "unlocked".
      expect(store.containsKey('is_authenticated'), isFalse);
    });

    test('the flag an older build persisted is ignored and wiped', () async {
      store['is_authenticated'] = 'true';
      final repo = AuthRepository();
      expect(await repo.isAuthenticated(), isFalse,
          reason: 'a restart after the old build must still ask for the PIN');
      await repo.setAuthenticated(false);
      expect(store.containsKey('is_authenticated'), isFalse);
    });

    test('a restart (new session) locks again', () async {
      await AuthRepository().setAuthenticated(true);
      AuthRepository.resetSessionForTest(); // what a new process looks like
      expect(await AuthRepository().isAuthenticated(), isFalse);
    });
  });

  group('«قفل خودکار» timeout', () {
    test('defaults to one minute', () async {
      expect(await AuthRepository.relockAfterSeconds(), 60);
    });

    test('keeps a chosen value', () async {
      for (final s in AuthRepository.relockChoices) {
        await AuthRepository.setRelockAfterSeconds(s);
        expect(await AuthRepository.relockAfterSeconds(), s);
      }
    });

    test('an unknown stored value falls back to the default', () async {
      SharedPreferences.setMockInitialValues({'set_relockAfterSeconds': 17});
      expect(await AuthRepository.relockAfterSeconds(), 60);
    });
  });
}
