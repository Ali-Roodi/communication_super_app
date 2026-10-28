# Editions: commercial, inter-organizational, organization

Part of the architecture notes for this repo. Index and the rules that apply everywhere: [`DEVELOPER_GUIDE.md`](../DEVELOPER_GUIDE.md).

> **This is the one document for everything organization / inter-organization** —
> editions, activation, the secure store, SMS encryption, the key bank, the hidden
> phonebook and its calls. Nothing about those editions goes into `store-release.md` (which is the
> commercial store launch only) or scattered into the other area notes; they link
> here instead. Its history is the log at the end of this file.

هم‌رسان is one codebase and three editions, delivered as **two APKs**:

| Edition | How it reaches a phone | What it is in the code |
|---|---|---|
| تجاری (commercial) | Bazaar / Myket | Gradle flavor `commercial` |
| بین‌سازمانی (inter-organizational) | the commercial APK, unlocked in-app by an activation code | a *runtime* state of the commercial build (phase B) — **not** a flavor |
| سازمانی (organization) | a direct APK, never a store | Gradle flavor `organization` |

The feature split per edition is the mentor's matrix in `docs/پیوست فنی.docx`
(priorities are the **cell colours**: magenta 1, green 2, light blue 3, yellow 4,
black = not in that edition). Decision, 1405/08/05: row 30's organization cell
(stored as `D86DCB`, a light purple) is **priority 1** — purple counts as
magenta; seen receipts stay in the organization build. Row 1
(activation code) is green for inter-organization **and** organization.

## One applicationId, one signing key

Both flavors install as **`ir.hamrasan.app`** and are signed with the **same
release key** (`signingConfigs.release` is shared). This is a requirement, not a
shortcut: a store decides «نصب است» by package name, and it must say so whichever
edition is on the phone. Per-edition ids (`.org`, `.inter`) would make the store
treat each edition as a different, uninstalled app.

Because the package and key are shared, the package manager sees one app. That is
also what lets a commercial install be converted to the organization edition by
installing the organization APK over it **with its data intact** (verified on a
device: PIN, call log, roles all survive).

## The versionCode band — what keeps the store off an organization install

The organization edition must never be "updated" into the commercial one — not
by a store, not by a sideloaded APK. Package name and key cannot provide that
(they are shared on purpose); the **versionCode** does:

| Flavor | versionCode |
|---|---|
| `commercial` | `N` = `git rev-list --count HEAD` (release scripts), `+1` from pubspec locally |
| `organization` | `2_000_000_000 + N` |

- A store only offers an update whose versionCode is **greater** than the
  installed one, so it never offers the commercial build to an organization
  phone.
- The package manager refuses a lower versionCode outright. Verified on an
  emulator: installing the commercial APK over an organization install fails
  with `INSTALL_FAILED_VERSION_DOWNGRADE: Update version code 127 is older than
  current 2000000127` and the organization install is untouched.
- Organization updates (`base + a larger N`) install over each other normally,
  data kept (verified: 2000000127 → 2000000128).
- The platform ceiling is 2_100_000_000, so the band leaves 100 million
  releases of headroom. `build.gradle.kts` **fails the configuration** if `N`
  leaves `1..100_000_000`, rather than letting the two bands meet.

**The band is applied in Gradle, to every build type of the flavor** — debug and
profile included. A debug organization APK with a plain commit-count versionCode
is exactly the install a store could "update" into the commercial app. Do not
move the addition into the release scripts.

`versionNameSuffix = "-org"` makes the edition visible in the system's App info
page; the app itself names it in Settings → «درباره برنامه» → «نوع نسخه».

**Consequence for anyone testing:** once an organization APK is on a phone, a
commercial build cannot be installed on it again without uninstalling (release
builds are not debuggable, so `adb install -d` does not help). Test the
organization flavor on an emulator or a dedicated phone, not on a daily-driver
test device holding real data.

## Build-time edition in Dart — `AppEdition`

`lib/core/edition/app_edition.dart`.

- `AppEdition.current` / `kOrganizationBuild` are **compile-time constants**
  derived from Flutter's `appFlavor` (which the Gradle plugin sets from the
  variant being built). Branching on them lets the AOT compiler drop the other
  edition's code entirely: in a build that is handed to an organization's
  security reviewer, "hidden behind an `if`" is not the same as "absent".
- `AppEdition.verifyBuildFlavor()` runs first thing in `main` and throws on a
  flavor name it does not know. `kOrganizationBuild` can only tell
  "organization" from "anything else"; this check is what makes "anything else"
  mean exactly "commercial" — a Gradle flavor added without its Dart
  counterpart must not start with a guessed feature set.
- A flavor-less run (`flutter test`) is the commercial edition.
- `pubspec.yaml` sets `default-flavor: commercial`, so a bare `flutter run` /
  `flutter build apk` is the store build; the organization APK is always asked
  for explicitly with `--flavor organization`.

### What differs between the flavors today

- **Crash reporting is compiled out of the organization edition**
  (`CrashReporting.isAvailable` is false whatever DSN was passed). That build is
  handed over on the promise that nothing on it talks to a third-party server.
- «نوع نسخه» in «درباره برنامه».
- **The organization APK opens nothing until activated** (matrix row 1, see
  «Organization activation» below); the commercial build has the
  «نسخه بین‌سازمانی» row instead.
- «متن پوششی» (row 31) is offered only in the organization build.

Everything else — the manifest included — is identical: `aapt2 dump xmltree` of
the two APKs differs **only** in `versionCode` / `versionName`. When an edition
needs a permission or component the other must not carry, put it in a
flavor-specific manifest (`android/app/src/<flavor>/AndroidManifest.xml`), so
that, for example, an organization-only permission never appears in the APK a
store reviews.

## Inter-organizational activation (phase B)

The commercial build becomes the inter-organizational edition by an offline
activation code. **The format is the mentor's existing one, kept exactly**
(design decision) so his Windows generator keeps working unchanged:

| Step | Value |
|---|---|
| device code | BLAKE3(`ANDROID_ID` bytes), first **3** bytes, lowercase hex → 6 chars |
| interleave | `d0 1 d1 1 d2 1 d3 1 d4 1 d5 1` (app id `111111`) → 12 chars |
| activation code | BLAKE3(interleaved), first **5** bytes, lowercase hex → 10 chars |

This is `Activation.java` from the earlier S2MS app (QKSMS fork); nothing in
that source ever *called* it, so the generator is the source of truth.

- **`lib/core/utils/blake3.dart`** — pure-Dart BLAKE3 (hash mode, XOF). Pinned
  in `blake3_test.dart` to 19 vectors produced by running the S2MS
  `Blake3.java` itself (official test-vector input pattern, lengths across every
  block/chunk/tree boundary, 131-byte output). The Java class matches the
  official BLAKE3 vectors (`""` → `af1349b9…`, `"abc"` → `6437b3ac…`).
- **`lib/core/edition/activation_code.dart`** — the derivation, the tolerant
  `normalize` (case, spaces, dashes, Persian/Arabic-Indic digits, ZWNJ/bidi
  marks) and a constant-time compare. **MIRROR of the Windows generator.**
  Reference triples in `activation_code_test.dart` come from the Java code.
- **`DeviceIdentityHandler.kt`** (channel `…/device_identity`) hands Dart the
  raw `ANDROID_ID`; everything else is Dart. No permission needed. Scoped to
  (signing key, user, device) since Android 8 → same for both flavors;
  regenerated by a factory reset → activation must be redone after one.
- **`ActivationRepository`** stores the **code itself** in secure storage
  (`inter_org_activation_code`) and re-verifies it against the current device on
  every read: a forged value, storage copied to another phone, or a factory
  reset all read as "not activated". An unreadable store reads as not activated.
- **`EditionBloc`** (global, `lazy: false`) — the *effective* edition.
  `AppEdition` now has three values; `AppEdition.current` (the build) is never
  `interOrganization`. `state.hasSecureFeatures` is what later phases branch
  on. A wrong code and a right-but-unsaveable code are different failures
  (`ActivationFailure`), because telling a user a correct code is wrong sends
  them back to the mentor for a code that will not change.
- **UI:** Settings → «درباره برنامه» → «نسخه بین‌سازمانی» (commercial build
  only; compiled out of the organization build) → `InterOrgActivationScreen`:
  device code (Latin, LTR, monospace, copy), the code field (Latin keyboard,
  forgiving input), «غیرفعال کردن» with confirmation. «نوع نسخه» shows the
  effective edition.

**Known limit, accepted:** the derivation is in the APK and the constant is
public, so anyone who reverse-engineers the store APK can mint codes. There is
no server and no revocation. The project chose compatibility with the existing
generator over a stronger scheme.

Verified on devices (1405/07/05): emulator device code `4dde22` and test phone
`b60966` were activated with codes computed by the **Java** reference
(`66f7450092`, `9c4a48e93a`), i.e. independently of the Dart code; a wrong
code was rejected; activation survived a cold start; deactivation returned to
commercial; the organization build shows no activation row. The test phone was
left deactivated. **Still open:** one end-to-end check with the mentor's actual
Windows app (`b60966` → expected `9c4a48e93a`).

### Organization activation (matrix row 1, 1405/08/05)

Row 1 («کد فعال‌سازی برای جلوگیری از توزیع غیرمجاز») is green for the
organization edition too. Decisions: **its code is separate** from the
inter-organizational one, and it is **issued from the same Windows panel**, in
a menu of its own.

- **Same derivation, another app id.** `ActivationTarget` (in
  `activation_code.dart`): `interOrganization` = `111111` (the mentor's, fixed),
  `organization` = **`222222`** (ours — the mentor's generator has no such
  edition, so only `tools/keybank` issues it). The device code is the same for
  both; a code for one is refused by the other (pinned both ways in
  `activation_code_test.dart` and `ActivationTest`). `ActivationTarget.ofBuild`
  is a compile-time constant from `kOrganizationBuild`.
- **Its own storage key** (`AppConstants.orgActivationKey`,
  `org_activation_code`). An organization APK installed over an activated
  commercial one inherits that storage; the inter-organizational code must not
  open it, and it does not — `ActivationRepository(target:)` reads only its
  target's key and verifies with its target's app id.
- **What "not activated" means: the app does not open.**
  `OrganizationActivationGate` sits in `main.dart` below `CallUiCoordinator`
  and above `AuthWrapperScreen`, so PIN setup, `PermissionGate` and the
  default-app roles are never reached first — an inactive install never becomes
  the SMS app or the dialer. It renders blank while loading (no spinner), then
  `OrganizationActivationScreen` (no app bar, no way past it), then the app. In
  the commercial build it is a pass-through the compiler drops.
- **`EditionBloc`** now reads the device code and the activation in both builds.
  `EditionState.activated` is the verified fact; `edition` stays `organization`
  in the organization build either way, and `hasSecureFeatures` is `activated`
  there (so the secure section stays closed even behind the gate). The event is
  `ActivateEdition`; `DeactivateInterOrganization` is ignored in the
  organization build (nothing to fall back to). The build is a constructor
  parameter (`build:`, default `AppEdition.current`) so tests can drive the
  organization path.
- **The form is shared** (`widgets/activation_code_form.dart`:
  `ActivationCodeForm`, `DeviceCodeCard`) between `InterOrgActivationScreen` and
  `OrganizationActivationScreen`.
- **Panel** (MSI 1.5.0): the rail has «فعال‌سازی بین‌سازمانی» and
  «فعال‌سازی سازمانی», one `ActivationState` each. «فایل کلید اعضا» asks which
  app the member runs («برنامهٔ عضو», kept across a batch) so the code on the
  delivery and its sheet — label and steps — are that edition's.
  `Delivery.target` is known only right after an issue; a re-opened member's
  sheet gives both paths. CLI: `activation <device> --organization`.
- **Known limit**, the same as phase B's: the app id is in the APK. And a
  factory reset (new ANDROID_ID) needs a new code — the organization APK is
  closed until then.

## The secure section (phase C)

Decisions: it opens with **its own PIN**, separate from the app PIN,
or a fingerprint (1405/07/27); a forgotten section PIN **loses its content**
(no recovery path into it, 1405/07/05); it **locks the moment the app leaves
the foreground**.

### Storage and keys

- **`secure.db`** — a separate **SQLCipher** database (`sqflite_sqlcipher`),
  opened only between an unlock and the next lock. Nothing secret may ever be
  written to the main database: Kotlin opens that one while the app is dead,
  with no key available. `sqflite_sqlcipher` has its own `databaseFactory` and
  never replaces sqflite's global one. Only `lib/features/secure/` imports it.
- **Its schema is version 1** (`SecureStore._onCreate`, one place for every
  table), with no migrations — see «There are no migrations» in [`DEVELOPER_GUIDE.md`](../DEVELOPER_GUIDE.md).
- **The key** — 32 random bytes, used as SQLCipher's raw key (`x'…'`, so
  SQLCipher does not stretch it again). Sealed twice (`secure/VaultCrypto.kt`):
  inner AES-256-GCM under PBKDF2-HMAC-SHA256(section PIN, salt, 210 000 rounds) — the
  GCM tag is also the PIN check — and outer AES-256-GCM under a non-exportable
  **Android Keystore** key (`KeystoreKeyWrapper`, StrongBox when present). The
  vault file (`noBackupFilesDir/secure_vault.txt`,
  `hamresan-vault:1:<rounds>:<salt>:<blob>`, hex) is useless off the device, so
  the 6-digit PIN cannot be brute-forced offline from a copy.
- The key crosses the channel once per unlock (SQLCipher is opened from Dart)
  and is never on disk in clear. `VaultCryptoTest` (JVM, 10 tests) pins the
  format and every failure mode; run with
  `./gradlew :app:testCommercialDebugUnitTest` from `android/`.

### Session (`SecureSessionBloc`)

Status: `unavailable` (commercial) · `notCreated` · `locked` · `unlocked` ·
`broken` (vault exists, cannot be opened — only a reset).

- **Its own PIN** (design decision, 1405/07/27: «رمز اپ و رمز بخش امن جدا
  باشد»). Six digits (`PinPolicy.secureLength`), set the first time the section
  is opened (`SecureUnlockScreen` in create mode: typed twice), and **never the
  app PIN** — `AuthRepository.isAppPin` refuses it at creation and at every
  change (a non-counting compare, reachable only inside the unlocked app; the
  other direction cannot be checked — testing a new app PIN against the vault
  would be an unthrottled oracle on the section PIN). The vault's GCM tag is
  the PIN check: a wrong PIN is `VaultFailure.wrongPin`, not `broken`.
- **Its own attempt budget**: `PinAttemptLimiter.secureSection` (keys
  `secure_pin_*`), consulted before PBKDF2 runs — 5 free, then 30 s doubling to
  30 min. Locking yourself out of one PIN never locks the other. Wrong section
  PINs count toward the intruder photos like wrong app PINs (`IntruderReporter`).
- **Nothing about the app PIN reaches it.** Setting, changing, removing or
  recovering the app PIN leaves the section alone (`AuthBloc` has no
  `SecureStore` any more); the app PIN may be removed while a section exists;
  the app's recovery code no longer deletes it. A secure edition with no app
  PIN at all still has a locked section.
- **«تغییر رمز بخش امن»** (Settings → امنیت → «بخش امن», `SecureSectionSettingsPage`):
  the current section PIN first (`SecureVerifyPinRequested` — vault `unlock`,
  key discarded, through the budget), then the new one twice, then
  `SecureChangePinRequested` → `rekey` (same data key, database untouched,
  biometric copy stays valid). Works on a locked section too.
- **«رمز بخش امن را فراموش کرده‌ام»** on the unlock screen: a warning that
  everything inside goes, then `SecureResetRequested` → create mode. The app PIN
  is untouched. The same reset is offered right on the screen of a `broken`
  section, and Settings → «بخش امن» → «حذف همیشگی بخش امن» does it on purpose.
- **FLAG_SECURE** is set *before* the section opens and released on an explicit
  lock. After a **background** lock it stays until the next resume: the recents
  thumbnail is taken on the way out, and clearing it first would capture the open
  section. Verified: a screenshot of an open section is black.
- It re-reads its status (and the biometric facts) on every `EditionBloc`
  change (deactivation closes it) and every resume.
- `SecureSessionGuard` (in the app builder) feeds `paused`/`hidden` → lock,
  `resumed` → release the window; `inactive` is ignored (shade, dialogs, calls).
- It must be listed **after** `EditionBloc` in `AppBlocProviders` — the first
  device run crashed on reading a bloc listed below it;
  `app_bloc_providers_test.dart` builds the real list to catch it.

### «باز کردن با اثر انگشت» for the section (`secure/SecureBiometric.kt`)

A second, independent copy of the data key, sealed under a Keystore key that
only a **strong (Class 3) biometric** can use, **for every single use**
(`setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`; per-use default on
9–10) and that the system **destroys when a biometric is enrolled or all are
removed** (`setInvalidatedByBiometricEnrollment`). The PIN vault is untouched.

- File: `noBackupFilesDir/secure_vault_bio.txt`,
  `hamresan-vault-bio:1:<iv hex>:<ciphertext+tag hex>` (`BioSeal`, pinned by
  `BioSealTest`).
- **On** (Settings → «بخش امن»): the section PIN (checked first), then
  `bioEnable`: the PIN opens the vault, a new key is made, a
  `BiometricPrompt` bound to its cipher (`BiometricGate.authenticateWithCipher`,
  BIOMETRIC_STRONG only, never the device credential) authorises it, the data
  key is sealed under it. Any failure after the PIN leaves it **off**, never half on.
- **Unlock**: `bioUnlock` → the prompt releases the cipher → the data key →
  SQLCipher. The fingerprint key left of ۰ on `SecureUnlockScreen` is the app
  lock's `BiometricUnlockKey` with the section's `isEnabled` / `attempt`; it
  raises the prompt once per appearance, as on the app lock. Runs inside
  `AppHandoff.run` so the prompt's pause does not lock the section it is
  opening. A biometric success clears the section's attempt budget.
- **A finger enrolled since** → `KeyPermanentlyInvalidatedException` (or a key
  the system deleted) → `BIO_INVALIDATED`: the copy is deleted, the setting reads
  off, the screen says why; only the PIN opens until it is turned on again. So
  somebody who knows the *phone's* PIN cannot add their own finger and walk in.
- **Face unlock is not offered** where it is weak (Class 2) — Samsung's, and most
  others: a weak biometric cannot release a Keystore key at all.
  `BiometricGate.strongStatus` answers `none_enrolled` there and Settings says
  in so many words that this phone's face recognition is not accepted for the
  section. A phone with a strong face sensor (e.g. Pixel 8+) gets it for free —
  the prompt takes whatever strong biometric is enrolled.
- `create`, `destroy` and a parse failure delete the copy and its key; `rekey`
  leaves it valid (same data key).
- The **app lock's** «باز کردن با اثر انگشت یا چهره» is separate and unchanged
  (any biometric, a sentinel key, opens only the app lock).

**«پیام رمز جدید» opens the section's unlock screen** (`MainNavigation._openSecureAfterAppLock`):
after the app lock is passed — `AppLock.whenDown` waits for the relock route to
go, it is never pushed over it — the secure inbox (or the hidden call history)
is pushed and `openSecureSection` follows, which raises the fingerprint prompt
when that is on.

**The app PIN is 4 digits in every edition** (`PinPolicy.appLength`, design
decision 1405/07/27 — it guards the app, the section has its own). The stored
length is recorded (`auth_pin_length`) and every app-lock screen sizes itself
from it, so a PIN of another length already on a phone keeps working until it
is changed. The section PIN is always 6 (`PinPolicy.secureLength`).

**The lock icon** (`SecureLockButton`) sits in every tab header — Recents/
Favorites (`HomeSearchHeader`), Contacts, Messages — and is absent in the
commercial edition. It never says whether the section holds anything.

**Every «باز کردن بخش امن» goes through `openSecureSection`** (in
`secure_lock_button.dart`) — the lock icon, the button a locked screen shows
(`SecureLockedView` — the key bank, the encrypted inbox) and the notification.
Pinned by `test/widget/secure_locked_view_test.dart`.

### Build dependency: vendored `androidx.sqlite`

`sqflite_sqlcipher` needs `androidx.sqlite:sqlite:2.5.2`; Google Maven answers 404
from this development network. Five files are vendored in
`android/third_party/maven/` (declared last, scoped to the group), fetched via one
mirror and verified byte-for-byte against a second (`SHA256SUMS`, `README.md`).

### Verified (1405/07/27)

Phone SM-A336E (in-display fingerprint, weak face), commercial release 170,
activated, installed over an existing section: the section opens with the PIN
it was sealed under, and the app PIN plays no part; a wrong section PIN says
«رمز بخش امن اشتباه است»; the open section screenshots black; leaving the app
locks it. «تغییر رمز بخش امن»: a wrong current PIN refused before anything
else, a mismatched confirmation refused, then `rekey` (475 ms) — the old PIN
refused, the new one opens; the app PIN offered as the new section PIN is
refused («…باید با رمز برنامه فرق داشته باشد»). Fingerprint: turned on behind
the section PIN with a strong-biometric prompt; the unlock screen raises the
prompt by itself and a finger opens the section; Back on the prompt leaves it
locked with the PIN still working. «پیام رمز جدید» intent, warm: straight to
the section's prompt; **cold**: the app lock's prompt (weak, authenticators
255) first, then the section's (strong, 15) — never the other way round. The
system log shows each success as `isStrong: true` against the app's own
prompt. Not run on the phone (destructive, or needs a new enrollment): the
reset after a forgotten PIN, and a finger enrolled after turning it on —
both covered by `secure_section_test.dart` / `secure_locked_view_test.dart`.

**«حذف رمز عبور» did not redraw Settings** (pre-existing, reported): Settings
re-read the storage right after `add(DisableAuth())`, before the bloc had
cleared the PIN; and the bloc's final `AuthAuthenticated` equalled the current
state, so there was nothing to wait for. `DisableAuth` now emits `AuthLoading`
first and Settings awaits the next `AuthAuthenticated`.

**Size:** the APK grew 22.7 → 27.8 MB (SQLCipher native library, arm64 only).

## SMS encryption — the crypto layer

Mentor's requirement: **asymmetric and post-quantum**; standardized algorithms
accepted; owner: "whatever is more secure and cheaper", and (1405/07/25) **a
first contact must cost a few SMS parts, even at some security cost**, with
post-quantum protection added in the background.

Code: `android/.../smscrypto/` (pure JVM except `SmsCryptoHandler`,
`KeyFilePicker`, `SecureSmsInbox`), Dart bridge
`lib/features/secure/services/sms_crypto_service.dart`.

### Who holds which key

- **A member's identity** (`Identity.kt`, `IdentityKeyPair`) = ML-KEM-768
  (FIPS 203) + X25519, stored as seeds (97 bytes: format ‖ ML-KEM `d‖z` ‖
  X25519 scalar). The authority derives it: `fromSeed(HKDF(memberSeed,
  phone ‖ generation))` for the member's **first** number, so re-issuing the
  same roster gives every member the same key and raising `generation`
  rotates one member. ML-KEM keys pass FIPS 203's modulus check on parse
  (`BAD_KEY` otherwise).
- **The member certificate «گواهی عضو»** (`keybank/MemberCert.kt`, 103
  bytes): `format ‖ phone (packed BCD of the 10 digits after the 0) ‖
  generation ‖ X25519 ‖ Ed25519(64)`. Signed with the authority's **Ed25519
  key only** (an ML-DSA signature is 3309 bytes — thirty parts per first
  contact); the authority id is signed but not sent (the verifier tries each
  anchor). Only `09…` mobiles get one: it is issued for the member's first
  mobile, at their generation (0..255 — the roster refuses more).
- **Key id** = SHA-256(`hamresan.sms.cert-key-id.v1` ‖ X25519)[0..8]
  (`MemberCert.keyIdOf`). It is the one name of a member everywhere — the
  packets, groups, the stored own key — **mirrored in Dart by
  `certKeyIdFor`**, both pinned to `6d0190893fd7bb4f` (32 × `0x07`).
- **No directory** (1405/07/29, the mentor's 10-17 comment applied in full and
  the request «نمی‌خواهم اسم مخاطبان رمز در برنامه یا در کلید باشد»): a phone
  holds no list of members, names or numbers. The certificate travels in the
  handshake, so anybody is reached by number, and **no phone needs a new file
  when someone joins, is edited, gets a new key or is removed** — only that
  member's own file changes. `update.hku`, `Directory.kt` and `UpdateFile.kt`
  are gone.

### The handshake (`CertHandshake.kt`) — 2 + 2 SMS parts

```
A → B  INIT      sid ‖ cert(A) ‖ eA              138 bytes, 2 parts
B → A  RESPONSE  sid ‖ cert(B) ‖ eB ‖ confirm    154 bytes, 2 parts
```

Keys = HKDF(`X25519(eA,eB) ‖ X25519(eA,X_B) ‖ X25519(X_A,eB)`, salt =
transcript hash) → two chains, a confirm key and a **root** (the Noise-XX
shape, certificates in the clear — the numbers in them are the SMS addresses
anyway). The request names no recipient: whoever holds a certificate for the
number it went to answers. Each side checks the other's certificate against
the trusted anchors **before** anything is stored or answered; the responder
may send at once, the initiator waits for the RESPONSE (`confirm` proves the
responder). Mutual authentication from the static terms, forward secrecy from
the ephemeral one. Crossed INITs: `ownInitWins` (the smaller certificate key
id goes ahead), identically on both phones. **Not post-quantum** until the
upgrade.

### The upgrade (`Upgrade.kt`) — post-quantum in the background

Payload kinds `0x13` PQ_OFFER / `0x14` PQ_ACCEPT / `0x15` PQ_DONE, all
control packets (no notification). The initiator, after whatever it had
queued, offers its long-term ML-KEM key on the session (11 parts); the
accepter encapsulates and answers on it (10 parts) and both derive a **new
session** (new sid) from HKDF(root ‖ ss) — secret if either the classical
handshake or ML-KEM holds. The old session stays for messages in flight.
**The accepter keeps the new session on standby** (`pq-standby`, not sent
on) until the offerer is heard on it — PQ_DONE, one part — because a lost
answer would otherwise leave it writing on a session the offerer never got.
No answer within `upgradeRetry` (30 min) → the next flush offers again; the
accepter then drops its stale standby session.

### Per message (`Session.kt`, `Payload.kt`)

- One symmetric hash ratchet per direction — `mk = HMAC(ck,1)`, `ck' =
  HMAC(ck,2)`, `mk` → HKDF → AES-256 key + GCM nonce (no nonce on the wire:
  every key seals exactly one message). Out of order up to 1000 ahead, ≤1000
  skipped keys kept (oldest evicted), a repeated counter = `DUPLICATE` (SMS
  is delivered twice sometimes), tamper = `AUTH_FAILED` and the state does not
  move (`Session` is immutable). The stored state carries the root for the
  upgrade (`Session` format 2).
- Payload: kind byte + text. Kind 2 = «هم‌رسان code page 1»
  (`PersianCodePage`): ASCII + 97 Persian characters in one byte each, `0xFF`
  escapes any other character as UTF-8. Kind 1 = UTF-8, used when shorter.
  The table is **frozen** (`PayloadTest` pins its hash) — a change means a new
  kind. Flags and control kinds: see «Encrypted SMS» and «Encrypted groups»
  below.

### Wire format and cost

`#E:` + Base64 without padding, all GSM-7 basic characters → 160 per SMS, 153
per part (no brackets: those are GSM extension characters and cost double).
Packet byte 0 = `(Wire.VERSION << 4) | type`: **1** message, **2** INIT,
**3** RESPONSE, **4** CONTROL (a receipt or upgrade step). sid 2 bytes;
message counter unsigned LEB128.

| Packet | Size | SMS parts |
|---|---|---|
| INIT / RESPONSE | 138 / 154 B | 2 / 2 |
| PQ_OFFER / PQ_ACCEPT / PQ_DONE | | 11 / 10 / 1 |
| message | 21 B + text | **1 for up to 96 Persian characters** |

Plain Persian SMS is UCS-2 (70 per SMS), so an encrypted Persian message costs
about the same as a plain one. The `#E:` prefix is mirrored in
`SmsCryptoService.wirePrefix`.

### Channel (`…/sms_crypto`) — stateless

`inspect` (routing without keys: type, sid, counter, and for a handshake
packet what its not-yet-verified certificate says), `ownInitWins`,
`certInitiate` / `certRespond` / `certComplete`, `certInfo`, `upgradeOffer` /
`upgradeAccept` / `upgradeComplete`, `encryptText` / `encryptControl` /
`encryptGroupInfo`, `decrypt`, `coverEncode`, `canonicalPhone`,
`openKeyFile`, and for the hidden phonebook's sealing key
`generateIdentity` / `publicIdentity` / `openSealed`. Every secret, pending
handshake and session goes in as bytes and the next state comes back; **the
caller stores it in `secure.db` before sending the wire** (never in the main
DB). Errors are the `SmsCryptoException.Code` names. The full list with
arguments is at the top of `SmsCryptoHandler.kt`.

### Dependency and tests

`org.bouncycastle:bcprov-jdk18on:1.86` (Maven Central, SHA-1 checked against
Central). JVM tests (122 in all, `src/test/.../smscrypto/` and the rest):
NIST ACVP ML-KEM-768 vectors (keygen ×25, encaps ×8, decaps ×10 incl.
implicit rejection, key check ×10 — `src/test/resources/mlkem768_acvp.txt`),
RFC 7748 X25519, RFC 5869 HKDF (`KnownAnswerTest`), `CertHandshakeTest` (15:
members issued apart talk at once, the responder first, a request or answer
from outside the organization, someone else's certificate, our own key,
tampering, the pending state, the key file's certificate, the upgrade and a
substituted key or ciphertext, crossed requests settled the same way on both
phones),
`SessionTest`, `WireTest`, `PayloadTest`, and **`GoldenVectorTest`**, which
pins the whole protocol byte for byte — certificate → INIT → RESPONSE →
message → PQ_OFFER → PQ_ACCEPT → message (`#E:EYVVACsm…` and
`#E:ERSrAOU9…`). A failure there means a format change, which needs a new
`Wire.VERSION`, never a new expected value.

## The key bank «بانک کلید»

Decisions (1405/07/05): the **authority tool generates** members' keys
(escrow accepted; the tool keeps no private keys — it re-derives them); the tool
is a **Java tool built from this code**; the app hardcodes **only the
authority's public key**. Key files are the **only** way a phone gets a key.

| What | Code | |
|---|---|---|
| Trust anchors | `lib/features/keybank/services/trust_anchors.dart` | The authority's **public** key (ML-DSA-65 + Ed25519, 1985 B hex): the real authority `7fda025a5a997b93` (`_production`, made afresh 1405/07/29 — the previous `b45a8048bd2d0314` is no longer trusted), plus the development one behind `HAMRESAN_DEV_ANCHOR`. |
| Key file `.hkb` | `smscrypto/keybank/KeyFile.kt` | This member's identity + their certificate, nothing else (261 B); Argon2id + AES-GCM under a 20-character password. |

### Formats (pinned by tests)

- **The authority signs certificates only** (Ed25519). Its ML-DSA half signs
  nothing today; it stays in the public key and the authority id so a future
  post-quantum signature needs no new anchor. `AuthorityFile` (`.hka`) is
  format 2: `[2] ‖ bytes16(AuthorityKey)` = three 32-byte seeds (ML-DSA,
  Ed25519, member seed).
- **Key file** (format 1): `[1] ‖ bytes16 identity(97) ‖ bytes16 cert(103)`
  = 205 B sealed → 261 B. `KeyFile.create` requires `cert.x25519 ==
  identity`; `open` tries each trust anchor on the certificate (`UNTRUSTED`
  if none) and refuses a secret the certificate does not name (`BAD_BUNDLE`).
  `SmsCryptoHandler.openKeyFile` returns `{authorityId, secret, keyId,
  cert{cert, keyId, phone, generation}}`.
- **Sealed file** (`SealedFile`): `magic ‖ format ‖ Argon2 t,m,p ‖ salt16 ‖
  nonce12` (AAD) + AES-GCM. Cost `PasswordKdf.KEY_FILE` = 64 MiB, 3 passes,
  capped (≤256 MiB, ≤10 passes) before deriving. Magic `HMRKB` = key file,
  `HMRKA` = authority file.
- **Canon** (`Canon.kt`, frozen — `KeyBankTest` pins it): phone → `09…` (all
  spellings, Persian digits), the spelling keys are derived from; key-file
  password → A–Z0–9 uppercased.
- Golden values in `KeyBankTest`: authority id `e09334807b8501e0`, member key
  id `72cadfdd2e2336fe`, key file SHA-256 `96532c6f…ef03`. A change re-keys
  every member.

### Storage and app

- `secure.db` table `kb_own_keys(authority_id PRIMARY KEY, key_id UNIQUE,
  phone, generation, secret, cert, imported_at)`: **one own key per
  authority**. `KeyBankRepository.importKeyFile` → `KeyImportOutcome`:
  `added`, `replaced` (a newer generation of the same phone), `alreadyImported`,
  `older` (refused). Only `KeyBankRepository` touches it.
- `KeyBankBloc` (lazy, after `SecureSessionBloc`) loads when the section opens
  and **empties itself when it locks**. State holds public data only.
  Notices: imported, replaced, alreadyImported, older, wrongPassword,
  notAKeyFile, untrusted, badBundle («محتوای فایل کلید معتبر نیست»), failed.
- Settings → امنیت → «بانک کلید» (secure editions): «کلید شما» (the
  certificate's number, «نسل کلید n · واردشده …», «حذف» with a confirmation),
  «وارد کردن فایل کلید». The password field is obscured with an eye toggle.
  On a locked section the screen asks to open it.
- File picking: `KeyFilePicker.kt` (`ACTION_OPEN_DOCUMENT`, no permission,
  8 MB cap, request code 9301).
- **`AppHandoff`** (`lib/core/services/app_handoff.dart`): the system picker is
  another app's activity, so opening it *paused* the app and **closed the secure
  section under the user** (found on the phone). A pause that begins inside
  `AppHandoff.run` is excused by both `SecureSessionGuard` and
  `AppLockWrapper` if the app is back within 2 minutes; longer → locks on
  return. Only the key-file picker uses it so far (the contact-photo picker
  still relocks with «فوراً» — pre-existing).

### Development authority and the release guard

`tools/keybank/dev/` (gitignored) holds a development authority (id
`0ff8c538a8c5ca4b`, password in `dev/authority-password.txt`) and test key
files. The app trusts it **only** with `--dart-define=HAMRESAN_DEV_ANCHOR=true`
(the key bank screen then shows a red «نسخه آزمایشی» banner).
`scripts/release_build.{sh,ps1}` **refuse any APK whose `libapp.so` contains
the development key** (read from `trust_anchors.dart`) — verified: 0 hits in
a normal build, 1 with the define.

### The Windows tool `tools/keybank/`

JVM build compiling `smscrypto/` from the app source (minus the three Android
files: `SmsCryptoHandler`, `KeyFilePicker`, `SecureSmsInbox`): `android\gradlew -p tools\keybank jar` → `hamresan-keybank.jar`
(Java 11+), `hamresan-keybank.cmd` launcher (chcp 65001).
Commands `init`, `public`, `issue <hka> <roster.csv> <out>` (one
`<number>.hkb` per member + `passwords.csv`), `inspect`, `activation`.
Roster: `organization,<name>` line then `name,phones,generation` — **every
member needs a mobile (`09…`)**, which their certificate names (the org name is
in the file because Java on Windows reads argv in the ANSI code page — a
Persian argument arrived as «???»). `passwords.csv` (UTF-8 BOM) is reused on
re-issue. Persian README for the mentor in the folder. `activation <device
code>` prints an activation code (no authority needed).

Shared between the command line and the panel (in `tools/keybank/src/main/kotlin/`):
`Issuance` (writes the files + `passwords.csv`; the CLI's `issue` is now this),
`AuthorityFolder` (the `authority.hka` / `roster.csv` / `issued/` layout,
`addMember`: validates the new roster *before* writing, backs the old one up
to `backups/`, restores it if issuing throws) and `Activation` — **a third
mirror of `ActivationCode`** (BLAKE3 from Bouncy Castle's `Blake3Digest`),
pinned by `ActivationTest` to the same reference triples plus four
phone-verified pairs. JVM tests: `ActivationTest`, `AuthorityFolderTest`
(`gradlew -p tools\keybank :test`, 23).

### The issuance panel `tools/keybank/panel/` («پنل صدور هم‌رسان»)

Every change — «عضو جدید», «ویرایش», «گوشی گم شد», «حذف از سازمان» — writes
or deletes **that member's file only** (`issueOne` / `removeOne`, atomic
`write()`); `addMember` / `editMember` / `newKey` return the `IssuedFile`.
No «فایل قدیمی» status, no update file. The «حذف از سازمان» text says the
removed member's certificate is not revoked. `prepareNewKey` refuses a
generation past 255. The self-test (`--self-test`) runs a certificate
handshake between two issued files on the installed build. MSI **1.4.0**.
The «عضو جدید» form and its confirmation live on `KeysState` (`newMember`,
`confirmAdd`) so `PreviewRender` can draw them filled in, refused and
confirming — the guide's pictures come from it.

Decisions (1405/07/13): one Windows app for both jobs, the key part
**locked** until `authority.hka` is opened with its password (so support staff
can be given the same installer for activation codes only); the activation
format stays as it is. Phase 1 = activation tab + «عضو جدید» with a printable
«برگهٔ تحویل». Phase 2 (built 1405/07/15), in the agreed order:

1. **Who holds an old file + «دفتر صدور».** `IssuanceLog` (`issuance-log.csv`
   beside `authority.hka`, BOM CSV, append-only, a damaged line is skipped)
   records every issue (add / edit / new-key / remove) and every delivery the
   operator records. A member's status comes from it: `NOT_RECORDED` (no
   delivery — a new member), `NEW_KEY` (their last delivered generation is not the current
   one), `CURRENT`. The
   panel cannot see a phone: delivery is what the operator records («تحویل داده
   شد», or «همه … گرفتند…»).
2. **«گوشی گم شد»** = `AuthorityFolder.newKey`: generation + 1 **and a new
   password** (the paper may have gone with the phone). A number that ever had a
   key starts above every generation the log has seen for it (`nextGeneration`),
   so a retired key — possibly on a lost phone — is never issued again, also not
   when a removed member is re-added.
3. **Edit / remove** (`editMember`, `removeMember`): the member's line is
   replaced in place (`replaceMemberLine` keeps comments, header, BOM, line
   endings of a hand-written roster). Changing the FIRST number changes the key;
   the password follows the member. The last member cannot be removed.
4. ~~`update.hku`~~ — removed 1405/07/29 with the directory.

Every change is `prepare*` (validates, writes nothing; the panel runs it before
its confirmation) → backup → write roster → `Issuance.issue` → restore on
failure → one log line. **`Issuance.issue` is all or nothing**: everything is
written to `issued/.issuing/` and moved into place only when every file exists.
It used to write in place, and a failure half-way after «گوشی گم شد» left a file
re-sealed under a password that `passwords.csv` (written last) did not have.

**A change must never run in a dialog's coroutine scope.** Found driving the
installed MSI: the confirmation of «گوشی گم شد» closed itself as it launched the
job, its `rememberCoroutineScope` was cancelled, and the panel reported
«انجام نشد و چیزی تغییر نکرد» over a new key it HAD issued (the blocking work
inside `withContext` finished anyway) — without ever showing the new password.
Every change now runs on `KeysState.launch` (a `SupervisorJob` on the AWT event
thread, a 3-line dispatcher: kotlinx-coroutines-swing is not on the classpath),
and a list that cannot be re-read after a successful issue no longer turns it
into an error. Pinned by `PreviewRender.aConfirmedChangeRunsToTheEnd`, which
presses the dialog's real button in an `ImageComposeScene` (verified to fail on
the old code) — every other panel test calls the state directly, which is why
none of them saw it.

- Compose Desktop 1.12.1 (Kotlin 2.4.0 compose plugin), compiled like the CLI
  from the app's `smscrypto/` source plus the shared files (excluding the
  CLI's `Main.kt`); Vazirmatn from `assets/fonts`; window icon and `icon.ico`
  from the launcher mipmap. Packaged with jpackage (JDK 21 toolchain, the
  Gradle-provisioned JBR) as a per-user MSI carrying its own runtime;
  `upgradeUuid` is fixed for ever.
- **Google Maven answers 404 on the development network**; androidx artifacts
  Compose needs come through JetBrains' cache redirector, scoped to the
  `androidx` groups in `settings.gradle.kts`.
- Release build = ProGuard, shrink only (`rules.pro`; keeps Bouncy Castle and
  all our classes): 106 MB → 58 MB, the material-icons jar being most of it.
  **Bouncy Castle must be an unsigned copy** (`unsignedBouncyCastle` task):
  ProGuard rewrites the classes but keeps the jar's signature files, and the
  JVM then refuses the first class with «SHA-256 digest error» — found by the
  self-test, invisible in the unshrunk build.
- `HamresanPanel.exe --self-test <dir>` checks the INSTALLED build headless:
  activation code, issue two members with a throw-away authority and reopen
  the file as the app does, a certificate handshake between them, render the
  screens to PNG; verdict in `<dir>/self-test.txt`. `PreviewRender`
  (`:panel:test`, 13) renders every screen to `panel/build/previews/` for
  layout review.
- The authority password is never stored (only the file's path, in
  `java.util.prefs`); ten idle minutes, «قفل» or closing the window drop the
  authority from memory. Mixed Persian/Latin lines are separate `Text`s — one
  string was reordered by bidi into nonsense — and an error naming a Latin
  input puts it at the END of the sentence (Compose ignores FSI/PDI isolates).
- Rules found by driving the installed MSI on Windows (1405/07/13):
  `AuthorityFolder.prepare` validates without writing and runs BEFORE the
  confirmation dialog (it used to come after, so the operator agreed to a
  re-issue that was then refused); the first number must be a mobile (`09…`,
  11 digits) or foreign (`00…`) — encrypted SMS goes to it; «شماره‌های دیگر»
  splits on ؛ ; ، , and new lines, and on spaces ONLY when the piece is not
  one number as a whole (`021 8877 6655` was split into three); any edit
  clears the form error; the form scrolls back to the top after an issue;
  window minimum 800×560. Pinned by `AuthorityFolderTest.prepareWritesNothing`
  and `PreviewRender` (`checkRunsBeforeAnythingIsWritten`,
  `otherNumbersAreSplitTheWayPeopleWriteThem`, `idleLockDropsTheAuthority`).
- Persian user guide: `docs/mentor/Hamresan_Issuance_Panel_Guide_FA.{html,pdf}`
  (screenshots in the gitignored `docs/mentor/panel-img/`).

### Tests

JVM: `KeyBankTest` (15: canon, signatures, key files — wrong password,
wrong authority, a forged or foreign certificate, a secret the certificate
does not name —, the certificate (size, key id, mobiles only, generation range),
roster parser, passwords, authority file, the golden key file), `KeyBankKnownAnswerTest` (NIST ACVP ML-DSA-65 keygen ×25
and sigVer ×7 with context, RFC 8032 Ed25519, RFC 9106 Argon2id),
Dart: repository (outcomes, rotation, the certificate stored,
the key-id mirror, the schema refusing an own key without a certificate), bloc,
service mapping (a key file without a certificate is refused), screen,
`AppHandoff`, provider order.

## Encrypted SMS «پیام‌های رمز»

Decisions: a **separate section**, visible only while the secure
section is open; the notification says only «پیام رمز جدید» (no sender, no
text); «دیده شد» is **automatic and batched** and can be turned off; «حذف پس
از دیدن» is chosen by the **sender, per message**. Groups: see «Encrypted
groups» below.

### The rule: an encrypted SMS never enters `content://sms` or `messages`

- **Receiving.** `SmsDeliverReceiver` skips the provider write for a body
  starting with `#E:`. Both app-side paths (`IncomingSmsReceiver` cold,
  `SmsHandler` live) hand such a body to `SecureSmsInbox.enqueue`, which
  parks the **ciphertext** in main-DB `secure_queue` (UNIQUE(address,
  body) — a double delivery is one row). Ciphertext is not a secret; the keys
  are, and Kotlin never sees them. `SecureSmsInbox.arrival(body)` decides the
  card: a non-control message **or an INIT** is «پیام رمز جدید» (counted), a
  RESPONSE alone is «پیام رمز شما آماده ارسال است · برای ارسال، بخش امن را
  باز کنید» — **except** when `SmsHandler` has just nudged a listening Dart,
  the activity is started and the section is open
  (`SecureVaultHandler.sectionOpen`, which mirrors FLAG_SECURE): the app sends
  the queued message itself a second later, and the card used to pop up with
  sound over that very conversation (1405/07/25). A control packet (receipt,
  upgrade step) posts nothing. An INIT must announce itself: the receiver
  would otherwise never open the section, and the sender's first message would
  wait for an answer that needs the private key (1405/07/14). The notification
  is bare id `0x5EC0` on channel `secure_sms`, and opens launch action `{type:
  secure}` → `SecureInboxScreen`, and the section's own unlock screen right
  after the app lock (see «باز کردن با اثر انگشت» above). An ordinary launch
  leaves the section locked.
- **The mirror-sync skips `#E:` rows** (`SmsCryptoService.looksEncrypted`) in
  case another app wrote one into the provider.
- **Sending.** `sendSms(private: true)` → `SmsHandler.sendSms(writeToProvider =
  false)`; the delivery reports still come back (device id `-1`).
- `SecureSmsInbox.kt` creates `secure_queue` with `CREATE TABLE IF NOT EXISTS`
  mirroring `DatabaseHelper._createSecureQueueTable` — **change them together**
  (the receiver can run before the app ever upgraded the DB).
- `NativeSmsService`'s status and secure streams are **static**: the bloc and
  the sender each held their own instance, and a delivery report went to
  whichever listened first.

### Engine (`lib/features/secure_sms/`)

`SecureMessenger` drains `secure_queue` into `secure.db` `sm_inbox` (then
deletes the main-DB rows) and processes it. Every operation is serialized
(`_serial`): a drain racing a send would advance one ratchet twice from the
same state and reuse a message key. **A session's new state is stored before
its SMS is sent.**

- **Whom we can reach** (`SecureIdentities`): every own key comes with its
  certificate (`OwnIdentity{identity, number, cert}`, one per authority).
  `forNumber(phone, {name})` answers a `SecurePeer` for **any mobile** (`09…`,
  11 digits) that is not our own number, as long as we hold a key — there is
  no list to consult. «گفتگوی رمز» (`SecureNewConversationScreen`) offers
  «انتخاب از مخاطبین» (`ContactSelectorScreen(pickOnly)`, the contact's name
  is kept) and a «شمارهٔ همراه» field («شروع با این شماره»); no confirmation
  dialog. A request is only ever sent when the user sends in an encrypted
  conversation they opened (that screen, or a hidden contact's «پیام رمز»):
  a plain SMS never turns into one. An incoming conversation is named by its
  number unless the number is in the hidden phonebook.
- **The handshake is automatic**: the first message to someone sends the INIT
  and waits under the banner «در حال برقراری کانال امن…»; the queued messages go when the
  RESPONSE arrives, and the upgrade offer follows them. An unanswered INIT is
  re-sent on the next send after `pendingTimeout` (**15 min**: one lost part
  loses the whole INIT); crossed INITs are resolved by `ownInitWins` — and the
  winner whose own INIT is older than `crossedGrace` (3 min) sends a fresh one
  instead of waiting: the peer asked because ours never arrived, and both
  phones used to wait on each other (deadlock, seen 1405/07/14). Every way an
  INIT is dropped is logged (`debugPrint`, no key material); a message that
  overtakes its RESPONSE waits in `sm_inbox` (dropped after 7 days / 50 tries).
- **A request is answered once** (`sm_answered_requests`, 1405/07/26): the
  SHA-256 of every INIT we answered is kept (newest 10 000), and one seen
  before is dropped. The app never sends the same INIT twice — a lost one is
  asked again with a new one — so a repeat is the radio delivering it again or
  someone replaying a captured one, from any number. Answered, it made a new
  session that only we held, it became the newest, and every message after it
  went out on it, unreadable to the peer. Pinned by «a request delivered again
  is never answered again» (fails without the check).
- **A channel that does not come is never silent** (1405/07/29, owner: «حالت
  های شکست را پیش بینی کن… کاربر بتونه بفهمه»). The INIT and the upgrade
  offer are sent with a tracking id `cs:<phone>:<sid>` (`_controlId`); a
  failed send status — or a throw in `_sendQuietly` — sets
  `sm_sessions.send_failed` (`markSendFailed`). `SecureChannelInfo`
  (`channelInfo(phone)`) feeds the conversation screen, which re-reads it
  every 15 s: `requestFailed` → «پیامک درخواست کانال امن ارسال نشد…» (error
  banner), pending longer than `_noAnswerAfter` (**2 min**) → «پاسخی از گوشی
  مقابل نرسیده…», both with «دوباره تلاش» → `SecureRetryChannel` →
  `retryChannel(phone)` (drops pending sessions, fresh INIT; a no-op once a
  session exists). Verified on the phones: SIM-less retry, no-answer after
  2 min with a keyless peer, then «دوباره تلاش» once the peer imported.
- **The upgrade is unseen.** The header says only «رمزشده» (or «پیامک
  رمزنشده» on a plain thread) — no «در حال ارتقا», no «پساکوانتومی» (owner,
  1405/07/29). `_maybeUpgrade` (also at the end of `_onMessage`) re-offers on
  `send_failed`, or once the peer was heard after our offer and
  `upgradeRetryWhenHeard` (**2 min**) passed (`lastReceivedAt`), else after
  `upgradeRetry` (30 min). `retryUpgrade` is gone.
- **Standby sessions survive a late offer** (bug found on the phones
  1405/07/29): offers arrive out of order, and `_acceptUpgrade` used to delete
  every `pq-standby` session — a 20-minute-late older offer deleted the one
  the offerer went on to use, and nothing it sent was readable afterwards.
  Now `keepNewestStandby(keep: maxStandby - 1)` (`maxStandby` = 2), and the
  first message heard on a standby promotes it to `pq` and deletes the rest.
  Pinned by «a late old offer does not undo the upgrade» (failed before).
- **Who sent it** is the certificate, not the number: an INIT is filed under
  the conversation of the key it carries (`phoneForPeerKey`) or else the
  number its certificate names, a RESPONSE / message under the session it
  belongs to (`_owner`) — a member writing from their other SIM is still
  themselves. A certificate conversation's `peer_key_id` is empty until the
  answer names it; `bindCertPeer` fills it in without dropping sessions — a
  *different* key (a lost phone's replacement) re-binds and drops them. **A
  certificate below the conversation's `peer_generation` is refused**, which
  is all the lost-phone protection there is: a phone that never saw the new
  generation still accepts the old one.
- **A conversation follows the key bank** (`_keysCurrent` / `_current`): when
  our own key is replaced (the panel's «گوشی گم شد» for us, or a key file
  removed), `_flush` re-binds the conversation to the identity we hold now
  (`upsertConversation` drops the old sessions) and the next send handshakes
  with it; a message on a retired key's session is dropped and re-binds. No
  key at all any more: queued messages fail.
- **The header only claims «رمزشده پساکوانتومی» once it is true**:
  `SecureConversation.quantumSafe` = an `EXISTS` over `sm_sessions.kind =
  'pq'` in both conversation queries; until then it reads «رمزشده · در حال
  ارتقای پساکوانتومی». The upgrade's last step (`_completeUpgrade`, and the
  accepter's standby → `pq`) calls `_changed` so the header turns without a
  new message.
- **Payload additions**: packet type 4 CONTROL (a receipt never looks like a
  message, so the native side can stay silent on it without keys); flag
  `0x80` = delete-after-seen on a text; kinds `0x10` SEEN(sid, counter-up-to)
  and `0x11` DELETE(sid, counter). `decrypt` refuses a control kind in a
  message packet and vice versa.
- **«دیده شد»**: opening a conversation sends one SEEN covering everything new
  (`markSeen`), off via the inbox menu (`secure_meta` `send_seen_receipts`).
- **«حذف پس از دیدن»**: the receiver's copy is marked shown when displayed and
  deleted when the conversation is left (`leaveConversation`).
- **«حذف برای هر دو»**: only for our own messages; the peer deletes only
  *received* rows matching (sid, counter) — nobody can delete the other's words.
- Tables: `sm_conversations` (`peer_generation`, `listed`),
  `sm_sessions` (per-sid state, pending INIT, `kind` = `cert-i` / `cert-r` /
  `pq` / `pq-standby`, `offered_at`, `send_failed`), `sm_answered_requests`, `sm_messages`,
  `sm_inbox`, plus `secure_meta` (`SecureMessageStore`).
- UI: `SecureInboxEntry` (row at the top of the inbox, only while open),
  `SecureInboxScreen`, `SecureConversationScreen`,
  `SecureNewConversationScreen`; `SecureMessagesBloc` (lazy, after
  `KeyBankBloc`) empties itself when the section locks. `SecureLockedView` is
  shared with the key bank screen.

### Tests and verification

Dart: `secure_messenger_test.dart` (44 — real `secure.db` schemas, three
engines over a simulated radio: handshake, queueing, out of order,
duplicates, a replayed request, crossed and lost INITs, dual SIM, seen,
delete-for-both, delete-after-seen, retry, keys replaced by the authority,
hidden contacts, timed messages, groups, and the `certificates` group: the
upgrade after the first message, members issued apart, a request
the authority did not sign, a lost phone's older certificate, a lost upgrade
answer; and 1405/07/29: «a channel that does not come is never silent» (7,
incl. the late old offer), plain threads «never mixed» / «rename both»),
repository, service mapping. Full suite 779, JVM 121, tools 23, panel 12.

**Two phones, real radio (Samsung A33 ↔ Huawei, 1405/07/25, fresh installs, a
directory listing only the sender — history, before the directory was removed):** request and answer 2 + 2 parts and the
first message out **~7 s** after «ارسال»; the upgrade 11 + 10 + 1 parts done
~25 s later, behind the message; every message after that one part, both
directions. Fixed on the way: the header's «پساکوانتومی» before the upgrade,
the «no key file» text for a self-only directory, the «آماده ارسال» card over
an open section.

**Known limits.** A phone holding certificates from two authorities answers
with the first, which the requester may not trust. Removing a member revokes
nothing: their certificate still opens sessions with anyone who has not been
told otherwise (design decision: no revocation).

## The hidden phonebook «دفترچه مخفی» and its calls (phase G)

Matrix rows 11 and 35 (organization: magenta, inter-org: green): a phonebook
of its own, **not in the system address book**, whose calls and SMS are **not
recorded by the OS** or visible to other apps. Decisions (1405/07/06):
a hidden contact who calls while the section is **locked** shows as the bare
number (name only while open); their missed call says only «تماس بی‌پاسخ»; their
**plain SMS are hidden too**; the phonebook and its call history are rows at
the top of Contacts and «اخیر», visible only while the section is open.

### The problem and the shape of the answer

Everything that must happen *while locked* (a call ends, an SMS arrives) runs
in Kotlin, which has no key to `secure.db`. Three pieces make that work
without writing a secret to the main database:

- **Tags** (`hidden/HiddenNumbers.kt`): Kotlin knows the hidden set only as
  HMAC-SHA256(tag key, canonical number) truncated to 16 bytes, in
  SharedPreferences. The 32-byte tag key is sealed by a non-exportable Keystore
  key (`KeystoreKeyWrapper`, alias `hamresan_hidden_tags_v1`). A copy of the
  files shows *how many* numbers are hidden, not which (the phone-number space
  is brute-forceable for an unkeyed hash, not for a Keystore-keyed one). No
  tags → `isHidden` answers false without touching the Keystore, so the
  commercial edition pays nothing. Canonicalization is
  `BlockedNumbers.normalizeToThreadId` on both sides, so `+98…`, `0098…` and
  `09…` all match (verified on the device).
- **Sealed records** (`smscrypto/SealedBox.kt`, pure JVM): one-way sealing to
  the section's own ML-KEM-768 + X25519 key pair — `FORMAT ‖ eph X25519 (32) ‖
  ML-KEM ct (1088) ‖ AES-256-GCM`, key and nonce from HKDF(ssKem ‖ X25519,
  salt = SHA-256(label ‖ recipient ‖ header)), header as AAD. 1137 bytes of
  overhead. Format pinned by `SealedBoxTest` (golden `f7778687…`). The secret
  lives in `secure_meta` `sealing_identity` (`SealingKey`, made on first
  open); the public half is pushed to Kotlin on every open.
- **`sealed_queue`** (main DB **v26**, `hidden/SealedInbox.kt` ↔
  `DatabaseHelper._createSealedQueueTable` / `AppConstants.sealedQueueTable`,
  both `IF NOT EXISTS` — **change together**): `id, kind, blob, created_at`.
  Only `kind` (`call` / `sms`) is in the clear. JSON records:
  `{k:"sms", address, body, timestamp, subscriptionId}`,
  `{k:"call", number, type, date, duration, account}` (`type` = raw
  `CallLog.Calls.TYPE`). Dart opens them with `openSealed` on the crypto
  channel; a blob that does not open (sealed before a reset) is dropped.

### Calls

- Telecom writes every carrier call to `CallLog.Calls` itself; a default
  dialer cannot prevent it. `HiddenCallLog` **moves** the row: seal first,
  then delete (a failed delete is re-sealed next time and deduplicated by
  `hc_calls` UNIQUE(phone, timestamp, call_type)). Sweeps: after a hidden call
  (`onCallRemoved` → polls ~15 s, the row appears a moment later), on every
  `MainActivity.onResume` and before the call-log mirror reads
  (incremental, 2 days back — the row is dated at the call's *start*), and
  over the whole log when the hidden set changes (a contact just hidden takes
  their past calls along).
- `CallLogSyncHandler` also **filters** hidden numbers out of
  `callLogEntries` and the id list the deletion diff uses, so the mirror
  never shows one and drops any it took before the number was hidden.
- `CallInCallService.lookupContactName` returns the in-memory name
  (`HiddenNumbers.setNames`, pushed by `HiddenBloc` on open, cleared on lock)
  or null — never the address book; no photo. A missed hidden call posts a
  bare «تماس بی‌پاسخ» (id `0x5EC1`, no number, no actions, not
  `markMissedCall`-ed — that stores the number in the clear) that opens
  launch action `{type: hiddenCalls}`.

### SMS

- `SmsDeliverReceiver` skips the provider for a hidden sender;
  `HiddenSms.receive` (both app-side receivers, before the `#E:` branch)
  seals the whole message — plain or encrypted — into `sealed_queue` and posts
  the same card as `SecureSmsInbox.arrival` decides (receipts announce
  nothing). `SecureMessenger.drain` takes them first (`HiddenSmsSource`): an
  `#E:` one joins `sm_inbox` like any packet, a plain one is stored as a
  **plain message** (`sm_messages.plain`, deduplicated on phone + body + time)
  in the contact's **plain thread**.
- **Plain and encrypted never share a thread** (owner, 1405/07/29: «چت رمز
  شده و عادی و رمز نشده به هیچ وجه نباید باهم مخلوط شوند»). A hidden
  contact's plain SMS live under `SecureMessenger.plainThread(phone)` =
  `p:<phone>` (`isPlainThread`, `numberOf`): `_receivePlain`,
  `importPlainHistory` and `startPlainConversation` use it, `sendPlain` works
  only on a `p:` thread and sends to `numberOf` with `private: true` (no
  provider write, no handshake, no «حذف پس از دیدن»); the header says
  «پیامک رمزنشده» and a banner says where the encrypted one is. The encrypted
  conversation is keyed by the plain number as before. It used to be one
  thread per number, and an INIT turned a plain chat into an encrypted one.
  The inbox list excludes `p:` threads; a row «پیامک‌های رمزنشدهٔ مخفی» (unread
  count) opens `SecureInboxScreen(plain: true)`. The hidden contact screen has
  «پیام رمز» (mobiles; `SecureStartEncrypted`) and «پیامک رمزنشده»
  (`SecureOpenWith` → the plain thread). `rename` renames both threads.
  Pinned by «never mixed» and «rename both». Verified on the phones.
- `querySms` / `querySmsIds` / `querySmsByIds` filter hidden addresses, so
  the mirror-sync never imports one.
- The ordinary composer refuses a hidden number (`SmsService.sendSms` →
  `HIDDEN_NUMBER`, «این شماره در دفترچه مخفی است؛ از بخش امن پیام دهید»)
  before anything is persisted.

### Hiding a number moves its history

`HiddenBloc._onSave`: canonical numbers (`canonicalPhone`; a number belongs
to one hidden contact) → `hc_contacts`/`hc_numbers` → tags + names to Kotlin
(full call-log sweep) → drain sealed calls → for each **newly** hidden number,
`HiddenHistoryMover.smsHistory` → `SecureImportHistory` (completes only once
stored) → **only then** `purgeSms` (provider thread delete — a no-op without
the SMS role, the native filter then keeps them out of the app — and a hard
delete of every local row **including tombstones**, their FTS `message_search`
rows, pin/archive/SIM/unread marks) and `purgeCalls` (mirror rows, matched
canonically). «از دفترچه تلفن گوشی» fills the form from an address-book
contact and, after saving, offers to delete it there (SIM contacts too).
Deleting a hidden contact stops hiding its numbers; what was moved stays.

### Storage and app

- Tables `hc_contacts`, `hc_numbers` (ordered, indexed by phone),
  `hc_calls`; a keyless conversation has null peer columns in
  `sm_conversations`, a plain message `sm_messages.plain`.
- `HiddenBloc` (**not lazy**, after `MessageBloc`/`CallLogBloc` — it
  refreshes them after moving history — and after `SecureMessagesBloc`): on
  open makes the sealing key, pushes tags/names, sweeps, drains calls; on lock
  clears names; drains again on every call-log change.
- `SecureStore.reset` also calls `HiddenBridge.forget` (tags, tag key,
  sealing key): with no phonebook nothing may stay hidden.
- Channel `…/hidden` (`HiddenHandler`): `setNumbers`, `setNames`,
  `clearNames`, `setSealingKey`, `sweep`, `isHidden`, `forget`,
  `clearMissedNotice`. Keystore/provider work off the main thread.
- UI (`lib/features/hidden/`): `HiddenContactsEntry` / `HiddenCallsEntry`
  (above the lists, so the contacts fast-scroll offsets are untouched),
  `HiddenContactsScreen`, `HiddenContactEditScreen`, `HiddenContactScreen`
  (پیام only on a mobile number), `HiddenCallsScreen`; hidden contacts are
  listed in «گفتگوی رمز» (mobiles only).

### Known gaps

- A **scheduled** message to a hidden number still goes the ordinary way
  (`ScheduledSmsWorker` persists it in `messages` and the provider).
- The carrier's own «تماس از 0912…» SMS names a hidden number in the normal
  inbox (from an alphanumeric sender).
- Without the SMS role, the moved SMS stay in the OS provider (hidden from this
  app only).
- **Not tested over a real radio** (no SIM on the emulator).

### Tests and verification

JVM: `SealedBoxTest` (round trip, wrong key, every altered byte, format,
empty, golden). Dart: repository (order, replace, owners, call dedupe),
`HiddenBloc` (open, refusals, history moved
only after the section has it, drain on call-log change, delete, lock),
messenger (plain receive + dedupe, encrypted from a hidden contact, keyless
send/retry, history import, a keyed conversation stays keyed).

**Device probe (1405/07/06, emulator API 37, org release):** seeded call log
(hidden `+989125555555` missed, ordinary `09127777777` outgoing) →
`setNumbers` 236 ms (Keystore key + full sweep): hidden row gone from the
provider, ordinary row untouched, one `call` blob of 1232 bytes with no
number visible, opened in Dart in 70 ms to the exact record, `null` with
another key; `+98`/`0098` forms match; `forget` un-hides. UI reviewed from
font-accurate renders (black under FLAG_SECURE on a device): fixed a Latin
digit in «شماره ۲», a redundant «رمزنشده» on every plain bubble, the contact's
name repeated on each of their calls, and landlines offered as SMS targets.

## Encrypted groups «گروه رمز» (matrix row 14)

Decisions (1405/07/06): **any member** makes a group ad hoc from key
holders (no key-file or Windows-tool change); the **creator chooses** the mode
— «گفتگوی گروهی» (a reply reaches everyone) or «اطلاع‌رسانی» (members reply to
the creator only); **only the creator** changes membership; «دیده شد» goes
**to the sender only**, under the same on/off setting as one-to-one.

### No multicast, so: fan-out over pairwise sessions

SMS is point-to-point. A group message is sealed **once per member, over that
member's own session** (the pairwise ratchet) — a sender key would save CPU,
not a single SMS. Every property of the pairwise sessions (ratchet,
duplicates, out of order) carries over unchanged, and the cost is plain: one
SMS per recipient per message. A pair that has never talked pays one
handshake (2 + 2 parts) the first time, made automatically.

### Wire (same `Wire.VERSION`; append-only payload additions)

- `FLAG_GROUP` (0x40) on a text kind → 8-byte group id, then the text. A
  group message costs its id and nothing else (`GroupPayloadTest`).
- `KIND_GROUP_INFO` (0x12), a **control** packet (no notification):
  `id ‖ version (varint) ‖ mode ‖ name (varint length, Persian code page) ‖
  count ‖ count × (digit count ‖ packed BCD ‖ key id 8)`. Members are
  everyone **but the creator** (each receiver adds the sender); key ids let a
  phone find **itself** (it may not know its own number); a member reached
  over a certificate that has not answered yet is listed with an all-zero key
  id, and a receiver recognises itself in it by its certificate's number. The
  others are reached by number like anyone else
  (`SecureIdentities.forNumber`). Two members + name: 107
  wire chars, one SMS. ≤100 members, name ≤200 bytes, strict parsing (pad
  nibble, trailing bytes).
- Receipts and «حذف برای هر دو» need nothing new: they name
  `(sid, counter)` of the pairwise session, which identifies a member's copy.

### Rules the engine enforces (`SecureMessenger`)

- A definition is accepted **only from the creator** and only when its
  `version` is newer (`SecureGroupStore.applyInfo`); a group first seen through
  a message (SMS reordered) is a placeholder (`pending_info`) whose creator
  is whoever sends the first definition. A definition that no longer lists
  this phone marks the group `left` (read-only).
- Per member, `_flush` sends: a definition they have not had (`info_version`
  < `version`, **first**), queued one-to-one messages, then queued group
  copies. A dropped member stays `removed` until told, then goes.
- Recipients (`SecureGroup.recipients`): chat → everyone (creator included
  when not us); announce → all members if ours, else the creator. Members the
  bank has no key for are skipped.
- A «دیده شد» names a point in a pair's session, so a group receipt also
  covers that pair's earlier one-to-one messages (and vice versa) — accepted.
- The pairwise conversations a group needs are **unlisted**
  (`sm_conversations.listed = 0`, also for any INIT-created one) until a
  message is said in them.
- Delivery reports: tracking id `g:<messageId>:<phone>` → that copy.

### Storage and UI

Tables `sg_groups` (`creator` null = ours, `pending_info`,
`left_group`), `sg_members` (`info_version`, `removed`), `sg_messages`,
`sg_deliveries` (one per recipient: status, sid, counter), plus
`sm_conversations.listed`. Only `SecureGroupStore` touches them.
`SecureMessagesBloc` carries groups, names, the open group and the candidates
(`SecureLoadGroupCandidates`: encrypted conversations; «افزودن از مخاطبین»
adds mobiles from the address book, canonicalized). Screens: groups in the
«پیام‌های رمز» list (newest first with conversations), `SecureGroupScreen`
(sender names, «دیده شده ۲ از ۳», per-member status sheet, cost line «به N نفر
· هر پیام N پیامک», banners for announce / left / pending), `SecureGroupEditScreen`
(mode fixed after creation; members whose key left the bank are kept, not
silently dropped), «گروه رمز جدید» atop «گفتگوی رمز». `SecureComposer` /
`SecureBanner` are shared with the one-to-one thread.

### Tests and verification

JVM: `GroupPayloadTest`. Dart: three simulated phones
(definition first, chat reply to all incl. a new pair's handshake, announce
reply to creator only, seen 2 of 2, removal told, forged redefinition refused,
delete for all, message before its definition, retry of the failed copy only,
delivery reports), `secure_group_store_test` (recipients, applyInfo rules,
placeholder, edit/removed lifecycle).

**Real-crypto probe (1405/07/06, emulator API 37, org release + dev anchor):**
three dev key files, only the radio replaced. Group made and delivered with
two handshakes in 953 ms (the handshake was larger then); definition 107 chars / 1 part; Persian + emoji group
message 86 chars / 1 part per member, 274 ms; B's reply reached A and C (B↔C
handshake made on the way); seen = 2/2; removal told (C `left`); delete for
all; announce reply reached the creator only; one-to-one lists stayed empty.
22 SMS / 79 parts for the whole run. UI reviewed from font-accurate renders.

## Rows 16, 29, 31, 32, 36 and the hidden-phonebook gaps (1405/07/12)

Decision: proceed without the mentor's answers; the decisions
below are the project's own and say so in the mentor report.

- **Real authority.** Created with the tool on 1405/07/12, id
  `b45a8048bd2d0314`; its public key is `TrustAnchors._production`. The
  private file, its password, the roster and the issued key files live in
  `C:\Users\hp\Hamresan-Authority\` (outside the repo, never committed;
  `README-FA.txt` there).
- **Row 16 «پیام زمان‌دار»** = a lifetime, not scheduled sending. Payload flag
  `FLAG_TIMED` (0x20) + varint seconds after the group id (≤ 1 week,
  `TimedPayloadTest`). Ours goes `ttl` after sending, theirs `ttl` after first shown
  (Signal's rule). `ttl` on `sm_messages`/`sg_messages`;
  `purgeExpired` on open and by a timer armed from `nextExpiry`. The
  composer's timer button picks «پس از دیدن» or a lifetime.
- **Row 29 «کنترل امنیت سامانه»** = a device check (Settings → امنیت): root,
  hooking frameworks in this process, a signer other than the release key,
  debuggable, emulator, screen lock, USB debugging, accessibility services
  (named via a `<queries>` entry), patch age, storage encryption, where the
  vault key lives (StrongBox/TEE/software), default SMS/dialer roles.
  `DeviceSecurity.kt` reports facts; `DeviceSecurityReport` weighs and words
  them (tested). Verified on the Xiaomi test phone.
- **Row 32 «عکس از ورود ناموفق»**: off by default; turning it on asks for
  CAMERA (new manifest permission, `uses-feature required=false`). Every
  third wrong app PIN in a row → one JPEG per camera (Camera2, no preview, no
  sound), sealed with `SealedBox` to the section key into
  `noBackupFilesDir/intruder/`; `IntruderRepository` moves them into
  `ip_photos` once the section is open. A report dialog at the next right
  PIN (`IntruderReporter`). The Android 12+ camera indicator still flashes.
- **Row 31 «متن پوششی»** (organization build only): message and receipt
  packets as words. **Format v2 (1405/08/07)**, after the mentor's «یکتا» /
  «اسماءالحسنی»: packet ‖ 2 checksum bytes (SHA-256 of `hamresan.cover.v2` ‖
  packet) ‖ a 1 bit ‖ 0 bits to a multiple of 12, then **12 bits a word** from a
  frozen **4096-word** list (`CoverWords.kt`, generated — never hand-edited).
  Taken from the mentor: n bits a word from a 2ⁿ-word bank. Not taken: his
  password/AES, shuffled map and rotations (the session already encrypts and
  authenticates, and a receiver must recognise a cover with no key) and his
  side-info symbol for the padding (the trailing 1 bit replaces it). His bank
  (131 072 words, n=17) was measured unusable as it stands — 14 of 19 common
  Persian obscenities and 5 of 15 English ones in it, sacred names, ZWNJ-less
  compounds, Arabic letters, a random 2¹⁷ cut that dropped common words (41 %
  of our old English list missing). Decisions: 4096 words; Persian =
  everyday words chosen by hand and kept only where his bank has them (Arabic
  ي/ك folded); English = chosen by hand. Both exclude profanity, sexual and
  romantic words, insults, sacred and religious terms, politics, military and
  violence, drugs/alcohol, death/disease and phishing triggers; `CoverBlocked.kt`
  holds that list as truncated SHA-256 only and `CoverTextTest` checks it. SMS
  cost is per character, so a bigger bank would not have been cheaper: a 40-byte
  packet is 28 words, ~170 characters (3 Persian parts, was 4) or ~190 (2
  English parts). Sentences of 5–12 words end where a word's value says so;
  English ones are capitalised. Every receiver, every edition, runs
  `CoverText.uncover` first, so the rest of the pipeline only ever sees `#E:`.
  Handshakes are never covered. Setting in the «پیام‌های رمز» menu
  (`secure_meta` `cover_text`). Verified 1405/08/07: organization release
  2000000177 on the emulator, a Persian and an English cover injected as
  incoming SMS — kept out of `content://sms`, «پیام رمز جدید» for the
  message-shaped one. Not yet sent between two phones.
- **Row 36**: was a «مخاطبین رمز» row atop Contacts listing the key-bank
  directory. **Removed (1405/07/29, design decision)**: with the directory gone
  it was only a second door to «گفتگوی رمز»; the hidden phonebook stays.
- **Hidden-phonebook gaps**: scheduling to a hidden number is refused; one
  hidden *after* scheduling is sent with no provider row and sealed as
  `{outgoing: true}` (`HiddenSms.sendPrivately`, both deliverers). An
  operator's SMS (a service sender) naming a hidden number is sealed into that
  contact's conversation (`about`) and filtered from the mirror. Without the
  SMS role, saving a hidden contact offers to take it.
- **Channel**: `security.*` methods ride `…/hidden` (`HiddenHandler` →
  `SecurityHandler`).
- **Real-radio test (1405/07/12, Samsung A33 + Xiaomi Mi 10T, commercial 141
  activated, real authority):** key files imported on both; 1:1 encrypted SMS
  both ways (with the larger handshake of the time ~70 s incl. opening the
  section by hand, then ~6 s per 1-part message), «دیده شد» both ways, timed 30 s (gone on both phones),
  delete-after-seen, delete for both, a 2-member group (definition, message,
  «دیده شده ۱ از ۱», reply), hidden contact (plain SMS kept out of the
  provider; missed call swept, bare «تماس بی‌پاسخ», number only while locked,
  name while open), intruder photos, device check. **Found and fixed on the
  phones:** (1) dual-SIM peers answer from the SIM that is not in the key
  bank — packets are now routed by key id / session id (`_owner`,
  `phoneForPeerKey`, `phonesWithSession`), a dropped RESPONSE used to stall
  the channel for 24 h; (2) encrypted SMS went out on the default SMS SIM
  (no credit there) — «ارسال با سیم …» in the «پیام‌های رمز» menu
  (`secure_meta sms_sim`); (3) a conversation/group screen left empty after
  the section re-locked under it — the bloc keeps the screen phone/group across
  a lock; (4) conversation title showed the number; (5) device-check labels.
  MIUI dropped a long multi-part request once (`checkSmsCmd … smsBlocked`);
  seen again 1405/07/14 (Samsung → Xiaomi, parts that never arrived, the
  system never assembled it). A lost request is recovered by the 15-min retry
  and the crossed-INIT rule.
- **Not done:** row 25 (location / wipe by a special SMS) — written, then
  taken out of the build until an SMS-triggered remote action and wipe is
  decided on; the source is kept outside the repository. Row 12 (encrypting the whole main DB) — declined:
  Kotlin opens that DB while the app is dead with no key, everything secret is
  already in SQLCipher, and ordinary SMS also live in the OS provider.

## Release builds

```bash
scripts/release_build.sh                          # commercial (store)
scripts/release_build.sh --flavor organization    # organization (direct APK)
```

PowerShell: `.\scripts\release_build.ps1 [-Flavor organization]`.

The APK lands in `build/app/outputs/flutter-apk/app-<flavor>-release.apk`.
Besides the existing signature guard, the scripts now read the **built manifest
back** with `aapt2 dump badging` and refuse the APK unless the package is
`ir.hamrasan.app` and the versionCode / versionName are exactly what the flavor
must produce. `APPLICATION_ID` and `ORGANIZATION_VERSION_CODE_BASE` there are a
**mirror of `android/app/build.gradle.kts` — change them together.**

The organization APK is **never** uploaded to a store. Record each one handed out
below.

### Organization APK history

| Date | versionCode | versionName | Handed to |
|---|---|---|---|
| — | — | — | none yet (2000000165 built 1405/07/25, `e0e7994`; 2000000176 built 1405/08/05 with the activation gate; neither handed out) |

## Log

| Date | Change |
|---|---|
| 1405/08/05 | **Organization activation (row 1).** `ActivationTarget` (inter-org `111111`, organization `222222`), `org_activation_code`, `OrganizationActivationGate` before the PIN, `EditionState.activated` / `ActivateEdition`, shared `ActivationCodeForm`. Panel MSI 1.5.0: «فعال‌سازی سازمانی» menu, «برنامهٔ عضو» on the member form and the delivery sheet; CLI `--organization`. Verified: organization release 2000000176 fresh on the emulator (`4dde22`): gate first, no permission or PIN before it, the inter-org code `66f7450092` refused, the CLI's organization code `9ecc6095a7` (typed `9ECC6-095A7`) accepted, kept across a cold start, secure section/key bank/device check present, no «نسخه بین‌سازمانی» row; commercial release 176 on the Samsung (`b60966`): no gate, organization code `f87be27c18` refused, `9c4a48e93a` activates, deactivation returns to the form (left deactivated). Release panel self-test passed. Dart 828, tools 25 + panel 13. |
| 1405/07/29 | **No directory, no update file** (the mentor's 10-17 comment in full; owner: no member names in the app or the key): a key file is the member's own identity + certificate only (format 1, 261 B); `Directory.kt`, `UpdateFile.kt`, `update.hku`, «فایل قدیمی» and the `UpdateFile.MAGIC` ↔ `isUpdateFile` mirror are gone from the app, CLI and panel (MSI 1.4.0); one own key per authority (`kb_own_keys`). «گفتگوی رمز» = contact picker or a typed mobile; any number. **Failure states** (`send_failed`, `SecureChannelInfo`, two banners with «دوباره تلاش», 2 min); the upgrade unseen (header only «رمزشده»), re-offered 2 min after the peer is heard. **Fixed:** a late old upgrade offer deleted the standby the offerer used (`keepNewestStandby`). Hidden contacts' plain SMS in their own `p:` thread and list. «مخاطبین رمز» removed. Secure.db reset on the phones (schema change, no migrations). New authority `7fda025a5a997b93`, `Hamresan-Authority` reset; keys re-issued. Device-tested Samsung ↔ Xiaomi, then Samsung ↔ Huawei (a member added that day, nobody else's file touched): channel, both ways, upgrade, group, timed, after-seen, delete-for-both, hidden plain/encrypted/calls, no `#E:` in either provider. Mentor docs (manual, report, panel guide) rewritten with new screenshots (a FLAG_SECURE-less build used for the shots only, never committed; the real 174 reinstalled after). `KeysState.newMember` / `confirmAdd` for the panel previews. Commercial 174. |
| 1405/07/27 | **The secure section's own PIN** (6 digits, never the app PIN, its own attempt budget) and **fingerprint** (a Keystore key needing a strong biometric for every use, invalidated by a new enrollment; Samsung's weak face is not accepted). The app PIN no longer touches the section — removable, recoverable, changeable freely — and is **4 digits in every edition**. «پیام رمز جدید» opens the section's unlock after the app lock (`AppLock.whenDown`); `PinHandoff` removed. Verified on the Samsung A33 (commercial 171, activated). JVM 127, Dart 776. |
| 1405/07/26 | **One scheme only.** The full ML-KEM handshake (10 + 11 parts), passphrase groups and «شماره‌های من» are removed from the app, the tools and these notes: every session is the certificate handshake, every own key comes from a key file with its certificate. Wire types renumbered (INIT 2, RESPONSE 3); the directory lists X25519 keys only (format 2) and names a member by their certificate key id; `Canon.text` and the group KDF gone. `secure.db` collapsed to one schema, version 1 (no migrations: nothing was installed outside development). New: a replayed session request is never answered again (`sm_answered_requests`). Panel MSI 1.3.0. Golden vectors re-pinned. **No backward compatibility anywhere** (nothing is released, only the developer has builds): the main database collapsed to its `_createDB` at version 1 too (26 migrations, the v11 back-fill and the dead `call_logs.sim_slot` gone), no plaintext-PIN upgrade, no persisted-unlock clean-up, no legacy theme key, no panel re-issue of files an earlier panel made. JVM 122, tools 23, panel 13 + release self-test, Dart 740. |
| 1405/07/25 | **Member certificates** (`MemberCert`, `CertHandshake`, `Upgrade`, secure.db v7, panel 1.2) and the two-phone test (Samsung A33 ↔ Huawei, fresh installs, a directory listing only the sender): 2 + 2 parts, first message ~7 s, upgrade ~25 s later, both directions. Fixed on the way: the header's «پساکوانتومی» before the upgrade, the «no key file» text for a self-only directory, the «آماده ارسال» card over an open section. No fallback for certificate-less files (owner: nothing in production). Release builds: commercial 165, organization 2000000165. |
| 1405/07/12 | **Real authority** (b45a8048bd2d0314) in the app. Rows 16 (timed messages, secure.db v6), 29 (device check), 31 (cover text, org), 32 (intruder photos, CAMERA), 36 (encrypted contacts row); hidden gaps (scheduled, operator notice, role offer). Row 25 parked, row 12 declined. Real-radio test on two phones; dual-SIM routing, SIM choice and re-lock fixes. JVM 98, Dart 675. Commercial 141 installed on both test phones. |
| 1405/07/15 | **Issuance panel phase 2** (MSI 1.1.0): who holds an old file + «دفتر صدور» (`issuance-log.csv`, delivery statuses), «گوشی گم شد» (new key + new password, retired keys never re-issued), edit / remove member, `update.hku` (password-less directory update, `UpdateFile.kt`, app import without a password). All-or-nothing `Issuance.issue`. **App:** conversations re-bind to the key bank's current keys (a lost phone's key used to stay in use for ever). **Found driving the installed MSI:** a confirmation dialog's own coroutine scope cancelled «گوشی گم شد» half-way — issued, but reported as failed, no password shown; now `KeysState.launch`, pinned by a real-click test. Tools 18 + panel 12, JVM key bank 26, Dart 693+. Commercial 150 on the Samsung. |
| 1405/07/14 | **Issuance panel** (`tools/keybank/panel/`, MSI) and an end-to-end run on both phones with it: activation codes from the panel (one typed `9C4A4-8E93A`), key files issued by the panel from the real authority, imported, encrypted SMS both ways incl. Persian, seen receipts, no `#E:` in either provider. **Fixed on the way:** `SecureLockedView` asked a phone with no PIN for one (`openSecureSection`); INITs announced nothing; a lost INIT + crossed INIT deadlocked (`crossedGrace`, `pendingTimeout` 24 h → 15 min, drop paths logged); `Issuance` left stale `NNN-*.hkb` behind after a reorder; `release_build.ps1` died on a JDK stderr warning. JVM 103, Dart 680, tools 8+7. Commercial 143 on both phones. |
| 1405/07/08 | **Answering a call past the app lock (all editions).** Checked in the organization / inter-org editions too: the call screen and the app lock are shared code, so the bug («برای پاسخ به تماس باید رمز وارد کرد» — the relock landed over a ringing call, `isInCall` excludes `incoming`) was in all three and is fixed in all three. New «رمز برای پاسخ به تماس» (Settings → امنیت) — off by default in every edition, no edition-specific default. The secure section keeps its own lock and is unaffected; a hidden-phonebook caller is not changed by it. Details in `dialer-and-calls.md`. |
| 1405/07/06 | **Encrypted groups (row 14).** Ad hoc groups over pairwise sessions: `FLAG_GROUP` + 8-byte id on text, `KIND_GROUP_INFO` control (creator-only, versioned, members with key ids); `secure.db` v5 (`sg_*`, `sm_conversations.listed`); chat / announce modes; per-member deliveries, «دیده شده N از M», delete for all, retry per copy; group screens. Verified with real crypto on the emulator. |
| 1405/07/06 | **Phase G.** Hidden phonebook «دفترچه مخفی» + «تماس‌های مخفی»: Keystore-keyed number tags in Kotlin, `SealedBox` (ML-KEM-768 + X25519 sealing to the section's own key), `sealed_queue` (main DB v26), call-log sweep, hidden names only while open, bare missed-call card, hidden contacts' plain SMS sealed and shown as keyless conversations, history moved on hiding, ordinary composer refuses hidden numbers; `secure.db` v4. Native half verified on the emulator. Also: `SecureSmsInbox.kt` excluded from `tools/keybank` (its build had broken in phase F). |
| 1405/07/05 | **Phase F.** Encrypted SMS: `secure_queue` (DB v25) parks ciphertext natively, never `content://sms` / `messages`; bare «پیام رمز جدید» notification; `SecureMessenger` (automatic handshake, queueing, seen receipts, delete-after-seen, delete-for-both); CONTROL packet type and payload kinds; `secure.db` v3; «پیام‌های رمز» screens. Real-crypto probe on the emulator passed; found and fixed a member's landline chosen as SMS target. Real-radio test pending. |
| 1405/07/05 | **Phase E.** Key bank: hardcoded authority public key (ML-DSA-65 + Ed25519), signed directories in password-sealed key files, passphrase groups (Argon2id + per-number keys), frozen `Canon`; `secure.db` v2 + `KeyBankRepository` / `KeyBankBloc` / «بانک کلید» screen; `KeyFilePicker`; `AppHandoff` (the picker no longer closes the section — found on the phone); Windows tool `tools/keybank/`; release scripts refuse the development authority. Verified on the phone; group id matches the JVM. (Passphrase groups removed 1405/07/26.) |
| 1405/07/05 | **Phase D.** SMS crypto core: ML-KEM-768 + X25519 hybrid handshake, per-direction hash ratchet with AES-256-GCM, Persian one-byte code page, GSM-7 `#E:` wire format, stateless `…/sms_crypto` channel + `SmsCryptoService`; Bouncy Castle 1.86; NIST ACVP / RFC vectors and a golden vector; verified on the phone under R8. (That handshake was replaced by the certificate handshake, 1405/07/26.) |
| 1405/07/05 | 6-digit PIN in the secure editions (`PinPolicy`, stored length, `pinTooShort`); «حذف رمز عبور» redraw fix; vendored `androidx.sqlite` also verified against Google Maven itself (VPN); phase C verified end to end on the phone and the phone restored. |
| 1405/07/05 | **Phase C.** Secure section: Keystore-bound vault (`VaultCrypto`, `KeystoreKeyWrapper`, `SecureVaultHandler`), SQLCipher `secure.db`, `SecureSessionBloc` + `SecureSessionGuard`, lock icon in every tab, FLAG_SECURE, `PinAttemptLimiter`, `VerifyPinScreen`, PIN change/remove/recover kept consistent with the vault, «بخش امن» in Settings, vendored `androidx.sqlite`. Device-verified on the emulator; a provider-order crash found on the device and pinned by a test. |
| 1405/07/05 | **Phase B.** Inter-organizational activation in the mentor's existing format: pure-Dart BLAKE3 pinned to the S2MS `Blake3.java`, `ActivationCode`, `DeviceIdentityHandler`, `ActivationRepository` (code re-verified per read), `EditionBloc`, `InterOrgActivationScreen`, «نسخه بین‌سازمانی» row. Device-verified with Java-computed codes. |
| 1405/07/05 | **Phase A.** Two Gradle flavors, one applicationId and signing key; organization versionCode band (`2_000_000_000 + N`) with a configuration-time range check; `AppEdition` + `verifyBuildFlavor`; crash reporting compiled out of the organization edition; «نوع نسخه» in About; release scripts take a flavor and verify package / versionCode / versionName from the APK. Verified: commercial over organization → `INSTALL_FAILED_VERSION_DOWNGRADE` (emulator); organization → organization update keeps data (emulator); commercial in-place on the test phone keeps data and both roles. |
