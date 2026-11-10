# Circle in-place updater (Windows PowerShell 5.1, .NET Framework).
# Execute only after the Dart client verifies the pinned Ed25519 signature and
# SHA-256 of this complete GitHub Release archive.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [Parameter(Mandatory=$true)][string]$ExpectedSha256,
    [Parameter(Mandatory=$true)][string]$ExePath,
    [Parameter(Mandatory=$true)][int]$ParentPid,
    [Parameter(Mandatory=$true)][string]$Version,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
$logFolder = Join-Path $env:LOCALAPPDATA 'Circle\updates'
New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
$log = Join-Path $logFolder 'update.log'
function Log([string]$message) {
    "$(Get-Date -Format o) $message" | Add-Content -LiteralPath $log -Encoding UTF8
}
$stage = $null; $backup = $null; $installedNew = $false; $movedOld = $false; $exeFull = $null
try {
    if ($ExpectedSha256 -notmatch '^[a-f0-9]{64}$' -or $Version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Invalid update arguments'
    }
    if (!(Test-Path -LiteralPath $Archive -PathType Leaf)) { throw 'Payload ZIP missing' }
    $actualHash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $ExpectedSha256) { throw 'Archive SHA-256 mismatch' }
    $exeFull = [System.IO.Path]::GetFullPath($ExePath)
    if ([System.IO.Path]::GetFileName($exeFull).ToLowerInvariant() -ne 'circle_windows.exe') {
        throw 'Unexpected executable name'
    }
    $root = [System.IO.Path]::GetDirectoryName($exeFull)
    $parent = [System.IO.Path]::GetDirectoryName($root)
    if (-not $parent -or !(Test-Path -LiteralPath $root -PathType Container)) {throw 'Application directory missing'}
    $nonce = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $parent ('Circle.stage.' + $nonce)
    $backup = Join-Path $parent ('Circle.backup.' + $nonce)
    New-Item -ItemType Directory -Path $stage | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 12000) {throw 'Too many archive entries'}
        [long]$total = 0
        $stagePrefix = [System.IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ($name.StartsWith('\') -or $name.Contains(':') -or $name -match '(^|\\)\.\.(\\|$)' -or
                $name.Contains([char]0) -or $name.Contains('\\\\')) {throw 'Unsafe archive path'}
            $segments = $name.Split('\')
            foreach ($segment in $segments) {
                if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
                    throw 'Windows reserved archive path'
                }
            }
            # Deny Unix symlinks (zip external attributes contain S_IFLNK).
            if ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960) {throw 'ZIP symlink not allowed'}
            $dest = [System.IO.Path]::GetFullPath((Join-Path $stage $name))
            if (!$dest.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ZIP path escaped the staging directory'
            }
            $total += $entry.Length
            if ($total -gt 1200MB) {throw 'Unpacked payload is too large'}
        }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($name)) {continue}
            $dest = [System.IO.Path]::GetFullPath((Join-Path $stage $name))
            if ($name.EndsWith('\')) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            } else {
                New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($dest)) -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $false)
            }
        }
    } finally {
        $zip.Dispose()
    }
    foreach ($needed in @('circle_windows.exe','flutter_windows.dll','data\flutter_assets','data\icudtl.dat','tools\apply_update.ps1')) {
        if (!(Test-Path -LiteralPath (Join-Path $stage $needed))) {throw "Missing payload component: $needed"}
    }
    if ($ValidateOnly) {
        Log "Verified update payload $Version ($total bytes); no changes performed"
        exit 0
    }
    Log "Staged update $Version ($total bytes). Waiting for Circle PID $ParentPid"
    $deadline = (Get-Date).AddSeconds(55)
    while ((Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
    }
    if (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
        throw 'Old Circle process did not exit; update aborted'
    }
    # Move old folder aside, then move the complete payload into its place.
    # This avoids partial DLL updates and supports rollback.
    for ($i = 0; $i -lt 12; $i++) {
        try {Move-Item -LiteralPath $root -Destination $backup -ErrorAction Stop; $movedOld = $true; break}
        catch {if ($i -eq 11) {throw}; Start-Sleep -Milliseconds 500}
    }
    Move-Item -LiteralPath $stage -Destination $root -ErrorAction Stop
    $stage = $null; $installedNew = $true
    $newExe = Join-Path $root 'circle_windows.exe'
    $process = Start-Process -FilePath $newExe -WorkingDirectory $root -PassThru
    Start-Sleep -Seconds 6
    $process.Refresh()
    if ($process.HasExited) {throw "Updated Circle exited on startup: $($process.ExitCode)"}
    Log "Update to $Version succeeded; backup: $backup"
    # Keep one rollback copy, but remove older backups to avoid disk buildup.
    $stale = @(Get-ChildItem -LiteralPath $parent -Directory -Filter 'Circle.backup.*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1)
    foreach ($old in $stale) {try {Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop} catch {Log "Old backup retained: $($old.FullName)"}}
    exit 0
} catch {
    Log "FAILED update to ${Version}: $($_.Exception.Message)"
    if (-not $movedOld -and -not $ValidateOnly -and $exeFull -and (Test-Path -LiteralPath $exeFull -PathType Leaf)) {
        try {
            Start-Process -FilePath $exeFull -WorkingDirectory $root | Out-Null
            Log 'Update rejected before swap; previous version restarted'
        } catch {Log "Unable to relaunch previous version: $($_.Exception.Message)"}
    }
    if ($movedOld) {
        try {
            if ($installedNew -and (Test-Path -LiteralPath $root)) {
                # Do not overwrite locked updated files. Move them out of the way.
                $failedDir = Join-Path $parent ('Circle.failed.' + [guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $root -Destination $failedDir -ErrorAction Stop
            }
            if (!(Test-Path -LiteralPath $root) -and (Test-Path -LiteralPath $backup)) {
                Move-Item -LiteralPath $backup -Destination $root -ErrorAction Stop
                Start-Process -FilePath (Join-Path $root 'circle_windows.exe') -WorkingDirectory $root | Out-Null
                Log 'Previous version restored and started'
            }
        } catch {Log "ROLLBACK FAILED: $($_.Exception.Message)"}
    }
    exit 1
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        try {Remove-Item -LiteralPath $stage -Recurse -Force} catch {Log "Stage cleanup failed: $($_.Exception.Message)"}
    }
    if (-not $ValidateOnly -and (Test-Path -LiteralPath $Archive -PathType Leaf)) {
        try {Remove-Item -LiteralPath $Archive -Force} catch {Log "Archive cleanup deferred: $($_.Exception.Message)"}
    }
}
