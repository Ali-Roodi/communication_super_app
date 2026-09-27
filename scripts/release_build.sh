#!/usr/bin/env bash
# Builds a release APK of either edition.
# POSIX twin of release_build.ps1 — this is the one CI runs.
#
#   commercial   (default) the APK uploaded to Bazaar / Myket
#   organization           the APK handed to an organization directly —
#                          NEVER uploaded to a store
#
# See docs/architecture/editions.md for why there are two and why they share
# one applicationId.
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
# The organization flavor adds ORGANIZATION_VERSION_CODE_BASE to that count in
# android/app/build.gradle.kts; this script does not add it, it CHECKS that the
# APK came out with it (see "manifest check" below).
#
# Usage: scripts/release_build.sh [--flavor commercial|organization] [--skip-verify]

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# MIRROR of android/app/build.gradle.kts — change the two together.
readonly APPLICATION_ID="ir.hamrasan.app"
readonly ORGANIZATION_VERSION_CODE_BASE=2000000000

flavor="commercial"
skip_verify=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavor)
      [[ $# -ge 2 ]] || { echo "--flavor needs a value: commercial | organization" >&2; exit 2; }
      flavor="$2"; shift 2 ;;
    --skip-verify)
      skip_verify=1; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: scripts/release_build.sh [--flavor commercial|organization] [--skip-verify]" >&2
      exit 2 ;;
  esac
done
case "$flavor" in
  commercial|organization) ;;
  *) echo "Unknown flavor '$flavor' — expected commercial or organization" >&2; exit 2 ;;
esac
echo "Edition: $flavor"

# --- version name -----------------------------------------------------------
if tag="$(git -C "$repo" describe --tags --exact-match HEAD 2>/dev/null)"; then
  version_name="${tag#v}"
  echo "versionName from tag: $version_name"
else
  version_name="$(sed -n 's/^version:[[:space:]]*\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' "$repo/pubspec.yaml")"
  [[ -n "$version_name" ]] || { echo "Could not read 'version:' out of pubspec.yaml" >&2; exit 1; }
  echo "HEAD carries no tag - versionName from pubspec: $version_name"
  echo "  (tag the release commit with 'git tag v$version_name' before a release)"
fi

# --- version code -----------------------------------------------------------
build_number="$(git -C "$repo" rev-list --count HEAD)"
echo "Build number from commit count: $build_number"
if [[ "$flavor" == "organization" ]]; then
  expected_version_code=$((ORGANIZATION_VERSION_CODE_BASE + build_number))
  expected_version_name="${version_name}-org"
else
  expected_version_code="$build_number"
  expected_version_name="$version_name"
fi
echo "Expected versionCode: $expected_version_code"

# A dirty tree means the APK does not match any commit, so the versionCode
# above names something that is not what was built.
if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
  echo "WARNING: working tree is dirty - this APK will not match commit $build_number"
fi

# --- build ------------------------------------------------------------------
echo
flutter build apk --release --flavor "$flavor" \
  --build-name="$version_name" --build-number="$build_number"

apk="$repo/build/app/outputs/flutter-apk/app-$flavor-release.apk"
[[ -f "$apk" ]] || { echo "APK not found at $apk" >&2; exit 1; }

# --- Android SDK --------------------------------------------------------------
# ANDROID_HOME first: android/local.properties is gitignored, so on a CI
# runner it does not exist at all and reading it would abort the script
# under `set -e` — after a successful build, which is the worst place to die.
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk" && -f "$repo/android/local.properties" ]]; then
  sdk="$(sed -n 's/^sdk\.dir=//p' "$repo/android/local.properties" | sed 's/\\\\/\//g; s/\\/\//g')"
fi

# The newest build-tools that carries the tool. The Windows SDK ships
# `apksigner.bat` / `aapt2.exe`; a Linux runner ships the bare names. Globbing
# on both is what makes this the same script in CI and on the laptop.
build_tool() {
  ls -d "$sdk"/build-tools/*/"$1" "$sdk"/build-tools/*/"$1".bat "$sdk"/build-tools/*/"$1".exe 2>/dev/null \
    | sort -V | tail -1 || true
}

# --- manifest check ---------------------------------------------------------
# The edition is decided by two numbers in the built manifest, so they are read
# back out of the APK rather than trusted from the command line: the package
# name (both editions MUST be ir.hamrasan.app, or a store stops recognising the
# install) and the versionCode band (an organization APK below the base is one
# a store would "update" into the commercial app).
if [[ "$skip_verify" -eq 0 ]]; then
  aapt2="$(build_tool aapt2)"
  if [[ -z "$aapt2" ]]; then
    echo "aapt2 not found under '${sdk:-<no sdk path>}' - manifest UNVERIFIED" >&2
    exit 1
  fi
  # Captured whole, then cut: `| head -1` would let aapt2 die of SIGPIPE, and
  # under pipefail that non-zero status aborts the script at this line.
  if ! badging="$("$aapt2" dump badging "$apk" 2>/dev/null)"; then
    echo "aapt2 could not read the APK - manifest UNVERIFIED" >&2
    exit 1
  fi
  badging="$(grep -m1 "^package: " <<<"$badging" || true)"
  package_name="$(sed -n "s/.*package: name='\([^']*\)'.*/\1/p" <<<"$badging")"
  version_code="$(sed -n "s/.* versionCode='\([^']*\)'.*/\1/p" <<<"$badging")"
  apk_version_name="$(sed -n "s/.* versionName='\([^']*\)'.*/\1/p" <<<"$badging")"
  if [[ "$package_name" != "$APPLICATION_ID" ]]; then
    echo "REFUSING THIS APK: package is '$package_name', expected '$APPLICATION_ID'." >&2
    exit 1
  fi
  if [[ "$version_code" != "$expected_version_code" ]]; then
    echo "REFUSING THIS APK: versionCode is '$version_code', expected '$expected_version_code' for the $flavor edition." >&2
    exit 1
  fi
  if [[ "$apk_version_name" != "$expected_version_name" ]]; then
    echo "REFUSING THIS APK: versionName is '$apk_version_name', expected '$expected_version_name'." >&2
    exit 1
  fi
  echo "Manifest OK - $package_name, versionCode $version_code, versionName $apk_version_name."
fi

# --- signature check --------------------------------------------------------
# android/key.properties is gitignored, so a fresh clone (or CI without the
# secret) signs the RELEASE build with the DEBUG key — see
# android/app/build.gradle.kts. That APK installs and runs fine, which is
# exactly why it can be uploaded by mistake.
if [[ "$skip_verify" -eq 0 ]]; then
  apksigner="$(build_tool apksigner)"

  # apksigner is a JVM tool and says so in a way that looks like ordinary
  # output. Without this, a machine with no `java` on PATH made the check
  # print "JAVA_HOME is not set", find no "Android Debug" in that text, and
  # report the signature OK — a false pass on the one thing this guard exists
  # to catch. Android Studio's bundled JBR is what Flutter itself builds with.
  if [[ -z "${JAVA_HOME:-}" ]] && ! command -v java >/dev/null 2>&1; then
    for candidate in "/c/Program Files/Android/Android Studio/jbr" "${LOCALAPPDATA:-}/Programs/Android Studio/jbr"; do
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
echo "Edition      $flavor"
echo "APK          $apk"
echo "versionName  $expected_version_name"
echo "versionCode  $expected_version_code"
echo
if [[ "$flavor" == "organization" ]]; then
  echo "ORGANIZATION APK - direct distribution only. NEVER upload it to a store."
  echo "Record it in the organization history table of docs/architecture/editions.md."
else
  echo "Record versionCode in the history table of docs/publishing/store-release.md."
fi
