# Builds a release APK of either edition.
# PowerShell twin of release_build.sh - change the two together.
#
#   commercial   (default) the APK uploaded to Bazaar / Myket
#   organization           the APK handed to an organization directly -
#                          NEVER uploaded to a store
#
# See docs/architecture/editions.md for why there are two and why they share
# one applicationId.
#
# WHY THIS EXISTS - versionCode must never repeat.
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
# number whether the build runs here or on a runner, needs no state kept
# anywhere, and only ever grows. It does not restart at 1 for a new release
# branch the way a per-workflow counter does.
#
# The organization flavor adds ORGANIZATION_VERSION_CODE_BASE to that count in
# android/app/build.gradle.kts; this script does not add it, it CHECKS that the
# APK came out with it (see "manifest check" below).
#
# Usage:
#   .\scripts\release_build.ps1                          # commercial, verified
#   .\scripts\release_build.ps1 -Flavor organization     # organization, verified
#   .\scripts\release_build.ps1 -SkipVerify              # build only
#
# Record the versionCode this prints: commercial builds in
# docs/publishing/store-release.md, organization builds in
# docs/architecture/editions.md.

param(
    [ValidateSet('commercial', 'organization')]
    [string]$Flavor = 'commercial',
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

# MIRROR of android/app/build.gradle.kts - change the two together.
$ApplicationId = 'ir.hamrasan.app'
$OrganizationVersionCodeBase = 2000000000

# Windows PowerShell 5.1 turns every stderr line of a native command whose
# stderr is redirected into an ErrorRecord, and under ErrorActionPreference
# 'Stop' the first one aborts the script. `git describe` on an untagged HEAD
# ("fatal: No names found") and apksigner's JVM warnings both did exactly that,
# so every build from an untagged commit died on line one. Native tools whose
# stderr we redirect run through here with the preference relaxed; stderr is
# folded into the output as plain strings and the exit code is still checked
# by the caller through $LASTEXITCODE.
function Invoke-Native([scriptblock]$command) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $command 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $previous }
}

Write-Host "Edition: $Flavor" -ForegroundColor Green

# --- version name -----------------------------------------------------------
$tag = Invoke-Native { git -C $repo describe --tags --exact-match HEAD }
if ($LASTEXITCODE -eq 0 -and $tag) {
    $versionName = $tag -replace '^v', ''
    Write-Host "versionName from tag: $versionName" -ForegroundColor Green
} else {
    $pubspec = Get-Content (Join-Path $repo 'pubspec.yaml') -Raw
    if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
        throw "Could not read 'version:' out of pubspec.yaml"
    }
    $versionName = $Matches[1]
    Write-Host "HEAD carries no tag - versionName from pubspec: $versionName" -ForegroundColor Yellow
    Write-Host "  (tag the release commit with 'git tag v$versionName' before a release)" -ForegroundColor Yellow
}

# --- version code -----------------------------------------------------------
$buildNumber = [int64]((git -C $repo rev-list --count HEAD).Trim())
Write-Host "Build number from commit count: $buildNumber" -ForegroundColor Green
if ($Flavor -eq 'organization') {
    $expectedVersionCode = $OrganizationVersionCodeBase + $buildNumber
    $expectedVersionName = "$versionName-org"
} else {
    $expectedVersionCode = $buildNumber
    $expectedVersionName = $versionName
}
Write-Host "Expected versionCode: $expectedVersionCode"

# A dirty tree means the APK does not match any commit, so the versionCode
# above names something that is not what was built.
$dirty = git -C $repo status --porcelain
if ($dirty) {
    Write-Host "WARNING: working tree is dirty - this APK will not match commit $buildNumber" -ForegroundColor Yellow
}

# --- build ------------------------------------------------------------------
Write-Host ''
flutter build apk --release --flavor $Flavor --build-name=$versionName --build-number=$buildNumber
if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }

$apk = Join-Path $repo "build\app\outputs\flutter-apk\app-$Flavor-release.apk"
if (-not (Test-Path $apk)) { throw "APK not found at $apk" }

# --- Android SDK --------------------------------------------------------------
# ANDROID_HOME first - android/local.properties is gitignored and does not
# exist on a fresh clone or a runner.
$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
$localProps = Join-Path $repo 'android\local.properties'
if (-not $sdk -and (Test-Path $localProps)) {
    $sdk = (Select-String -Path $localProps -Pattern '^sdk\.dir=(.+)$').Matches.Groups[1].Value -replace '\\\\', '\' -replace '\\:', ':'
}

# The newest build-tools directory that carries $name.
function Find-BuildTool([string]$name) {
    if (-not $sdk -or -not (Test-Path (Join-Path $sdk 'build-tools'))) { return $null }
    # Sort by version, not by name: "9.0.0" sorts after "10.0.0" as a string.
    $dirs = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } } -Descending
    foreach ($dir in $dirs) {
        $path = Join-Path $dir.FullName $name
        if (Test-Path $path) { return $path }
    }
    return $null
}

# --- manifest check ---------------------------------------------------------
# The edition is decided by two numbers in the built manifest, so they are read
# back out of the APK rather than trusted from the command line: the package
# name (both editions MUST be ir.hamrasan.app, or a store stops recognising the
# install) and the versionCode band (an organization APK below the base is one
# a store would "update" into the commercial app).
if (-not $SkipVerify) {
    $aapt2 = Find-BuildTool 'aapt2.exe'
    if (-not $aapt2) { throw "aapt2 not found under '$sdk' - manifest UNVERIFIED" }
    $badging = Invoke-Native { & $aapt2 dump badging $apk }
    if ($LASTEXITCODE -ne 0) { throw 'aapt2 could not read the APK - manifest UNVERIFIED' }
    $packageLine = $badging | Where-Object { $_ -like 'package: *' } | Select-Object -First 1
    if ($packageLine -notmatch "package: name='([^']*)'") { throw "No package line in aapt2 output - manifest UNVERIFIED" }
    $packageName = $Matches[1]
    $versionCode = if ($packageLine -match " versionCode='([^']*)'") { $Matches[1] } else { '' }
    $apkVersionName = if ($packageLine -match " versionName='([^']*)'") { $Matches[1] } else { '' }

    if ($packageName -ne $ApplicationId) {
        throw "REFUSING THIS APK: package is '$packageName', expected '$ApplicationId'."
    }
    if ($versionCode -ne "$expectedVersionCode") {
        throw "REFUSING THIS APK: versionCode is '$versionCode', expected '$expectedVersionCode' for the $Flavor edition."
    }
    if ($apkVersionName -ne $expectedVersionName) {
        throw "REFUSING THIS APK: versionName is '$apkVersionName', expected '$expectedVersionName'."
    }
    Write-Host "Manifest OK - $packageName, versionCode $versionCode, versionName $apkVersionName." -ForegroundColor Green
}

# --- trust anchor check -----------------------------------------------------
# The DEVELOPMENT key-bank authority (tools/keybank/dev/) is trusted only by a
# build made with --dart-define=HAMRESAN_DEV_ANCHOR=true, which this script
# never passes. Checked anyway, in the compiled Dart - see release_build.sh.
$anchors = Get-Content -Raw (Join-Path $repo "lib\features\keybank\services\trust_anchors.dart")
$devMatch = [regex]::Match($anchors, "_development =\s*'([0-9a-f]{64})")
if (-not $devMatch.Success) { throw "cannot read the development authority from trust_anchors.dart - trust anchors UNVERIFIED" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
try {
    $entry = $zip.GetEntry("lib/arm64-v8a/libapp.so")
    if ($null -eq $entry) { throw "libapp.so not found in the APK - trust anchors UNVERIFIED" }
    $stream = $entry.Open()
    $buffer = New-Object System.IO.MemoryStream
    try { $stream.CopyTo($buffer) } finally { $stream.Dispose() }
    # Latin-1 maps every byte to one char, so an ASCII marker is found as is.
    $libapp = [System.Text.Encoding]::GetEncoding(28591).GetString($buffer.ToArray())
} finally { $zip.Dispose() }
if ($libapp.Contains($devMatch.Groups[1].Value)) {
    throw "REFUSING THIS APK: it trusts the DEVELOPMENT key-bank authority. Rebuild without HAMRESAN_DEV_ANCHOR."
}
Write-Host "Trust anchors OK - no development authority." -ForegroundColor Green

# --- signature check --------------------------------------------------------
# android/key.properties is gitignored, so a fresh clone signs the RELEASE
# build with the DEBUG key (see android/app/build.gradle.kts). That APK
# installs and runs fine, which is exactly why it can be uploaded by mistake.
if (-not $SkipVerify) {
    $apksigner = Find-BuildTool 'apksigner.bat'

    # apksigner is a JVM tool and complains in a way that looks like ordinary
    # output. Without this, a machine with no `java` on PATH made the check
    # print "JAVA_HOME is not set", find no "Android Debug" in that text, and
    # report the signature OK - a false pass on the one thing this guard exists
    # to catch. Android Studio's bundled JBR is what Flutter itself builds with.
    if (-not $env:JAVA_HOME -and -not (Get-Command java -ErrorAction SilentlyContinue)) {
        foreach ($candidate in @("$env:ProgramFiles\Android\Android Studio\jbr",
                                 "$env:LOCALAPPDATA\Programs\Android Studio\jbr")) {
            if (Test-Path (Join-Path $candidate 'bin\java.exe')) { $env:JAVA_HOME = $candidate; break }
        }
    }

    if (-not $apksigner) {
        Write-Host "apksigner not found under '$sdk' - skipping signature check" -ForegroundColor Yellow
    } else {
        $certs = (Invoke-Native { & $apksigner verify --print-certs $apk }) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $certs -notmatch 'certificate DN:') {
            # Ran but printed no certificate - treat as unverified, never OK.
            Write-Host $certs -ForegroundColor Red
            throw 'Signature UNVERIFIED: apksigner did not print a certificate. Do not distribute this APK.'
        }
        Write-Host $certs
        if ($certs -match 'Android Debug') {
            throw 'REFUSING THIS APK: it is signed with the DEBUG key. Restore android/key.properties and android/upload-keystore.jks, then rebuild.'
        }
        Write-Host 'Signature OK - not the debug key.' -ForegroundColor Green
    }
}

# --- summary ----------------------------------------------------------------
$size = [math]::Round((Get-Item $apk).Length / 1MB, 1)
Write-Host ''
Write-Host "Edition      $Flavor"
Write-Host "APK          $apk  ($size MB)"
Write-Host "versionName  $expectedVersionName"
Write-Host "versionCode  $expectedVersionCode"
Write-Host ''
if ($Flavor -eq 'organization') {
    Write-Host 'ORGANIZATION APK - direct distribution only. NEVER upload it to a store.' -ForegroundColor Yellow
    Write-Host 'Record it in the organization history table of docs/architecture/editions.md.'
} else {
    Write-Host 'Record versionCode in the history table of docs/publishing/store-release.md.'
}
