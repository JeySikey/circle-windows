# Circle Windows signed, in-place updater (PowerShell 5.1 compatible).
# Runs OUTSIDE the application directory. The Dart client authenticates the
# Ed25519-signed release manifest and the payload SHA-256 before invoking us;
# the digest is checked again here. No installers or elevated permissions.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [Parameter(Mandatory=$true)][string]$ExpectedSha256,
    [Parameter(Mandatory=$true)][string]$ExePath,
    [Parameter(Mandatory=$true)][int]$ParentPid,
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$HandshakeFile = '',
    [switch]$ValidateOnly,
    [switch]$CITestSkipLaunch,
    [switch]$CITestForcePostSwapFailure
)
$ErrorActionPreference = 'Stop'
$logFolder = Join-Path $env:LOCALAPPDATA 'Circle\updates'
New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
$log = Join-Path $logFolder 'update.log'
$resultFile = Join-Path $logFolder 'last_result.json'
function Log([string]$message) {
    "$(Get-Date -Format o) $message" | Add-Content -LiteralPath $log -Encoding UTF8
}
function WriteResult([string]$state, [string]$message) {
    $record = @{ state=$state; version=$Version; message=$message;
                 timestamp=(Get-Date).ToUniversalTime().ToString('o'); log=$log }
    $tempResult = Join-Path $logFolder ('result-' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($tempResult, ($record | ConvertTo-Json -Compress),
        (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempResult -Destination $resultFile -Force
}
$stage = $null; $backup = $null; $movedOld = $false; $installedNew = $false
$root = $null; $parent = $null; $exeFull = $null
try {
    if ($ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$' -or $Version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Invalid update arguments'
    }
    if (($CITestSkipLaunch -or $CITestForcePostSwapFailure) -and $env:GITHUB_ACTIONS -ne 'true') {
        throw 'CI test flag is only available in GitHub Actions'
    }
    if (!(Test-Path -LiteralPath $Archive -PathType Leaf)) { throw 'Update ZIP is missing' }
    $actualHash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $ExpectedSha256) { throw 'Update ZIP SHA-256 mismatch' }
    $exeFull = [System.IO.Path]::GetFullPath($ExePath)
    if ([System.IO.Path]::GetFileName($exeFull).ToLowerInvariant() -ne 'circle_windows.exe') {
        throw 'Unexpected executable name'
    }
    $root = [System.IO.Path]::GetDirectoryName($exeFull)
    $parent = [System.IO.Path]::GetDirectoryName($root)
    if (-not $parent -or !(Test-Path -LiteralPath $root -PathType Container)) {
        throw 'Application directory not found'
    }
    if (!(Test-Path -LiteralPath $exeFull -PathType Leaf)) { throw 'Installed Circle EXE is missing' }
    $nonce = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $parent ('Circle.stage.' + $nonce)
    $backup = Join-Path $parent ('Circle.backup.' + $nonce)
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 12000) { throw 'Too many ZIP entries' }
        $stagePrefix = [System.IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('\') -or
                $name.Contains(':') -or $name -match '(^|\x5c)\.\.(\x5c|$)' -or $name.Contains([char]0)) {
                throw "Unsafe ZIP path: $name"
            }
            if (!$seen.Add($name.TrimEnd('\'))) { throw "Duplicate ZIP entry: $name" }
            foreach ($segment in $name.TrimEnd('\').Split('\')) {
                if ([string]::IsNullOrEmpty($segment) -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
                    $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
                    throw "Reserved Windows ZIP path: $name"
                }
            }
            if ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960) { throw 'ZIP symlinks not allowed' }
            $destination = [System.IO.Path]::GetFullPath((Join-Path $stage $name))
            if (!$destination.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ZIP path escaped the staging directory'
            }
            $total += $entry.Length
            if ($entry.Length -gt 512MB -or $total -gt 1200MB) { throw 'Update payload too large' }
        }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            $destination = [System.IO.Path]::GetFullPath((Join-Path $stage $name))
            if ($name.EndsWith('\')) {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
            } else {
                New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
            }
        }
    } finally {
        $zip.Dispose()
    }
    foreach ($needed in @('circle_windows.exe','flutter_windows.dll','data\flutter_assets','data\icudtl.dat','tools\apply_update.ps1')) {
        if (!(Test-Path -LiteralPath (Join-Path $stage $needed))) { throw "Missing update component: $needed" }
    }
    if ($ValidateOnly) {
        Log "Validation passed for $Version ($total extracted bytes); no files changed"
        exit 0
    }
    # Inno Setup stores uninstall metadata inside {app}. A whole-directory
    # replacement must keep it, otherwise Windows cannot uninstall Circle.
    foreach ($uninstaller in @(Get-ChildItem -LiteralPath $root -File -Filter 'unins*' -ErrorAction SilentlyContinue)) {
        if ($uninstaller.Name -match '^unins\d{3}\.(exe|dat|msg)$') {
            if (Test-Path -LiteralPath (Join-Path $stage $uninstaller.Name)) { throw 'Payload collides with uninstall metadata' }
            Copy-Item -LiteralPath $uninstaller.FullName -Destination (Join-Path $stage $uninstaller.Name) -ErrorAction Stop
        }
    }
    WriteResult 'pending' 'Files downloaded and checked. Preparing update.'
    Log "Payload $Version staged and checked ($total bytes). Parent PID: $ParentPid"
    # Handshake avoids closing the running application if PowerShell failed to
    # start, verify the ZIP or extract its contents.
    if ($HandshakeFile) {
        $handshakeParent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($HandshakeFile))
        if (!(Test-Path -LiteralPath $handshakeParent -PathType Container)) {throw 'Handshake folder missing'}
        [System.IO.File]::WriteAllText($HandshakeFile, 'ready')
    }
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
    }
    if (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
        throw 'Circle did not close within 90 seconds'
    }
    # The staging directory is adjacent to the installation directory, so
    # the directory renames are on the same filesystem. Restore on failure.
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            Move-Item -LiteralPath $root -Destination $backup -ErrorAction Stop
            $movedOld = $true
            break
        } catch {
            if ($attempt -eq 19) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
    Move-Item -LiteralPath $stage -Destination $root -ErrorAction Stop
    $stage = $null; $installedNew = $true
    if ($CITestForcePostSwapFailure) { throw 'Simulated CI failure after directory swap' }
    if ($CITestSkipLaunch) {
        Log "CI validation: swapped Circle directory to $Version without launching a GUI"
    } else {
        $newExe = Join-Path $root 'circle_windows.exe'
        $process = Start-Process -FilePath $newExe -WorkingDirectory $root -PassThru
        Start-Sleep -Seconds 6
        $process.Refresh()
        if ($process.HasExited) { throw "Updated Circle exited on startup: $($process.ExitCode)" }
    }
    WriteResult 'success' "Circle $Version installed successfully"
    Log "Update to $Version succeeded; backup: $backup"
    # Preserve one backup. Older backups can be removed later; failure to
    # remove one must not turn a successful update into a rollback.
    foreach ($old in @(Get-ChildItem -LiteralPath $parent -Directory -Filter 'Circle.backup.*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1)) {
        try { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop }
        catch { Log "Old backup kept: $($old.FullName)" }
    }
    exit 0
} catch {
    $failureMessage = $_.Exception.Message
    Log "FAILED Circle $Version update: $failureMessage"
    $restored = $false
    if ($movedOld) {
        try {
            if ($installedNew -and (Test-Path -LiteralPath $root)) {
                $failedDir = Join-Path $parent ('Circle.failed.' + [guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $root -Destination $failedDir -ErrorAction Stop
            }
            if (!(Test-Path -LiteralPath $root) -and (Test-Path -LiteralPath $backup)) {
                Move-Item -LiteralPath $backup -Destination $root -ErrorAction Stop
                $restored = $true
                Log 'Previous Circle version restored'
            }
        } catch {
            $failureMessage += "; rollback error: $($_.Exception.Message)"
            Log "ROLLBACK FAILED: $($_.Exception.Message)"
        }
    }
    # Write the result BEFORE starting the old application so its startup
    # dialog can immediately show the error, without requiring a log search.
    try { WriteResult 'failed' $failureMessage } catch { Log "Cannot write update result: $($_.Exception.Message)" }
    if ($root -and (Test-Path -LiteralPath (Join-Path $root 'circle_windows.exe')) -and
        -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) -and
        -not $CITestSkipLaunch) {
        try {
            Start-Process -FilePath (Join-Path $root 'circle_windows.exe') -WorkingDirectory $root | Out-Null
            Log 'Previous Circle executable started after failed update'
        } catch { Log "Could not restart previous Circle: $($_.Exception.Message)" }
    }
    exit 1
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        try { Remove-Item -LiteralPath $stage -Recurse -Force }
        catch { Log "Stage cleanup failed: $($_.Exception.Message)" }
    }
    if (-not $ValidateOnly -and (Test-Path -LiteralPath $Archive -PathType Leaf)) {
        try { Remove-Item -LiteralPath $Archive -Force }
        catch { Log "ZIP cleanup deferred: $($_.Exception.Message)" }
    }
}
