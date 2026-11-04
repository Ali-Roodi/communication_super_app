# KNOWN ISSUES

What is open, accepted or not yet verified, as of 1405/08. Fixed defects are not
listed here — their story is in the git history and the area notes under
`architecture/`, next to the invariant that keeps each one fixed.

## Open

### Found in the two-phone test of 1405/08/13 (Samsung A33 ↔ Huawei ART-L29)
- **The secure section ignores the app's default SIM.** With «ارسال با سیم‌کارت پیش‌فرض» in the
  «پیام‌های رمز» menu, `SecureMessenger._send` passes no subscription, so handshake answers leave
  on the *phone's* default SIM even when Settings → «سیم‌کارت‌ها» names another. On a phone whose
  default SIM has no credit the answer never goes and the peer sees «پاسخی از گوشی مقابل نرسیده».
  Choosing the SIM in that menu works. Stated in the user manual (section 14); not changed.
- **The keypad's refusal message is not visible.** A number barred by «فهرست سیاه و سفید» dialled
  from the keypad sheet is correctly not called, but `sim_call.dart`'s snack bar did not appear on
  screen; it probably shows on the scaffold under the sheet. Not changed.

### K1 — Not yet verified between two real phones
- **Cover text and the organization APK** passed the two-phone test of 1405/08/13 (a test build of
  commit `7c41463`, Samsung A33 ↔ Huawei ART-L29, real carrier): activation gate, Persian and English
  cover, a long message, no provider row. Not repeated: a reboot after activation, groups with cover text.
- **The mentor's own Windows activation-code generator**: one end-to-end check
  (device `b60966` → `9c4a48e93a`) is outstanding. Codes from our panel are
  verified on phones.
- **Rows built on 1405/08/11–13** (5, 10, 23, 34, 36, 39, 42) and the contact photo
  from the camera: their two-phone checks are open in `FINAL_DEVICE_TESTS.md`.
  Saving to a Google account and to Google Drive (row 34) has not been tried yet.

### K2 — Matrix rows not done
- **Row 25** (location and wipe on a special SMS): cancelled. It was written, then
  taken out of the build, and it will not come back.
- **Row 12** (encrypting the whole main database): cancelled — Kotlin opens
  that database while the app is dead with no key, everything secret is already in
  SQLCipher, and ordinary SMS also live in the OS provider.
- **Row 4** (one-tap shortcut from a physical key): cancelled. An ordinary app
  cannot be given a hardware key; see the log in `architecture/editions.md`.
- **Row 38** (speaking the caller's or sender's name before the alert): cancelled.
  The phones have no Persian voice, and the Urdu and Arabic ones were not
  understandable; see the log in `architecture/editions.md`.
- **Row 2** (signing in with a pattern) and **row 24** (a star on encrypted
  messages): dropped. The PIN and fingerprint stay, and so do the stars on contacts
  and ordinary SMS; only those two missing parts will not be built.
- **Row 37** (a profile for contacts and contact groups): dropped. The contact form
  keeps the fields it has; the missing parts, such as the allowed call hours, will
  not be built.
- **Row 41** (work modes): dropped, and nothing of it was built.
- **Rows 7, 8, 9 and 43** (backup, moving a backup to another phone, forwarding SMS
  automatically, a permanent contact history): not built in any edition, and not
  decided either. The mentor's matrix gives them a low priority.

### K3 — Long multi-part SMS can be lost by some OEMs
MIUI once dropped a long multi-part session request (`checkSmsCmd … smsBlocked`)
and parts that never arrived were never assembled. A lost request is recovered by
the 15-minute retry and the crossed-INIT rule; a lost message part is not.

### K4 — Activation codes can be minted from the APK
The derivation and both app ids are in the APK; there is no server and no
revocation. Accepted to stay compatible with the mentor's existing generator. A
factory reset changes ANDROID_ID and needs a new code (the organization APK stays
closed until then).

### K5 — Crash reporting does not see Kotlin crashes
`CrashReporting` uses the pure-Dart `sentry` package (`sentry_flutter` pins an
Android Gradle plugin this build cannot resolve), so only Dart errors are
reported.

### K6 — Non-Iranian numbers normalize weakly
`PhoneNormalizer` is tuned for Iranian numbers; foreign numbers fall back to a
cleaned digit string and two formats of one foreign number may not merge.
Acceptable for the target market.

### K7 — No localization layer
All user-facing text is inline Persian. The app ships no Persian
`MaterialLocalizations`, which is why some framework labels (the selection
toolbar) are supplied by hand.

### K8 — Dependencies behind their latest major versions
`flutter_secure_storage` 9, `flutter_local_notifications` 18 and
`flutter_contacts` 1 are behind. `flutter_contacts` 2 is a full API rewrite of
everything contact-related and needs its own branch and device QA.

### K9 — One timing-sensitive widget test
`test/widget/pin_error_text_test.dart` («a lockout counts down and disappears»)
fails in a full `flutter test` run and passes on its own (seen again 1405/08/13).
The other 907 Dart tests pass.

## Accepted by design

- **Cover text reads as words, not sentences.** Real grammar would multiply the
  SMS cost; see `architecture/editions.md` (row 31).
- **Handshakes are never covered** (138 and 154 bytes would be about a hundred words each).
- **The dormant `ConnectionService` path** (`call/CallConnectionService.kt`) is
  VoIP scaffolding; cellular calls go through `CallInCallService` as the default
  dialer.
