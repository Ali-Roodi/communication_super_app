# KNOWN ISSUES

What is open, accepted or not yet verified, as of 1405/08. Fixed defects are not
listed here — their story is in the git history and the area notes under
`architecture/`, next to the invariant that keeps each one fixed.

## Open

### K1 — Not yet verified between two real phones
- **Cover text** («متن پوششی», format v2): verified on the emulator with injected
  SMS (organization release 2000000177), not yet sent over a carrier.
- **The organization APK** as a whole: verified on the emulator (activation gate,
  secure section); every two-phone test so far ran on the commercial APK with the
  inter-organizational edition activated.
- **The mentor's own Windows activation-code generator**: one end-to-end check
  (device `b60966` → `9c4a48e93a`) is outstanding. Codes from our panel are
  verified on phones.

### K2 — Matrix rows not done
- **Row 25** (location and wipe on a special SMS): written, then taken out of the
  build until an SMS-triggered remote action and wipe is decided on.
- **Row 12** (encrypting the whole main database): declined for now — Kotlin opens
  that database while the app is dead with no key, everything secret is already in
  SQLCipher, and ordinary SMS also live in the OS provider.
- Rows shared by all editions and not built yet: 4 (one-tap shortcut), 38 (spoken
  caller name), 39 (call/SMS reminder), 41 (work modes); partly built: 5, 10, 23,
  34, 36, 37, 42. Details in `architecture/editions.md`.

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
has failed once under a loaded full run and passes on its own.

## Accepted by design

- **Cover text reads as words, not sentences.** Real grammar would multiply the
  SMS cost; see `architecture/editions.md` (row 31).
- **Handshakes are never covered** (≈1150 bytes would be hundreds of words).
- **The dormant `ConnectionService` path** (`call/CallConnectionService.kt`) is
  VoIP scaffolding; cellular calls go through `CallInCallService` as the default
  dialer.
