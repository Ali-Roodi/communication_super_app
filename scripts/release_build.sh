#!/usr/bin/env bash
# Builds the release APK that gets uploaded to Bazaar / Myket.
# POSIX twin of release_build.ps1 — this is the one CI runs.
#
# WHY THIS EXISTS — versionCode must never repeat.
#
# `pubspec.yaml` says `version: 1.0.0+1`. That `+1` is a placeholder for local
# development and must NOT reach a store: every upload needs a versionCode
# strictly greater than the last one, and a hand-edited number in pubspec is
# forgotten exactly once and then the upload is rejected at the store's door.
#
# So the two halves come from git instead, and `flutter build` overrides
# pubspec with them:
#   versionName  <- the tag on HEAD (`v1.2.3` -> `1.2.3`), else pubspec's name
#   versionCode  <- `git rev-list --count HEAD`
#
# Commit count is used rather than a CI run number because it is the same
# number whether the build runs on a laptop or on a runner, needs no state kept
# anywhere, and only ever grows. It does not restart at 1 for a new release
# branch the way a per-workflow counter does.
#
# Usage: scripts/release_build.sh [--skip-verify]

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skip_verify=0
[[ "${1:-}" == "--skip-verify" ]] && skip_verify=1

# --- version name -----------------------------------------------------------
if tag="$(git -C "$repo" describe --tags --exact-match HEAD 2>/dev/null)"; then
  version_name="${tag#v}"
  echo "versionName from tag: $version_name"
else
  version_name="$(sed -n 's/^version:[[:space:]]*\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' "$repo/pubspec.yaml")"
  [[ -n "$version_name" ]] || { echo "Could not read 'version:' out of pubspec.yaml" >&2; exit 1; }
  echo "HEAD carries no tag - versionName from pubspec: $version_name"
  echo "  (tag the release commit with 'git tag v$version_name' before a store upload)"
fi

# --- version code -----------------------------------------------------------
version_code="$(git -C "$repo" rev-list --count HEAD)"
echo "versionCode from commit count: $version_code"

# A dirty tree means the APK does not match any commit, so the versionCode
# above names something that is not what was built.
if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
  echo "WARNING: working tree is dirty - this APK will not match commit $version_code"
fi

# --- build ------------------------------------------------------------------
echo
flutter build apk --release --build-name="$version_name" --build-number="$version_code"

apk="$repo/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$apk" ]] || { echo "APK not found at $apk" >&2; exit 1; }

# --- signature check --------------------------------------------------------
# android/key.properties is gitignored, so a fresh clone (or CI without the
# secret) signs the RELEASE build with the DEBUG key — see
# android/app/build.gradle.kts. That APK installs and runs fine, which is
# exactly why it can be uploaded by mistake.
if [[ "$skip_verify" -eq 0 ]]; then
  # ANDROID_HOME first: android/local.properties is gitignored, so on a CI
  # runner it does not exist at all and reading it would abort the script
  # under `set -e` — after a successful build, which is the worst place to die.
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk" && -f "$repo/android/local.properties" ]]; then
    sdk="$(sed -n 's/^sdk\.dir=//p' "$repo/android/local.properties" | sed 's/\\\\/\//g; s/\\/\//g')"
  fi

  # The Windows SDK ships only apksigner.bat; a Linux runner ships only the
  # extensionless shell script. Globbing on both is what makes this the same
  # script in CI and on the laptop.
  apksigner="$(ls -d "$sdk"/build-tools/*/apksigner "$sdk"/build-tools/*/apksigner.bat 2>/dev/null | sort -V | tail -1 || true)"

  # apksigner is a JVM tool and says so in a way that looks like ordinary
  # output. Without this, a machine with no `java` on PATH made the check
  # print "JAVA_HOME is not set", find no "Android Debug" in that text, and
  # report the signature OK — a false pass on the one thing this guard exists
  # to catch. Android Studio's bundled JBR is what Flutter itself builds with.
  if [[ -z "${JAVA_HOME:-}" ]] && ! command -v java >/dev/null 2>&1; then
    for candidate in "/c/Program Files/Android/Android Studio/jbr" "$LOCALAPPDATA/Programs/Android Studio/jbr"; do
      [[ -x "$candidate/bin/java" ]] && { export JAVA_HOME="$candidate"; break; }
    done
  fi

  if [[ -z "$apksigner" ]]; then
    echo "apksigner not found under '${sdk:-<no sdk path>}' - skipping signature check"
  elif ! certs="$("$apksigner" verify --print-certs "$apk" 2>&1)"; then
    echo "apksigner could not read the APK - signature UNVERIFIED:" >&2
    echo "$certs" >&2
    exit 1
  elif ! grep -q 'certificate DN:' <<<"$certs"; then
    # Ran, exited 0, but printed no certificate — treat as unverified, never OK.
    echo "apksigner printed no certificate - signature UNVERIFIED:" >&2
    echo "$certs" >&2
    exit 1
  else
    echo "$certs"
    if grep -q 'Android Debug' <<<"$certs"; then
      echo "REFUSING THIS APK: it is signed with the DEBUG key. Restore android/key.properties and android/upload-keystore.jks, then rebuild." >&2
      exit 1
    fi
    echo "Signature OK - not the debug key."
  fi
fi

# --- summary ----------------------------------------------------------------
echo
echo "APK          $apk"
echo "versionName  $version_name"
echo "versionCode  $version_code"
echo
echo "Record versionCode in the history table of docs/publishing/store-release.md."
