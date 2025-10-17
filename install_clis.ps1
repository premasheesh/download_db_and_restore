# install_clis.ps1
# Installs AWS CLI v2 and Azure CLI on Windows using PowerShell.
# Designed for unattended execution in a system context with administrative privileges.
# Downloads to C:\Temp and includes MSI logging for troubleshooting.

# ==== CHECK ADMIN PRIVILEGES ====
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $errorMessage = "This script requires administrative privileges. Please run it in an elevated context (e.g., as SYSTEM via Task Scheduler or an admin account)."
    Write-Host "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))] ERROR: $errorMessage"
    Write-Error $errorMessage
    exit 1
}

# ==== CONFIG ====
$ErrorActionPreference = "Stop"

# AWS CLI
$AwsMsiUrl = "https://awscli.amazonaws.com/AWSCLIV2.msi"

# Azure CLI (64-bit preferred; change to $AzureMsiUrl32 if 32-bit needed)
$AzureMsiUrl64 = "https://aka.ms/installazurecliwindowsx64"
$AzureMsiUrl32 = "https://aka.ms/installazurecliwindows"

# Use 64-bit by default if system supports it
$AzureMsiUrl = if ([Environment]::Is64BitOperatingSystem) { $AzureMsiUrl64 } else { $AzureMsiUrl32 }

# Temporary directory for downloads
$TempDir = "C:\Temp"
if (-not (Test-Path $TempDir)) { New-Item -Path $TempDir -ItemType Directory -Force | Out-Null }
$AwsMsiPath = Join-Path $TempDir "AWSCLIV2.msi"
$AzureMsiPath = Join-Path $TempDir "AzureCLI.msi"

# ==== FUNCTIONS ====
function Write-Log($Message) {
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Timestamp] $Message"
}

function Test-CommandExists($Command) {
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Install-Msi($MsiPath, $MsiUrl) {
    if (-not (Test-Path $MsiPath)) {
        Write-Log "Downloading MSI from $MsiUrl..."
        try {
            Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing
            Write-Log "Download complete."
        } catch {
            Write-Error "Failed to download MSI: $($_.Exception.Message)"
            return $false
        }
    }

    Write-Log "Installing MSI from $MsiPath (silent mode with logging)..."
    try {
        $LogPath = "$MsiPath.log"
        $ProcessArgs = "/i `"$MsiPath`" /quiet /norestart /l*v `"$LogPath`""
        $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList $ProcessArgs -Wait -PassThru -NoNewWindow
        if ($Process.ExitCode -eq 0) {
            Write-Log "Installation successful."
            Remove-Item -Force $MsiPath -ErrorAction SilentlyContinue
            Remove-Item -Force $LogPath -ErrorAction SilentlyContinue
            return $true
        } else {
            Write-Error "MSI installation failed with exit code: $($Process.ExitCode). Check log at $LogPath"
            return $false
        }
    } catch {
        Write-Error "Failed to install MSI: $($_.Exception.Message)"
        return $false
    }
}

function Verify-Installation($Command, $VersionCmd) {
    if (Test-CommandExists $Command) {
        $VersionOutput = & $Command --version 2>$null
        Write-Log "$Command is installed: $VersionOutput"
        return $true
    } else {
        Write-Error "$Command is not found in PATH."
        return $false
    }
}

# ==== MAIN SCRIPT ====
Write-Log "Starting CLI installations in elevated system context."

# Check if already installed
if (Test-CommandExists "aws") {
    Write-Log "AWS CLI is already installed. Skipping AWS installation."
} else {
    Write-Log "Installing AWS CLI v2..."
    if (-not (Install-Msi $AwsMsiPath $AwsMsiUrl)) {
        Write-Log "AWS CLI installation failed. Exiting."
        exit 1
    }
}

if (Test-CommandExists "az") {
    Write-Log "Azure CLI is already installed. Skipping Azure installation."
} else {
    Write-Log "Installing Azure CLI (64-bit if supported)..."
    if (-not (Install-Msi $AzureMsiPath $AzureMsiUrl)) {
        Write-Log "Azure CLI installation failed. Exiting."
        exit 1
    }
}

# Verification
Write-Log "Verifying installations..."
$awsSuccess = Verify-Installation "aws" "aws --version"
$azSuccess = Verify-Installation "az" "az version"

if ($awsSuccess -and $azSuccess) {
    Write-Log "Installation and verification complete! AWS CLI and Azure CLI are installed."
} else {
    Write-Log "One or both CLIs failed to verify. Check logs at $TempDir for details."
    exit 1
}

Write-Log "For Azure CLI, you can now run 'az login' to authenticate (if applicable)."