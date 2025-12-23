# Script to fix telephony package namespace issue
# This script adds the required namespace to the telephony package's build.gradle

$telephonyPath = "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\telephony-0.2.0\android\build.gradle"

if (Test-Path $telephonyPath) {
    $content = Get-Content $telephonyPath -Raw
    
    if ($content -notmatch "namespace\s*=") {
        $content = $content -replace "(android\s*\{)", "`$1`n    namespace = `"com.shounakmulay.telephony`""
        Set-Content -Path $telephonyPath -Value $content -NoNewline
        Write-Host "Fixed telephony package namespace" -ForegroundColor Green
    } else {
        Write-Host "Telephony package namespace already fixed" -ForegroundColor Yellow
    }
} else {
    Write-Host "Telephony package not found. Run 'flutter pub get' first." -ForegroundColor Red
}






