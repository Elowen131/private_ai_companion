<#
 Route C - text-to-3D local environment one-click launcher.
 Put this file at the PROJECT ROOT (same level as the tools/ folder), then
 double-click it, or right-click -> "Run with PowerShell".
 It locates tools/text_to_3d/setup.ps1 automatically and does NOT depend on
 your current command-line directory. The window pauses at the end.
#>
$ErrorActionPreference = "Stop"
$Root  = $PSScriptRoot
$Setup = Join-Path $Root "tools/text_to_3d/setup.ps1"

if (-not (Test-Path $Setup)) {
    Write-Host "Cannot find: $Setup" -ForegroundColor Red
    Write-Host "Make sure this launcher sits at the project root (same level as tools/)." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

# Forward any extra args (e.g. -DownloadWeights) to setup.ps1
& powershell -ExecutionPolicy Bypass -File $Setup @args
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
    Write-Host "Environment setup finished." -ForegroundColor Green
} else {
    Write-Host "Setup failed (exit code $code)." -ForegroundColor Red
}
Read-Host "Press Enter to close"
