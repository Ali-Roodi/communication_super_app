# Vendored Maven artifacts

A local Maven repository holding **only** the artifacts below, declared in
`android/build.gradle.kts` after `google()` / `mavenCentral()` and scoped to
their group, so it is used only when Google Maven cannot be reached.

## Why it exists

`sqflite_sqlcipher` (the secure section's encrypted database) needs
`androidx.sqlite:sqlite:2.5.2`. Google Maven (`dl.google.com`) answers 404 for
everything from this development network, and Gradle's cache is per
repository, so an artifact fetched once through a mirror is not reused by a
later build that does not declare that mirror. Vendoring the exact, verified
bytes makes the build reproducible here and on CI without trusting a mirror at
build time.

## Contents and provenance

| Artifact | Files |
|---|---|
| `androidx.sqlite:sqlite:2.5.2` | `.pom`, `.module` (Kotlin-multiplatform root; Android resolves through it to `sqlite-android`) |
| `androidx.sqlite:sqlite-android:2.5.2` | `.pom`, `.module`, `.aar` |

Fetched 1405/07/05 (2026-09-27) through `maven.aliyun.com/repository/google`
and verified **byte for byte** against a second, independent mirror
(`maven.myket.ir`): every file's SHA-256 matched. Checksums are in
`SHA256SUMS`; check them with `sha256sum -c SHA256SUMS` from this folder.

## Changing or removing

- To upgrade: replace the files with the new version fetched the same way,
  verify against two independent sources, update `SHA256SUMS`, and bump the
  version the plugin asks for — never edit a vendored file by hand.
- If Google Maven becomes reachable, this folder can be deleted: `google()` is
  declared first and serves the same artifacts.
