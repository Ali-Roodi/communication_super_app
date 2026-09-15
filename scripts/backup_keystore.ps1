# Makes — and verifies — an encrypted offline backup of the release signing key.
#
# WHY THIS EXISTS — the key IS the app.
#
# Bazaar and Myket have no equivalent of Play App Signing. `android/
# upload-keystore.jks` plus the three secrets in `android/key.properties` are
# the identity of `ir.hamrasan.app` for ever: lose them and no update can ever
# be published for that package name again. Both files are gitignored (they
# must be), so nothing outside this laptop holds them unless somebody puts a
# copy there on purpose. This script is that purpose.
#
# What it produces (in -OutDir, default `keystore-backup/` at the repo root,
# gitignored):
#   hamrasan-keystore-backup-<yyyyMMdd>.tar.enc   AES-256-CBC, PBKDF2 600k
#   hamrasan-keystore-backup-<yyyyMMdd>.sha256    checksum of the .enc file
# The archive holds the .jks, key.properties, a base64 copy of the .jks (what a
# CI secret wants), RESTORE.md, and SHA256SUMS. Nothing is written in plain
# text outside the archive.
#
# Two things make this a backup rather than a copy:
#   * before packing, the keystore is OPENED with the passwords from
#     key.properties (keytool -list) — a backup whose recorded password is
#     wrong is worth nothing, and this is the only moment that is cheap to
#     find out;
#   * after packing, the archive is decrypted again into a temp dir, the .jks
#     is compared byte for byte, and keytool is run on *that* copy. The
#     fingerprint printed at the end comes from the restored copy, not the
#     original.
#
# Usage:
#   $env:HAMRASAN_BACKUP_PASSPHRASE = '...'      # or be prompted
#   .\scripts\backup_keystore.ps1                  # backup
#   .\scripts\backup_keystore.ps1 -OutDir D:\usb   # backup straight to a USB stick
#   .\scripts\backup_keystore.ps1 -Restore <file.tar.enc>          # restore into android/
#   .\scripts\backup_keystore.ps1 -Restore <file.tar.enc> -Force   # overwrite existing
#
# The passphrase is NOT in this repo, not in the archive, and not recoverable.
# Keep it in a password manager, separately from the archive.

[CmdletBinding(DefaultParameterSetName = 'Backup')]
param(
    [Parameter(ParameterSetName = 'Backup')]
    [string]$OutDir,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [string]$Restore,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $repo 'android'
$jksPath = Join-Path $androidDir 'upload-keystore.jks'
$propsPath = Join-Path $androidDir 'key.properties'

# --- tools ------------------------------------------------------------------
# openssl and tar ship with Git for Windows; keytool with any JDK, and the JBR
# bundled with Android Studio is the one this machine is guaranteed to have.
function Find-Tool([string]$name, [string[]]$extraDirs) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($d in $extraDirs) {
        $p = Join-Path $d "$name.exe"
        if (Test-Path $p) { return $p }
    }
    throw "'$name' not found. Install Git for Windows (openssl, tar) and Android Studio (keytool)."
}
$gitDirs = @("$env:ProgramFiles\Git\usr\bin", "$env:ProgramFiles\Git\mingw64\bin")
$javaDirs = @()
if ($env:JAVA_HOME) { $javaDirs += (Join-Path $env:JAVA_HOME 'bin') }
$javaDirs += @("$env:ProgramFiles\Android\Android Studio\jbr\bin",
               "$env:LOCALAPPDATA\Programs\Android Studio\jbr\bin")
$openssl = Find-Tool 'openssl' $gitDirs
$tar     = Find-Tool 'tar'     ($gitDirs + @("$env:SystemRoot\System32"))
$keytool = Find-Tool 'keytool' $javaDirs

function Get-Passphrase {
    if ($env:HAMRASAN_BACKUP_PASSPHRASE) { return $env:HAMRASAN_BACKUP_PASSPHRASE }
    $secure = Read-Host -AsSecureString 'Archive passphrase'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# openssl reads the passphrase from an env var so it never lands on a command
# line (visible in the process table) or in this shell's history.
function Invoke-OpenSslEnc([string]$mode, [string]$in, [string]$out, [string]$pass) {
    $env:HKS_PASS = $pass
    try {
        & $openssl enc $mode -aes-256-cbc -pbkdf2 -iter 600000 -salt -in $in -out $out -pass env:HKS_PASS
        if ($LASTEXITCODE -ne 0) { throw "openssl $mode failed (wrong passphrase?)" }
    } finally { Remove-Item Env:\HKS_PASS -ErrorAction SilentlyContinue }
}

function Read-KeyProperties([string]$path) {
    $h = @{}
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*([A-Za-z]+)\s*=\s*(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() }
    }
    foreach ($k in 'storePassword', 'keyPassword', 'keyAlias') {
        if (-not $h[$k]) { throw "key.properties has no '$k'" }
    }
    return $h
}

# Opens the keystore with the recorded passwords and returns the SHA-256
# certificate fingerprint. Throws if the passwords are wrong — the whole point.
function Get-Fingerprint([string]$jks, [hashtable]$props) {
    # keytool warns on stderr about the JKS format, and under
    # $ErrorActionPreference = 'Stop' PowerShell 5.1 turns a native command's
    # stderr line into a terminating error. Read it as text instead.
    $env:HKS_STOREPASS = $props.storePassword
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = (& $keytool -list -v -keystore $jks -alias $props.keyAlias -storepass:env HKS_STOREPASS 2>&1 |
                ForEach-Object { "$_" }) -join "`n"
    } finally {
        $ErrorActionPreference = $eap
        Remove-Item Env:\HKS_STOREPASS -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0 -or $out -notmatch 'SHA256:\s*([0-9A-F:]+)') {
        throw "keytool could not open '$jks' with the password in key.properties:`n$out"
    }
    return $Matches[1]
}

function Get-Sha256([string]$path) {
    return (Get-FileHash -Algorithm SHA256 $path).Hash.ToLower()
}

# =============================================================================
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    if (-not (Test-Path $Restore)) { throw "No such archive: $Restore" }
    if ((Test-Path $jksPath) -and -not $Force) {
        throw "$jksPath already exists. Pass -Force to overwrite it."
    }
    $pass = Get-Passphrase
    $work = Join-Path ([IO.Path]::GetTempPath()) ("hks-restore-" + [Guid]::NewGuid())
    New-Item -ItemType Directory $work | Out-Null
    try {
        $tarPath = Join-Path $work 'bundle.tar'
        Invoke-OpenSslEnc '-d' $Restore $tarPath $pass
        & $tar -xf $tarPath -C $work
        if ($LASTEXITCODE -ne 0) { throw 'tar extract failed' }

        $props = Read-KeyProperties (Join-Path $work 'key.properties')
        $fp = Get-Fingerprint (Join-Path $work 'upload-keystore.jks') $props
        $expected = (Get-Content (Join-Path $work 'RESTORE.md') -Raw)
        if ($expected -notmatch [regex]::Escape($fp)) {
            throw "Fingerprint of restored keystore ($fp) is not the one recorded in RESTORE.md. Stop."
        }

        New-Item -ItemType Directory -Force $androidDir | Out-Null
        Copy-Item (Join-Path $work 'upload-keystore.jks') $jksPath -Force
        Copy-Item (Join-Path $work 'key.properties') $propsPath -Force
        Write-Host "Restored to $androidDir" -ForegroundColor Green
        Write-Host "SHA-256 fingerprint: $fp" -ForegroundColor Green
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
    exit 0
}

# =============================================================================
# Backup
foreach ($p in $jksPath, $propsPath) {
    if (-not (Test-Path $p)) { throw "Missing $p - nothing to back up." }
}
$props = Read-KeyProperties $propsPath

Write-Host 'Opening the keystore with the passwords in key.properties...'
$fingerprint = Get-Fingerprint $jksPath $props
Write-Host "  OK - SHA-256: $fingerprint" -ForegroundColor Green

if (-not $OutDir) { $OutDir = Join-Path $repo 'keystore-backup' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd'
$base = "hamrasan-keystore-backup-$stamp"
$encPath = Join-Path $OutDir "$base.tar.enc"
$sumPath = Join-Path $OutDir "$base.sha256"
if (Test-Path $encPath) { throw "$encPath already exists - refusing to overwrite a backup." }

$pass = Get-Passphrase
if ($pass.Length -lt 16) { throw 'Passphrase must be at least 16 characters.' }

$work = Join-Path ([IO.Path]::GetTempPath()) ("hks-backup-" + [Guid]::NewGuid())
$stage = Join-Path $work 'stage'
New-Item -ItemType Directory $stage | Out-Null
try {
    # --- stage ------------------------------------------------------------
    Copy-Item $jksPath   (Join-Path $stage 'upload-keystore.jks')
    Copy-Item $propsPath (Join-Path $stage 'key.properties')
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($jksPath))
    [IO.File]::WriteAllText((Join-Path $stage 'upload-keystore.jks.base64'), $b64)

    $jksSha = Get-Sha256 $jksPath
    $readme = @"
# Hamrasan release signing key — offline backup

Made:        $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME
Package:     ir.hamrasan.app
Key alias:   $($props.keyAlias)
Cert SHA-256 fingerprint: $fingerprint
upload-keystore.jks SHA-256: $jksSha

## Files
- upload-keystore.jks         the keystore. Goes to android/upload-keystore.jks
- key.properties              storeFile / storePassword / keyAlias / keyPassword.
                              Goes to android/key.properties
- upload-keystore.jks.base64  the same keystore, base64 — paste into a CI secret
                              (KEYSTORE_BASE64) and decode it on the runner
- SHA256SUMS                  checksums of the above

## Restore
    .\scripts\backup_keystore.ps1 -Restore <this archive>       (Windows)
    scripts/backup_keystore.sh --restore <this archive>         (Linux/macOS)
Both re-open the keystore and refuse to install it unless its fingerprint is
the one above. Then `scripts/release_build.ps1` verifies the APK signature
against the same certificate.

## By hand (no script)
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <archive> -out bundle.tar
    tar -xf bundle.tar
    keytool -list -v -keystore upload-keystore.jks -alias $($props.keyAlias)
The SHA256 line keytool prints must equal the fingerprint above.

## If this is ever lost
There is no recovery. A new key means a new package name, which means every
existing install is orphaned. See docs/publishing/store-release.md.
"@
    [IO.File]::WriteAllText((Join-Path $stage 'RESTORE.md'), $readme, [Text.UTF8Encoding]::new($false))

    $sums = foreach ($f in 'upload-keystore.jks', 'key.properties', 'upload-keystore.jks.base64', 'RESTORE.md') {
        "$(Get-Sha256 (Join-Path $stage $f))  $f"
    }
    [IO.File]::WriteAllText((Join-Path $stage 'SHA256SUMS'), ($sums -join "`n") + "`n")

    # --- pack + encrypt ---------------------------------------------------
    $tarPath = Join-Path $work 'bundle.tar'
    & $tar -cf $tarPath -C $stage .
    if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
    Invoke-OpenSslEnc '-e' $tarPath $encPath $pass
    "$(Get-Sha256 $encPath)  $base.tar.enc`n" | Set-Content -NoNewline -Encoding ascii $sumPath

    # --- verify by restoring ----------------------------------------------
    # Not "did openssl exit 0" — did the bytes that come back open as the
    # same key. This is the check that turns a copy into a backup.
    Write-Host 'Verifying: decrypting the archive and re-opening the restored keystore...'
    $check = Join-Path $work 'check'
    New-Item -ItemType Directory $check | Out-Null
    $tar2 = Join-Path $check 'bundle.tar'
    Invoke-OpenSslEnc '-d' $encPath $tar2 $pass
    & $tar -xf $tar2 -C $check
    if ($LASTEXITCODE -ne 0) { throw 'verification: tar extract failed' }
    $restoredJks = Join-Path $check 'upload-keystore.jks'
    if ((Get-Sha256 $restoredJks) -ne $jksSha) { throw 'verification: restored .jks differs from the original' }
    $restoredFp = Get-Fingerprint $restoredJks (Read-KeyProperties (Join-Path $check 'key.properties'))
    if ($restoredFp -ne $fingerprint) { throw 'verification: restored keystore has a different fingerprint' }
    $restoredB64 = Get-Content (Join-Path $check 'upload-keystore.jks.base64') -Raw
    if ($restoredB64.Trim() -ne $b64) { throw 'verification: base64 copy does not match' }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Backup written and verified:" -ForegroundColor Green
Write-Host "  $encPath  ($([math]::Round((Get-Item $encPath).Length / 1KB, 1)) KB)"
Write-Host "  $sumPath"
Write-Host "  cert SHA-256: $fingerprint"
Write-Host ''
Write-Host 'Now copy the .tar.enc somewhere that is NOT this machine, and keep the' -ForegroundColor Yellow
Write-Host 'passphrase somewhere that is NOT next to the archive.' -ForegroundColor Yellow
