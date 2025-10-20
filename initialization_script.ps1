<#
initialization_script.ps1 — Complete bootstrap automation with logging
1. Installs AWS & Azure CLI (admin check)
2. Logs into Azure (Service Principal, Managed Identity, or Interactive)
3. Reads AWS credentials from Azure Key Vault and configures AWS CLI
4. Fetches GitHub PAT from Azure Key Vault, downloads the target GitHub script, and executes it
5. Writes everything into a single log file under OutDir
#>

# ==================== CONFIG ====================
$Config = [ordered]@{
  # === Service Principal Credentials ===
  AuthMode            = "ServicePrincipal"
  TenantId            = "16e34764-f598-4c2c-88c4-2e19fa02fbb6" # Directory (tenant) ID
  ClientId            = "5f515515-3860-4919-b692-0cfc9f1379e2" # Application (client) ID
  ClientSecret        = "Ma98Q~G7tY9bjCAPhiPa0_urAndd~fQU3~n0Ka0K"
  SubscriptionId      = "" #optional
  DefaultResourceGroup= "" #optional
  DefaultLocation     = "" #optional
  UseDeviceCode       = $false

  # === Key Vault (AWS) ===
  VaultName           = "kv-s3-bucket"
  AccessKeyName       = "aws-access-key-id"
  SecretKeyName       = "aws-secret-access-key"
  SessionTokName      = ""
  ProfileName         = ""
  Region              = "ca-central-1"

  # === Key Vault (GitHub) ===
  GitHubVaultName     = "kv-github-access"
  PatSecretName       = "token-access-scripts"

  # === GitHub script ===
  SourceUrl           = "https://raw.githubusercontent.com/premasheesh/download_db_and_restore/test_branch/download_and_restore_tested.ps1"
  OutDir              = "C:/db_scripts"
  FileName            = "download_and_restore_tested.ps1"
  UseManagedIdentity  = $false
}

# =================== FUNCTIONS =====================
$ErrorActionPreference = "Stop"
function Log([string]$m){ Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Fail([string]$m){ Write-Error $m; if ($global:_TranscriptStarted) { Stop-Transcript | Out-Null }; exit 1 }

# ------------------- START LOGGING -------------------
if (-not (Test-Path $Config.OutDir)) { New-Item -ItemType Directory -Path $Config.OutDir -Force | Out-Null }
$LogFile = Join-Path $Config.OutDir ("bootstrap_run_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null
$global:_TranscriptStarted = $true
Log "=== Logging started: $LogFile ==="

# ------------------- ADMIN CHECK -------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail "This script requires administrative privileges. Please run as Administrator." }

# ------------------- INSTALL CLIS -------------------
function Test-CommandExists($Command) { return [bool](Get-Command $Command -ErrorAction SilentlyContinue) }
function Install-MSI($MsiUrl, $MsiPath) {
    Log "Downloading $MsiUrl..."
    Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing
    Log "Installing $MsiPath..."
    $ProcessArgs = "/i `"$MsiPath`" /quiet /norestart"
    Start-Process -FilePath "msiexec.exe" -ArgumentList $ProcessArgs -Wait -NoNewWindow
    Log "Installed: $MsiPath"
}
function Install-CLIs {
    Log "Checking CLI prerequisites..."
    $TempDir = "C:\Temp"
    if (-not (Test-Path $TempDir)) { New-Item -Path $TempDir -ItemType Directory -Force | Out-Null }

    $AwsMsiUrl = "https://awscli.amazonaws.com/AWSCLIV2.msi"
    $AzureMsiUrl64 = "https://aka.ms/installazurecliwindowsx64"
    $AzureMsiUrl32 = "https://aka.ms/installazurecliwindows"
    $AzureMsiUrl = if ([Environment]::Is64BitOperatingSystem) { $AzureMsiUrl64 } else { $AzureMsiUrl32 }
    $AwsMsiPath = Join-Path $TempDir "AWSCLIV2.msi"
    $AzureMsiPath = Join-Path $TempDir "AzureCLI.msi"

    if (-not (Test-CommandExists "aws")) { Install-MSI $AwsMsiUrl $AwsMsiPath }
    else { Log "AWS CLI already installed." }

    if (-not (Test-CommandExists "az")) { Install-MSI $AzureMsiUrl $AzureMsiPath }
    else { Log "Azure CLI already installed." }

    Log "Verifying installations..."
    aws --version | Out-Host
    az version | Out-Host
}
Install-CLIs

# ------------------- AZURE LOGIN -------------------
function Ensure-AzLogin {
  param($AuthMode, $TenantId, $ClientId, $ClientSecret)
  try {
    az account show -o none 2>$null
    if ($LASTEXITCODE -eq 0) { Log "Azure CLI already logged in."; return }
  } catch {}
  switch ($AuthMode) {
    "ServicePrincipal" {
      Log "Logging into Azure with Service Principal..."
      $ClientSecret = ($ClientSecret -replace "[\r\n]+","").Trim()
      az login --service-principal --tenant $TenantId --username $ClientId --password "$ClientSecret" 1>$null
      if ($LASTEXITCODE -ne 0) { Fail "Service Principal login failed." }
    }
    "ManagedIdentity" {
      Log "Logging into Azure with Managed Identity..."
      az login --identity | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail "Managed Identity login failed." }
    }
    default {
      Log "Interactive login..."
      az login
      if ($LASTEXITCODE -ne 0) { Fail "Interactive login failed." }
    }
  }
  Log "Azure login successful."
}
Ensure-AzLogin -AuthMode $Config.AuthMode -TenantId $Config.TenantId -ClientId $Config.ClientId -ClientSecret $Config.ClientSecret

# ------------------- CONFIGURE AWS CLI -------------------
Log ("Reading AWS credentials from Key Vault '{0}'..." -f $Config.VaultName)
$AWS_ACCESS_KEY_ID = (az keyvault secret show --vault-name $Config.VaultName --name $Config.AccessKeyName --query value -o tsv).Trim()
$AWS_SECRET_ACCESS_KEY = (az keyvault secret show --vault-name $Config.VaultName --name $Config.SecretKeyName --query value -o tsv).Trim()
if ([string]::IsNullOrWhiteSpace($AWS_ACCESS_KEY_ID) -or [string]::IsNullOrWhiteSpace($AWS_SECRET_ACCESS_KEY)) {
  Fail "Failed to read AWS credentials from Key Vault."
}
$Profile = if ([string]::IsNullOrWhiteSpace($Config.ProfileName)) { "default" } else { $Config.ProfileName }
Log ("Configuring AWS CLI profile '{0}'..." -f $Profile)
aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$Profile"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$Profile"
aws configure set region "$($Config.Region)" --profile "$Profile"
aws configure set output json --profile "$Profile"
Log "Testing AWS credentials..."
aws sts get-caller-identity --profile "$Profile" | Out-Host
Log "AWS configuration complete."

# ------------------- DOWNLOAD GITHUB SCRIPT -------------------
Log ("Retrieving GitHub PAT from Key Vault '{0}' (secret '{1}')..." -f $Config.GitHubVaultName, $Config.PatSecretName)
$GitHubPAT = (az keyvault secret show --vault-name $Config.GitHubVaultName --name $Config.PatSecretName --query value -o tsv).Trim()
if ([string]::IsNullOrWhiteSpace($GitHubPAT)) { Fail "GitHub PAT not found or empty." }

$Headers = @{ 'Authorization' = "Bearer $GitHubPAT"; 'User-Agent' = 'ps-bootstrapper' }
$DestPath = Join-Path $Config.OutDir $Config.FileName
if (-not (Test-Path $Config.OutDir)) { New-Item -ItemType Directory -Path $Config.OutDir -Force | Out-Null }

Log ("Downloading script from: {0}" -f $Config.SourceUrl)
try {
  Invoke-WebRequest -Uri $Config.SourceUrl -Headers $Headers -UseBasicParsing -OutFile $DestPath
  Log ("Saved to: {0}" -f $DestPath)
} catch {
  if ($Config.SourceUrl -match '^https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*)$') {
    $owner = $Matches[1]; $repo = $Matches[2]; $ref = $Matches[3]; $path = $Matches[4]
    $apiUrl = "https://api.github.com/repos/$owner/$repo/contents/$path?ref=$ref"
    $apiHeaders = $Headers.Clone(); $apiHeaders['Accept'] = 'application/vnd.github.raw'
    Invoke-WebRequest -Uri $apiUrl -Headers $apiHeaders -UseBasicParsing -OutFile $DestPath
    Log ("Saved via API fallback to: {0}" -f $DestPath)
  } else { Fail "Download failed. Ensure PAT has repo scope and URL is valid." }
}

# cleanup sensitive values
$GitHubPAT = $null; [System.GC]::Collect()

# ------------------- RUN DOWNLOADED SCRIPT -------------------
try { Unblock-File -LiteralPath $DestPath } catch {}
Log "Launching downloaded script..."
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$DestPath`"") -NoNewWindow -Wait
Log "Execution complete."
if ($global:_TranscriptStarted) { Stop-Transcript | Out-Null }
Log "=== Logging complete: $LogFile ==="
