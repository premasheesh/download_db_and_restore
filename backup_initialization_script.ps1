<#
init.ps1 — simple & safe bootstrapper
Downloads a PowerShell script from GitHub (raw), saves it locally, unblocks it, and runs it.

Usage:
  powershell -ExecutionPolicy Bypass -File .\init.ps1
  powershell -ExecutionPolicy Bypass -File .\init.ps1 -DryRun
#>

param(
  [switch]$DryRun,
  [string]$OutDir   = 'C:/db_scripts', #(Get-Location).Path,
  [string]$SourceUrl = 'https://raw.githubusercontent.com/premasheesh/download_db_and_restore/test_branch/download_and_restore_tested.ps1',
  [string]$FileName  = 'download_and_restore_tested.ps1'
)

$ErrorActionPreference = 'Stop'

function Log([string]$m) {
  Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m)
}

# --- Ensure TLS 1.2 (required by GitHub) ---
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

# --- Build paths ---
$DestPath = Join-Path $OutDir $FileName

# --- Make sure folder exists ---
if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# --- Download script from GitHub raw ---
Log "Downloading script from: $SourceUrl"
try {
  Invoke-WebRequest -Uri $SourceUrl -UseBasicParsing -OutFile $DestPath
  Log "Saved to: $DestPath"
} catch {
  Write-Host "!!!Failed to download script. Check URL or Internet connection." -ForegroundColor Red
  exit 1
}

# --- Unblock (in case Windows blocked it) ---
try {
  Unblock-File -LiteralPath $DestPath
  Log "File unblocked successfully."
} catch {
  Log "Could not unblock file (not critical)."
}

# --- Run downloaded script ---
$quotedPath = "`"$DestPath`""
$childArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $quotedPath)
if ($DryRun) { $childArgs += '-DryRun' }

Log "Launching downloaded script..."
Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs -NoNewWindow -Wait
Log "Execution complete."
