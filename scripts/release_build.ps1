# Builds the release APK that gets uploaded to Bazaar / Myket.
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
# number whether the build runs here or on a runner, needs no state kept
# anywhere, and only ever grows. It does not restart at 1 for a new release
# branch the way a per-workflow counter does.
#
# Usage:
#   .\scripts\release_build.ps1                 # build + verify signature
#   .\scripts\release_build.ps1 -SkipVerify     # build only
#
# Record the versionCode this prints in docs/publishing/store-release.md.

param(
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

# --- version name -----------------------------------------------------------
$tag = git -C $repo describe --tags --exact-match HEAD 2>$null
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
    Write-Host "  (tag the release commit with 'git tag v$versionName' before a store upload)" -ForegroundColor Yellow
}

# --- version code -----------------------------------------------------------
$versionCode = (git -C $repo rev-list --count HEAD).Trim()
Write-Host "versionCode from commit count: $versionCode" -ForegroundColor Green

# A dirty tree means the APK does not match any commit, so the versionCode
# above names something that is not what was built.
$dirty = git -C $repo status --porcelain
if ($dirty) {
    Write-Host "WARNING: working tree is dirty - this APK will not match commit $versionCode" -ForegroundColor Yellow
}

# --- build ------------------------------------------------------------------
Write-Host ''
flutter build apk --release --build-name=$versionName --build-number=$versionCode
if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }

$apk = Join-Path $repo 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) { throw "APK not found at $apk" }

# --- signature check --------------------------------------------------------
# android/key.properties is gitignored, so a fresh clone signs the RELEASE
# build with the DEBUG key (see android/app/build.gradle.kts). That APK
# installs and runs fine, which is exactly why it can be uploaded by mistake.
if (-not $SkipVerify) {
    # ANDROID_HOME first — android/local.properties is gitignored and does not
    # exist on a fresh clone or a runner.
    $sdk = $env:ANDROID_HOME
    if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
    $localProps = Join-Path $repo 'android\local.properties'
    if (-not $sdk -and (Test-Path $localProps)) {
        $sdk = (Select-String -Path $localProps -Pattern '^sdk\.dir=(.+)$').Matches.Groups[1].Value -replace '\\\\', '\'
    }

    $apksigner = $null
    if ($sdk -and (Test-Path (Join-Path $sdk 'build-tools'))) {
        # Sort by version, not by name: "9.0.0" sorts after "10.0.0" as a string.
        $buildTools = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } } -Descending |
            Select-Object -First 1
        if ($buildTools) { $apksigner = Join-Path $buildTools.FullName 'apksigner.bat' }
    }

    # apksigner is a JVM tool and complains in a way that looks like ordinary
    # output. Without this, a machine with no `java` on PATH made the check
    # print "JAVA_HOME is not set", find no "Android Debug" in that text, and
    # report the signature OK — a false pass on the one thing this guard exists
    # to catch. Android Studio's bundled JBR is what Flutter itself builds with.
    if (-not $env:JAVA_HOME -and -not (Get-Command java -ErrorAction SilentlyContinue)) {
        foreach ($candidate in @("$env:ProgramFiles\Android\Android Studio\jbr",
                                 "$env:LOCALAPPDATA\Programs\Android Studio\jbr")) {
            if (Test-Path (Join-Path $candidate 'bin\java.exe')) { $env:JAVA_HOME = $candidate; break }
        }
    }

    if (-not $apksigner -or -not (Test-Path $apksigner)) {
        Write-Host "apksigner not found under '$sdk' - skipping signature check" -ForegroundColor Yellow
    } else {
        $certs = (& $apksigner verify --print-certs $apk 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $certs -notmatch 'certificate DN:') {
            # Ran but printed no certificate - treat as unverified, never OK.
            Write-Host $certs -ForegroundColor Red
            throw 'Signature UNVERIFIED: apksigner did not print a certificate. Do not upload this APK.'
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
Write-Host "APK          $apk  ($size MB)"
Write-Host "versionName  $versionName"
Write-Host "versionCode  $versionCode"
Write-Host ''
Write-Host 'Record versionCode in the history table of docs/publishing/store-release.md.'
