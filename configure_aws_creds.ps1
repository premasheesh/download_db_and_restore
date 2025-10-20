# ==================== CONFIG ====================
$Config = [ordered]@{
  VaultName       = "kv-s3-bucket"
  AccessKeyName   = "aws-access-key-id"
  SecretKeyName   = "aws-secret-access-key"
  SessionTokName  = ""               # e.g. "aws-session-token" if present
  ProfileName     = ""               # leave blank to use 'default'
  Region          = "us-east-1"
  UseManagedId    = $false           # $true -> az login --identity
  WriteToAwsCli   = $true            # $false -> set env vars only
}

# =================== SCRIPT =====================
$ErrorActionPreference = "Stop"
function Fail($m){ Write-Error $m; exit 1 }
function Log($m){ Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

# Require az + aws only (no NuGet/modules)
if (-not (Get-Command az -ErrorAction SilentlyContinue))  { Fail 'Azure CLI "az" not found on PATH.' }
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { Fail 'AWS CLI "aws" not found on PATH.' }

# Azure login (optional)
try {
  $acct = az account show -o tsv 2>$null
  if ($LASTEXITCODE -ne 0) {
    if ($Config.UseManagedId) {
      Log 'Logging in with managed identity...'
      az login --identity | Out-Null
    } else {
      Log 'No az session found. Run "az login" (interactive) and retry, or set UseManagedId = $true.'
      Fail 'Not logged in to Azure.'
    }
  }
} catch { Fail ("Azure CLI login check failed: {0}" -f $_) }

# Read secrets via az keyvault (RBAC on the vault must allow secrets get/list)
Log ("Reading secrets from Key Vault '{0}'..." -f $Config.VaultName)

$AWS_ACCESS_KEY_ID = (az keyvault secret show --vault-name $Config.VaultName --name $Config.AccessKeyName --query value -o tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AWS_ACCESS_KEY_ID)) {
  Fail ("Failed to read {0} from Key Vault." -f $Config.AccessKeyName)
}

$AWS_SECRET_ACCESS_KEY = (az keyvault secret show --vault-name $Config.VaultName --name $Config.SecretKeyName --query value -o tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AWS_SECRET_ACCESS_KEY)) {
  Fail ("Failed to read {0} from Key Vault." -f $Config.SecretKeyName)
}

$AWS_SESSION_TOKEN = ""
if ($Config.SessionTokName) {
  $AWS_SESSION_TOKEN = (az keyvault secret show --vault-name $Config.VaultName --name $Config.SessionTokName --query value -o tsv).Trim()
  if ($LASTEXITCODE -ne 0) { Fail ("Failed to read {0} from Key Vault." -f $Config.SessionTokName) }
}

if ($Config.WriteToAwsCli) {
  # ----- Fallback profile logic -----
  $TargetProfile = if ([string]::IsNullOrWhiteSpace($Config.ProfileName)) { "default" } else { $Config.ProfileName }
  if ([string]::IsNullOrWhiteSpace($Config.ProfileName)) {
    Log 'No profile name specified — using AWS CLI default profile.'
  } else {
    Log ("Writing AWS CLI profile '{0}'..." -f $TargetProfile)
  }

  # ----- Configure AWS CLI profile -----
  aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     --profile "$TargetProfile"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$TargetProfile"
  if ($AWS_SESSION_TOKEN) { aws configure set aws_session_token "$AWS_SESSION_TOKEN" --profile "$TargetProfile" }

  if ($Config.Region) {
    aws configure set region "$($Config.Region)" --profile "$TargetProfile"
    aws configure set output json               --profile "$TargetProfile"
  }

  # ----- Session env for immediate use -----
  $env:AWS_PROFILE = $TargetProfile
  if ($Config.Region) { $env:AWS_DEFAULT_REGION = $Config.Region }

  # Optional sanity check
  try {
    aws sts get-caller-identity --profile "$TargetProfile" 1>$null
  } catch {
    Fail ("AWS profile '{0}' not usable (sts call failed)." -f $TargetProfile)
  }

  Log ("Profile set. Session AWS_PROFILE='{0}'." -f $TargetProfile)
} else {
  Log 'Setting session-only environment variables...'
  $env:AWS_ACCESS_KEY_ID     = $AWS_ACCESS_KEY_ID
  $env:AWS_SECRET_ACCESS_KEY = $AWS_SECRET_ACCESS_KEY
  if ($AWS_SESSION_TOKEN) { $env:AWS_SESSION_TOKEN = $AWS_SESSION_TOKEN }
  if ($Config.Region)     { $env:AWS_DEFAULT_REGION = $Config.Region }
}

# hygiene
$AWS_ACCESS_KEY_ID = $null
$AWS_SECRET_ACCESS_KEY = $null
$AWS_SESSION_TOKEN = $null

Log 'Done. Try: aws sts get-caller-identity'
