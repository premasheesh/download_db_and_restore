# ==================== CONFIG ====================
$Config = [ordered]@{
  # --- Azure auth mode ---
  AuthMode            = "ServicePrincipal"

  # === Service Principal Credentials ===
  TenantId            = "16e34764-f598-4c2c-88c4-2e19fa02fbb6"  # Directory (tenant) ID
  ClientId            = "5f515515-3860-4919-b692-0cfc9f1379e2"  # Application (client) ID
  ClientSecret        = "Ma98Q~G7tY9bjCAPhiPa0_urAndd~fQU3~n0Ka0K"  # Replace with new full secret VALUE

  SubscriptionId      = ""          # optional
  DefaultResourceGroup= ""          # optional
  DefaultLocation     = ""          # optional
  UseDeviceCode       = $false

  # === Key Vault & AWS ===
  VaultName           = "kv-s3-bucket"
  AccessKeyName       = "aws-access-key-id"
  SecretKeyName       = "aws-secret-access-key"
  SessionTokName      = ""
  ProfileName         = ""
  Region              = ""
  WriteToAwsCli       = $true
}

# =================== SCRIPT =====================
$ErrorActionPreference = "Stop"
function Fail($m){ Write-Error $m; exit 1 }
function Log($m){ Write-Host ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

# Require az + aws
if (-not (Get-Command az -ErrorAction SilentlyContinue))  { Fail 'Azure CLI "az" not found on PATH.' }
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { Fail 'AWS CLI "aws" not found on PATH.' }

# ---------- Azure CLI auto-login ----------
function Ensure-AzLogin {
  param(
    [string]$AuthMode,
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret
  )

  try {
    az account show -o none 2>$null
    if ($LASTEXITCODE -eq 0) { Log "Azure CLI already logged in."; return }
  } catch {}

  switch ($AuthMode) {
    "ServicePrincipal" {
      Log "Logging into Azure with Service Principal..."
      az login --service-principal `
        --tenant $TenantId `
        --username $ClientId `
        --password "$ClientSecret" 1>$null
      if ($LASTEXITCODE -ne 0) { Fail "Service Principal login failed." }
    }
    "ManagedIdentity" {
      Log "Logging into Azure with Managed Identity..."
      az login --identity | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail "Managed Identity login failed." }
    }
    default {
      Log "Logging into Azure interactively..."
      az login
      if ($LASTEXITCODE -ne 0) { Fail "Interactive Azure login failed." }
    }
  }

  Log "Azure login successful."
}

# Step 1: Login to Azure
Ensure-AzLogin `
  -AuthMode $Config.AuthMode `
  -TenantId $Config.TenantId `
  -ClientId $Config.ClientId `
  -ClientSecret $Config.ClientSecret

# Step 2: Read AWS creds from Key Vault
Log ("Reading secrets from Key Vault '{0}'..." -f $Config.VaultName)

$AWS_ACCESS_KEY_ID = (az keyvault secret show --vault-name $Config.VaultName --name $Config.AccessKeyName --query value -o tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AWS_ACCESS_KEY_ID)) {
  Fail ("Failed to read {0} from Key Vault." -f $Config.AccessKeyName)
}

$AWS_SECRET_ACCESS_KEY = (az keyvault secret show --vault-name $Config.VaultName --name $Config.SecretKeyName --query value -o tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AWS_SECRET_ACCESS_KEY)) {
  Fail ("Failed to read {0} from Key Vault." -f $Config.SecretKeyName)
}

# Step 3: Configure AWS CLI
$Profile = if ([string]::IsNullOrWhiteSpace($Config.ProfileName)) { "default" } else { $Config.ProfileName }
Log ("Configuring AWS CLI profile '{0}'..." -f $Profile)

aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$Profile"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$Profile"
aws configure set region "$($Config.Region)" --profile "$Profile"
aws configure set output json --profile "$Profile"

$env:AWS_PROFILE = $Profile
$env:AWS_DEFAULT_REGION = $Config.Region

Log "Testing AWS credentials..."
try {
  aws sts get-caller-identity --profile "$Profile" | Out-Host
} catch {
  Fail ("AWS authentication test failed for profile '{0}'." -f $Profile)
}

Log "✅ Azure + AWS configuration complete."
