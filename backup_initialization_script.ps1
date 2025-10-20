<#
backup_initialization_script.ps1 — secure bootstrapper
- Logs into Azure if needed (optional: Managed Identity)
- Fetches a GitHub PAT from Azure Key Vault
- Downloads a script from GitHub (private or public)
- Saves, unblocks, runs it

Usage examples:
  powershell -ExecutionPolicy Bypass -File .\backup_initialization_script.ps1
  powershell -ExecutionPolicy Bypass -File .\backup_initialization_script.ps1 -DryRun
#>

param(
  [switch]$DryRun,

  # Where to save + run the downloaded script
  [string]$OutDir    = 'C:/db_scripts',
  [string]$FileName  = 'download_and_restore_tested.ps1',

  # GitHub raw URL to the target script (branch/ref allowed)
  [string]$SourceUrl = 'https://raw.githubusercontent.com/premasheesh/download_db_and_restore/test_branch/download_and_restore_tested.ps1',

  # Key Vault details 
  [string]$VaultName     = 'kv-github-access',
  [string]$PatSecretName = 'token-access-scripts',

  # Azure auth behavior
  [switch]$UseManagedIdentity   # set when running on an Azure VM/App Service with MI enabled
)

$ErrorActionPreference = 'Stop'
function Log([string]$m){ Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Fail([string]$m){ Write-Error $m; exit 1 }

# --- Pre-reqs ---
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Fail 'Azure CLI "az" not found on PATH.' }

# --- Ensure TLS 1.2 for GitHub ---
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- Azure login (az CLI) ---
try {
  az account show -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    if ($UseManagedIdentity) {
      Log 'No az session; attempting Managed Identity login...'
      az login --identity 1>$null
      if ($LASTEXITCODE -ne 0) { Fail 'Managed Identity login failed. Ensure MI is enabled and has Key Vault access.' }
    } else {
      Fail 'Not logged into Azure. Run "az login" (or use -UseManagedIdentity) and retry.'
    }
  }
} catch { Fail ("Azure CLI check failed: {0}" -f $_) }

# --- Fetch GitHub PAT from Key Vault (RBAC must allow Secrets Get) ---
Log ("Retrieving GitHub PAT from Key Vault '{0}' (secret '{1}')..." -f $VaultName, $PatSecretName)
$GitHubPAT = (az keyvault secret show --vault-name $VaultName --name $PatSecretName --query value -o tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($GitHubPAT)) {
  Fail ("Failed to read secret '{0}' from Key Vault '{1}' or it is empty." -f $PatSecretName, $VaultName)
}

# --- Build paths and ensure folder ---
$DestPath = Join-Path $OutDir $FileName
if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# --- Prepare headers for GitHub (PAT + UA) ---
$Headers = @{
  'Authorization' = "Bearer $GitHubPAT"  # works for raw and API
  'User-Agent'    = 'ps-bootstrapper'
}

# --- Download script ---
Log "Downloading script from: $SourceUrl"
$downloaded = $false
try {
  # preferred path for raw.githubusercontent.com links
  Invoke-WebRequest -Uri $SourceUrl -Headers $Headers -UseBasicParsing -OutFile $DestPath
  $downloaded = $true
  Log "Saved to: $DestPath"
} catch {
  # fallback for standard github.com/.../blob/... links via contents API
  if ($SourceUrl -match '^https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*)$') {
    $owner = $Matches[1]; $repo = $Matches[2]; $ref = $Matches[3]; $path = $Matches[4]
    $apiUrl = "https://api.github.com/repos/$owner/$repo/contents/$path`?ref=$ref"
    Log ("Raw download failed; retrying via GitHub API: {0}" -f $apiUrl)
    $apiHeaders = $Headers.Clone(); $apiHeaders['Accept'] = 'application/vnd.github.raw'
    Invoke-WebRequest -Uri $apiUrl -Headers $apiHeaders -UseBasicParsing -OutFile $DestPath
    $downloaded = $true
    Log "Saved to: $DestPath"
  } else {
    Fail "Download failed. Ensure the URL is raw.github content OR a standard GitHub blob URL, and that PAT has 'repo' scope."
  }
} finally {
  # minimize PAT lifetime in memory
  $GitHubPAT = $null
  [System.GC]::Collect()
}

# --- Unblock and run ---
try { Unblock-File -LiteralPath $DestPath; Log 'File unblocked successfully.' } catch { Log 'Could not unblock file (not critical).' }

$quotedPath = "`"$DestPath`""
$childArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $quotedPath)
if ($DryRun) { $childArgs += '-DryRun' }

Log 'Launching downloaded script...'
Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs -NoNewWindow -Wait
Log 'Execution complete.'
