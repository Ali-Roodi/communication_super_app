import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/features/messages/services/spam_prompt_store.dart';

/// «اگه یک بار روی "نه" کلیک کردی، وقتی دوباره اومدی توی این پوشه، نباید دوباره
/// این پیغام رو نشون بده».
///
/// The dismissal used to be a field on the conversation's `State`, so it lasted
/// exactly as long as the screen and the banner came back on every visit.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SpamPromptStore.resetForTest();
  });

  test('«نه» survives leaving the conversation', () async {
    await SpamPromptStore.load();
    expect(SpamPromptStore.isDismissed('09121112233'), isFalse);

    await SpamPromptStore.dismiss('09121112233');
    expect(SpamPromptStore.isDismissed('09121112233'), isTrue);

    // A fresh process: nothing in memory, everything read back from storage.
    SpamPromptStore.resetForTest();
    expect(
      SpamPromptStore.isDismissed('09121112233'),
      isFalse,
      reason: 'unknown until read — null means "not read yet", not "not dismissed"',
    );
    await SpamPromptStore.load();
    expect(SpamPromptStore.isDismissed('09121112233'), isTrue);
  });

  test('a dismissal is per conversation, not global', () async {
    await SpamPromptStore.dismiss('09121112233');
    expect(SpamPromptStore.isDismissed('09129998877'), isFalse);
  });

  test('dismissing twice writes one entry', () async {
    await SpamPromptStore.dismiss('09121112233');
    await SpamPromptStore.dismiss('09121112233');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('set_spam_prompt_dismissed'), [
      '09121112233',
    ]);
  });

  test('an empty thread id is never stored', () async {
    await SpamPromptStore.dismiss('');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('set_spam_prompt_dismissed'), isNull);
  });

  test('an alphanumeric sender id is remembered like any other', () async {
    await SpamPromptStore.dismiss('همراه اول');
    SpamPromptStore.resetForTest();
    await SpamPromptStore.load();
    expect(SpamPromptStore.isDismissed('همراه اول'), isTrue);
  });
}
