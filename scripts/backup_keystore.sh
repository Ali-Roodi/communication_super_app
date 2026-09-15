#!/usr/bin/env bash
# Encrypted, verified offline backup of the release signing key — the POSIX
# twin of backup_keystore.ps1. Read the header of that file for why this
# exists; the short version is that android/upload-keystore.jks plus
# android/key.properties are the identity of ir.hamrasan.app for ever, both
# are gitignored, and losing them orphans every install.
#
# Usage:
#   HAMRASAN_BACKUP_PASSPHRASE=... scripts/backup_keystore.sh [out-dir]
#   scripts/backup_keystore.sh --restore <file.tar.enc> [--force]
#
# Needs openssl, tar, keytool (any JDK; Android Studio's JBR is tried).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_dir="$repo/android"
jks="$android_dir/upload-keystore.jks"
props="$android_dir/key.properties"

find_keytool() {
  if command -v keytool >/dev/null 2>&1; then command -v keytool; return; fi
  for d in "${JAVA_HOME:-}/bin" \
           "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin" \
           "$HOME/.local/share/JetBrains/Toolbox/apps/android-studio/jbr/bin" \
           "/opt/android-studio/jbr/bin" \
           "/c/Program Files/Android/Android Studio/jbr/bin"; do
    [ -x "$d/keytool" ] && { echo "$d/keytool"; return; }
    [ -x "$d/keytool.exe" ] && { echo "$d/keytool.exe"; return; }
  done
  echo "keytool not found (install a JDK or Android Studio)" >&2; exit 1
}
keytool="$(find_keytool)"
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

passphrase() {
  if [ -n "${HAMRASAN_BACKUP_PASSPHRASE:-}" ]; then printf '%s' "$HAMRASAN_BACKUP_PASSPHRASE"; return; fi
  read -r -s -p 'Archive passphrase: ' p; echo >&2; printf '%s' "$p"
}

# The passphrase goes to openssl through the environment, never argv.
enc() { # mode in out
  HKS_PASS="$pass" openssl enc "$1" -aes-256-cbc -pbkdf2 -iter 600000 -salt -in "$2" -out "$3" -pass env:HKS_PASS
}

prop() { # file key
  local v; v="$(grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$v" ] || { echo "key.properties has no '$2'" >&2; exit 1; }
  printf '%s' "$v"
}

# Opens the keystore with the recorded password; prints the cert SHA-256.
fingerprint() { # jks props
  local alias storepass out
  alias="$(prop "$2" keyAlias)"; storepass="$(prop "$2" storePassword)"
  out="$(HKS_STOREPASS="$storepass" "$keytool" -list -v -keystore "$1" -alias "$alias" -storepass:env HKS_STOREPASS 2>&1)" \
    || { echo "keytool could not open $1 with the password in key.properties:" >&2; echo "$out" >&2; exit 1; }
  echo "$out" | grep -oE 'SHA256:[[:space:]]*[0-9A-F:]+' | head -1 | sed 's/SHA256:[[:space:]]*//'
}

sha256() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
if [ "${1:-}" = "--restore" ]; then
  archive="${2:?usage: --restore <file.tar.enc> [--force]}"
  [ -f "$archive" ] || { echo "No such archive: $archive" >&2; exit 1; }
  if [ -e "$jks" ] && [ "${3:-}" != "--force" ]; then
    echo "$jks already exists. Pass --force to overwrite." >&2; exit 1
  fi
  pass="$(passphrase)"
  enc -d "$archive" "$work/bundle.tar"
  tar -xf "$work/bundle.tar" -C "$work"
  fp="$(fingerprint "$work/upload-keystore.jks" "$work/key.properties")"
  grep -qF "$fp" "$work/RESTORE.md" || { echo "Restored fingerprint $fp is not the one in RESTORE.md. Stop." >&2; exit 1; }
  mkdir -p "$android_dir"
  cp "$work/upload-keystore.jks" "$jks"
  cp "$work/key.properties" "$props"
  echo "Restored to $android_dir"
  echo "SHA-256 fingerprint: $fp"
  exit 0
fi

# ---------------------------------------------------------------------------
[ -f "$jks" ] && [ -f "$props" ] || { echo "Missing $jks or $props - nothing to back up." >&2; exit 1; }
echo 'Opening the keystore with the passwords in key.properties...'
fp="$(fingerprint "$jks" "$props")"
echo "  OK - SHA-256: $fp"

out_dir="${1:-$repo/keystore-backup}"
mkdir -p "$out_dir"
base="hamrasan-keystore-backup-$(date +%Y%m%d)"
enc_path="$out_dir/$base.tar.enc"
[ -e "$enc_path" ] && { echo "$enc_path already exists - refusing to overwrite a backup." >&2; exit 1; }

pass="$(passphrase)"
[ "${#pass}" -ge 16 ] || { echo 'Passphrase must be at least 16 characters.' >&2; exit 1; }

stage="$work/stage"; mkdir -p "$stage"
cp "$jks" "$stage/upload-keystore.jks"
cp "$props" "$stage/key.properties"
openssl base64 -A -in "$jks" -out "$stage/upload-keystore.jks.base64"
jks_sha="$(sha256 "$jks")"
alias="$(prop "$props" keyAlias)"
cat > "$stage/RESTORE.md" <<EOF
# Hamrasan release signing key — offline backup

Made:        $(date '+%Y-%m-%d %H:%M') on $(hostname)
Package:     ir.hamrasan.app
Key alias:   $alias
Cert SHA-256 fingerprint: $fp
upload-keystore.jks SHA-256: $jks_sha

## Files
- upload-keystore.jks         the keystore. Goes to android/upload-keystore.jks
- key.properties              storeFile / storePassword / keyAlias / keyPassword.
                              Goes to android/key.properties
- upload-keystore.jks.base64  the same keystore, base64 — paste into a CI secret
                              (KEYSTORE_BASE64) and decode it on the runner
- SHA256SUMS                  checksums of the above

## Restore
    .\\scripts\\backup_keystore.ps1 -Restore <this archive>       (Windows)
    scripts/backup_keystore.sh --restore <this archive>         (Linux/macOS)
Both re-open the keystore and refuse to install it unless its fingerprint is
the one above. Then scripts/release_build.* verifies the APK signature
against the same certificate.

## By hand (no script)
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <archive> -out bundle.tar
    tar -xf bundle.tar
    keytool -list -v -keystore upload-keystore.jks -alias $alias
The SHA256 line keytool prints must equal the fingerprint above.

## If this is ever lost
There is no recovery. A new key means a new package name, which means every
existing install is orphaned. See docs/publishing/store-release.md.
EOF
( cd "$stage" && for f in upload-keystore.jks key.properties upload-keystore.jks.base64 RESTORE.md; do
    echo "$(sha256 "$f")  $f"; done > SHA256SUMS )

tar -cf "$work/bundle.tar" -C "$stage" .
enc -e "$work/bundle.tar" "$enc_path"
echo "$(sha256 "$enc_path")  $base.tar.enc" > "$out_dir/$base.sha256"

# Verify by restoring — the check that turns a copy into a backup.
echo 'Verifying: decrypting the archive and re-opening the restored keystore...'
check="$work/check"; mkdir -p "$check"
enc -d "$enc_path" "$check/bundle.tar"
tar -xf "$check/bundle.tar" -C "$check"
[ "$(sha256 "$check/upload-keystore.jks")" = "$jks_sha" ] || { echo 'verification: restored .jks differs' >&2; exit 1; }
[ "$(fingerprint "$check/upload-keystore.jks" "$check/key.properties")" = "$fp" ] || { echo 'verification: fingerprint differs' >&2; exit 1; }
cmp -s "$check/upload-keystore.jks.base64" "$stage/upload-keystore.jks.base64" || { echo 'verification: base64 copy differs' >&2; exit 1; }

echo
echo "Backup written and verified:"
echo "  $enc_path"
echo "  $out_dir/$base.sha256"
echo "  cert SHA-256: $fp"
echo
echo 'Now copy the .tar.enc somewhere that is NOT this machine, and keep the'
echo 'passphrase somewhere that is NOT next to the archive.'
