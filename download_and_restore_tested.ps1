# download_and_restore_tested.ps1
# Downloads the newest .bak file from the most recent YYYYMMDD folder in S3
# Then restores it to SQL Server using sqlcmd. PowerShell 5-safe.

# ==== CONFIG ====
param(
    [switch]$DryRun
)

$Bucket       = "as-rds-backup-shared"
$BasePrefix   = "residential_mtl"     # top-level prefix under the bucket
$InnerSuffix  = "residential_mtl"     # optional inner folder under YYYYMMDD
$OutRoot      = "C:\db_latest_backup" #"$HOME\db_latest_backup"
$Profile      = "default"
$Region       = ""
$NoVerify     = $true
$MaxRetries   = 3
$SleepBase    = 5
$RequireFull  = $true                  # true = only match _FULL_ files

# SQL restore config
$SqlInstance  = "localhost"            
$DefaultDbFallback = "residential_mtl"   # used if DB name can't be parsed from filename

$LogRetentionDays = 2                  # Number of days to retain log files
$BakRetentionDays = 2                  # Number of days to retain .bak files

# ==== SETUP ====
$ErrorActionPreference = "Continue"
$env:PYTHONWARNINGS = "ignore:Unverified HTTPS request"

# AWS CLI detection
$awsCmdObj = Get-Command aws.exe -ErrorAction SilentlyContinue
if (-not $awsCmdObj) { Write-Host "AWS CLI not found. Install AWS CLI v2 and ensure it is in PATH."; exit 1 }
$AwsCmd = $awsCmdObj.Source

# sqlcmd detection
$sqlcmdObj = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
if (-not $sqlcmdObj) { Write-Host "sqlcmd.exe not found. Install SQL Server Command Line Utilities or ensure it's in PATH."; exit 1 }
$SqlCmd = $sqlcmdObj.Source

# Build common AWS args
$Common = @()
if ($Profile) { $Common += @("--profile", $Profile) }
if ($Region)  { $Common += @("--region", $Region) }
if ($NoVerify){ $Common += "--no-verify-ssl" }

# Validate AWS credentials
try {
    & "$AwsCmd" sts get-caller-identity @Common | Out-Null
} catch {
    Write-Host "AWS credentials invalid or expired."; exit 1
}

# ==== LOG SETUP ====
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
# Create $OutRoot and logs subdirectory if they don't exist
if (-not (Test-Path $OutRoot)) { New-Item -Path $OutRoot -ItemType Directory -Force | Out-Null }
$LogDir = Join-Path $OutRoot "logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir "restore_$Timestamp.log"

function Log($msg) {
    $formatted = ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg)
    Write-Host $formatted
    Add-Content -Path $LogFile -Value $formatted -Encoding UTF8
}

# Log retention: Delete old log files in logs subdirectory
Log "Cleaning old log files older than $LogRetentionDays days from $LogDir..."
Get-ChildItem -Path $LogDir -Filter "restore_*.log" -ErrorAction SilentlyContinue | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } | 
    Remove-Item -Force -ErrorAction SilentlyContinue

# .bak file retention: Delete .bak files older than $BakRetentionDays
Log "Cleaning .bak files older than $BakRetentionDays days from $OutRoot..."
Get-ChildItem -Path $OutRoot -Filter "*.bak" | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$BakRetentionDays) } | 
    Remove-Item -Force -ErrorAction SilentlyContinue

# ==== FIND LATEST FOLDER ====
Log "Listing folders under s3://$Bucket/$BasePrefix/"
$rootArgs = @("s3api", "list-objects-v2", "--bucket", $Bucket, "--prefix", "$BasePrefix/", "--delimiter", "/", "--output", "json") + $Common
$rootOut = & "$AwsCmd" @rootArgs 2>$null
if (-not $rootOut) { Log "No output from AWS CLI."; exit 1 }
if ($rootOut -match '"AccessDenied"') { Log "Access denied to bucket $Bucket."; exit 1 }

try { $rootObj = $rootOut | ConvertFrom-Json } catch { Log "Invalid JSON from AWS CLI."; exit 1 }

$AllFolders = @()
foreach ($cp in $rootObj.CommonPrefixes) {
    if ($cp.Prefix -match "$BasePrefix/(\d{8})/") { $AllFolders += $Matches[1] }
}
if (-not $AllFolders) { Log "!!!!===== No folders found under $BasePrefix/"; exit 0 }

[int]$Latest = ($AllFolders | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum
$LatestFolder = ("{0:D8}" -f $Latest)
Log "====== Latest folder found is::::: $LatestFolder"

# ==== FIND LATEST .BAK IN THAT FOLDER ====
$Prefix = if ($InnerSuffix) { "$BasePrefix/$LatestFolder/$InnerSuffix/" } else { "$BasePrefix/$LatestFolder/" }
Log "===== Scanning s3://$Bucket/$Prefix"

$Best = $null
$BestLM = Get-Date 0
$continuation = $null

do {
    $pageArgs = @("s3api", "list-objects-v2", "--bucket", $Bucket, "--prefix", $Prefix, "--output", "json") + $Common
    if ($continuation) { $pageArgs += @("--continuation-token", $continuation) }
    $pageOut = & "$AwsCmd" @pageArgs 2>$null
    if (-not $pageOut) { break }

    try { $page = $pageOut | ConvertFrom-Json } catch { break }

    foreach ($f in $page.Contents) {
        $k = $f.Key
        if ($k -notlike "*.bak") { continue }
        if ($RequireFull -and ($k -notmatch "_FULL_")) { continue }
        $lm = [datetime]$f.LastModified
        if ($lm -gt $BestLM) { $BestLM = $lm; $Best = $f }
    }

    $continuation = if ($page.IsTruncated -and $page.NextContinuationToken) { $page.NextContinuationToken } else { $null }
} while ($continuation)

if (-not $Best) { Log "!!!!======= No .bak found in $Prefix"; exit 0 }

# ===== DRY RUN started =====
if ($DryRun) {
    $LeafFromS3 = [System.IO.Path]::GetFileName($Best.Key)
    $DbNameSim  = $DefaultDbFallback
    if ($LeafFromS3 -match '^(?<db>.+?)(?=_(FULL|DIFF|LOG)(_|\.))') {
        $DbNameSim = $Matches['db']
    } elseif ($LeafFromS3 -match '^([A-Za-z0-9_]+)_') {
        $DbNameSim = $Matches[1]
    }

    Log ("Latest file: {0} (LastModified: {1})" -f $Best.Key, $Best.LastModified)
    Log "===== DRY RUN MODE ENABLED ====="
    Log "Would download: s3://$Bucket/$($Best.Key)"
    Log "Would restore as database: [$DbNameSim] on instance: $SqlInstance"
    Log "No files were downloaded or restored in this mode."
    exit 0
}

Log ("Latest file: {0} (LastModified: {1})" -f $Best.Key, $Best.LastModified)

# ==== DOWNLOAD ====
$Dest = Join-Path $OutRoot (Split-Path $Best.Key -Leaf)

for ($i = 1; $i -le $MaxRetries; $i++) {
    Log "===== Downloading the latest backup from the latest folder ======"
    Log ("Downloading ({0}/{1}): {2}" -f $i, $MaxRetries, $Best.Key)
    & "$AwsCmd" s3 cp ("s3://$Bucket/$($Best.Key)") $Dest --no-progress @Common

    if ($LASTEXITCODE -eq 0 -and (Test-Path $Dest)) {
        $localSize = (Get-Item $Dest).Length
        if ($localSize -eq [long]$Best.Size) {
            Log "============Download successful. Size verified.============="
            break
        } else {
            Log ("Size mismatch: got {0}, expected {1}" -f $localSize, $Best.Size)
        }
    } else {
        Log "Download failed or file missing."
    }

    if ($i -eq $MaxRetries) {
        Log "!!!!!!!! Download failed after $MaxRetries attempts.!!!!!"
        exit 1
    }

    Remove-Item -Force $Dest -ErrorAction SilentlyContinue
    Start-Sleep -Seconds ($SleepBase * $i)
}

if (-not (Test-Path $Dest)) { Log "File not found after download. Check permissions or disk space."; exit 1 }

# ==== RESTORE ====
$Leaf   = [System.IO.Path]::GetFileName($Dest)
$DbName = $DefaultDbFallback
# Grab the part before _FULL / _DIFF / _LOG (most common tags)
if ($Leaf -match '^(?<db>.+?)(?=_(FULL|DIFF|LOG)(_|\.))') {
    $DbName = $Matches['db']
} elseif ($Leaf -match '^([A-Za-z0-9_]+)_') {
    $DbName = $Matches[1]
}

Log "=========== Download complete. Attempting to restore database [$DbName] from:`n  $Dest=========="

# Define target folder for .mdf and .ldf files
$SqlDataRoot = "C:\SQLData"
if (-not (Test-Path $SqlDataRoot)) {
    try {
        New-Item -Path $SqlDataRoot -ItemType Directory -Force | Out-Null
        Log "Created SQL data folder for .mdf and .ldf files: $SqlDataRoot Restore still in progress......"
    } catch {
        Log "Failed to create SQL data folder: $SqlDataRoot"; exit 1
    }
}

$MdfPath = Join-Path $SqlDataRoot "$DbName.mdf"
$LdfPath = Join-Path $SqlDataRoot "$DbName.ldf"

$SqlH = @"
SET NOCOUNT ON;

DECLARE @bak NVARCHAR(4000) = N'$($Dest.Replace("'", "''"))';
DECLARE @db  SYSNAME        = N'$($DbName.Replace("'", "''"))';
DECLARE @qdb SYSNAME        = QUOTENAME(@db);
DECLARE @mdf NVARCHAR(4000) = N'$($MdfPath.Replace("'", "''"))';
DECLARE @ldf NVARCHAR(4000) = N'$($LdfPath.Replace("'", "''"))';

IF DB_ID(@db) IS NOT NULL
BEGIN
    DECLARE @sqlDrop NVARCHAR(MAX) =
        N'ALTER DATABASE ' + @qdb + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; ' +
        N'DROP DATABASE ' + @qdb + N';';
    EXEC (@sqlDrop);
END

BEGIN TRY
    PRINT N'Starting RESTORE...';
    DECLARE @sql NVARCHAR(MAX) =
        N'RESTORE DATABASE ' + @qdb +
        N' FROM DISK = N''' + @bak + N''' WITH REPLACE, RECOVERY, ' +
        N'MOVE N''' + @db + N''' TO N''' + @mdf + N''', ' +
        N'MOVE N''' + @db + '_log'' TO N''' + @ldf + N''';';
    EXEC (@sql);
    PRINT N'RESTORE completed.';
END TRY
BEGIN CATCH
    PRINT N'RESTORE FAILED: ' + ERROR_MESSAGE();
    THROW;
END CATCH
"@

$TmpSql = Join-Path $env:TEMP ("restore_" + [System.Guid]::NewGuid().ToString("N") + ".sql")
$SqlH | Out-File -Encoding UTF8 -FilePath $TmpSql

Log "Executing SQL restore script..."

$SqlArgs = @("-S", $SqlInstance, "-E", "-C", "-b", "-i", $TmpSql)
$allOut = & "$SqlCmd" @SqlArgs *>&1

Log "SQL Output:"
$allOut | ForEach-Object { Log $_ }

if ($LASTEXITCODE -ne 0) {
    Log "Restore FAILED. See log: $LogFile"
    exit 1
} else {
    Log "Restore completed successfully. See log: $LogFile"
    Remove-Item -Force $TmpSql -ErrorAction SilentlyContinue
    exit 0
}
