# Verify the actual Inno Setup installer on Windows CI, not only flutter build.
# Inno Setup is a Windows GUI executable. Calling it with & can return before it
# exits and leave $LASTEXITCODE unset; testing $null -ne 0 causes a false failure.
# Start-Process -Wait -PassThru gives a reliable Process.ExitCode.
[CmdletBinding()]
param([string]$InstallerPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
$match = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$')
if (-not $match.Success) { throw 'Cannot read app version from pubspec.yaml' }
$version = $match.Groups[1].Value
if (-not $InstallerPath) {
  $InstallerPath = Join-Path $root "dist\Circle_Windows_${version}_Setup.exe"
}
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
  throw "Expected Inno installer not found: $InstallerPath"
}
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
if (-not $tempRoot) { throw 'Neither RUNNER_TEMP nor TEMP was configured' }
$destination = Join-Path $tempRoot 'Circle-Installer-Verification'
$logPath = Join-Path $tempRoot 'circle-install.log'
$reportPath = Join-Path $tempRoot 'circle-install-verification.txt'
$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path -LiteralPath $release -PathType Container)) {
  throw "Flutter release output not found: $release"
}

# Do not modify an existing installed copy. The CI runner should be clean.
if (Test-Path -LiteralPath $destination) {
  throw "Verification destination is not empty; refusing to overwrite: $destination"
}
$null = New-Item -ItemType Directory -Path (Split-Path $reportPath -Parent) -Force
"Circle $version installer validation" | Set-Content -LiteralPath $reportPath -Encoding utf8
"Installer: $InstallerPath" | Add-Content -LiteralPath $reportPath -Encoding utf8
"Target: $destination" | Add-Content -LiteralPath $reportPath -Encoding utf8

try {
  $setupArgs = @(
    '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
    "/DIR=`"$destination`"", "/LOG=`"$logPath`""
  )
  Write-Host "Installing Circle $version to verification directory..."
  $proc = Start-Process -FilePath $InstallerPath -ArgumentList $setupArgs -Wait -PassThru -ErrorAction Stop
  if ($null -eq $proc) { throw 'Windows returned no installation process' }
  $exitCode = [int]$proc.ExitCode
  "Installer exit code: $exitCode" | Add-Content -LiteralPath $reportPath -Encoding utf8
  if ($exitCode -ne 0) { throw "Inno Setup exited with code $exitCode" }

  $required = @(
    'circle_windows.exe', 'flutter_windows.dll',
    'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
    'data\flutter_assets', 'data\icudtl.dat'
  )
  foreach ($relative in $required) {
    $installed = Join-Path $destination $relative
    if (-not (Test-Path -LiteralPath $installed)) {
      throw "Missing essential installed payload: $relative"
    }
  }

  # The package must contain every file emitted by Flutter, including plugins.
  # This catches Inno filters accidentally omitting native plugin DLLs/assets.
  $sourceFiles = @(Get-ChildItem -LiteralPath $release -File -Recurse)
  if ($sourceFiles.Count -eq 0) { throw 'Flutter release directory is empty' }
  foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($release.Length).TrimStart([char[]]@('\', '/'))
    $installed = Join-Path $destination $relative
    if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
      throw "Installer omitted Flutter output: $relative"
    }
    if ((Get-Item -LiteralPath $installed).Length -ne $file.Length) {
      throw "Wrong file size after installation: $relative"
    }
  }
  foreach ($name in @('circle_windows.exe', 'flutter_windows.dll', 'data\icudtl.dat')) {
    $expected = (Get-FileHash -LiteralPath (Join-Path $release $name) -Algorithm SHA256).Hash
    $actual = (Get-FileHash -LiteralPath (Join-Path $destination $name) -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "Checksum mismatch after installation: $name" }
  }

  $success = "PASS: installer exited 0, essentials present, $($sourceFiles.Count) Flutter output files verified"
  Write-Host $success
  $success | Add-Content -LiteralPath $reportPath -Encoding utf8
} catch {
  $message = "FAIL: $($_.Exception.Message)"
  Write-Host $message
  $message | Add-Content -LiteralPath $reportPath -Encoding utf8
  if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    Write-Host '--- Last 80 lines of Inno Setup installation log ---'
    Get-Content -LiteralPath $logPath -Tail 80 | ForEach-Object { Write-Host $_ }
  } else {
    Write-Host 'Inno Setup did not create a log file.'
  }
  throw
} finally {
  Write-Host "CI verification report: $reportPath"
  Write-Host "Inno Setup log: $logPath"
}
