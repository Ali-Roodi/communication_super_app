# هم‌رسان (Hamresan)

An Android SMS and phone app with a Persian (RTL) interface — the phone's default
SMS app and default dialer — in three editions:

| Edition | Delivered as |
|---|---|
| **تجاری** (commercial) | The store APK (بازار / مایکت) |
| **بین‌سازمانی** (inter-organizational) | The commercial APK, unlocked in the app by an activation code |
| **سازمانی** (organization) | A separate APK, distributed directly, that opens only with its own activation code |

The two secure editions add a secure section with its own PIN, post-quantum
encrypted SMS and encrypted groups, a key bank issued by the organization's
authority, a hidden phonebook, a device security check and intruder photos; the
organization edition adds cover text.

Flutter (Dart) for the app, Kotlin for the Android side, BLoC for state, SQLite
and SQLCipher for storage. No backend.

## Build

Requirements: Flutter (Dart SDK ^3.10.1), the Android SDK, JDK 21 (for the
release scripts and the Windows tool).

```bash
flutter pub get
flutter run                          # commercial (the default flavor)
flutter run --flavor organization    # organization
flutter analyze
flutter test
```

Release APKs — every check run, versionCode from git:

```bash
scripts/release_build.sh                        # the store APK
scripts/release_build.sh --flavor organization  # the organization APK (never to a store)
```

A release build needs `android/key.properties` and the signing keystore, which
are **not** in this repository.

## Layout

```
lib/                 the Flutter app (core/ + one folder per feature)
android/             the Android side (Kotlin under app/src/main/kotlin/…)
test/                Dart unit and widget tests
tools/keybank/       Windows: key-bank CLI and «پنل صدور هم‌رسان» (MSI)
scripts/             release builds, keystore backup
docs/                documentation — start at docs/README.md
```

## Documentation

- [`docs/README.md`](docs/README.md) — the index.
- [`docs/DEVELOPER_GUIDE.md`](docs/DEVELOPER_GUIDE.md) — read before changing
  anything: the rules that apply everywhere and which area note covers what.
- [`docs/architecture/editions.md`](docs/architecture/editions.md) — the editions,
  activation, the secure section and SMS encryption.
