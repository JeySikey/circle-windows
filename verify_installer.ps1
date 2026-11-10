<#
.SYNOPSIS
  Verify initial Circle Windows installation on a GitHub Actions Windows runner.
.DESCRIPTION
  Inno Setup uses the Windows GUI subsystem. Invoking the setup EXE with `&` in
  PowerShell does not reliably wait for it, which leaves $LASTEXITCODE unset.
  Start-Process -Wait -PassThru blocks until the install completes and provides
  the real ExitCode. On failure, emit the last lines of Inno's /LOG output.
#>
[CmdletBinding()]
param(
  [string]$ReleaseDirectory,
  [string]$InstallerDirectory,
  [string]$InstallationDirectory,
  [string]$LogDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $root 'build\windows\x64\runner\Release' }
if (-not $InstallerDirectory) { $InstallerDirectory = Join-Path $root 'dist' }
if (-not $LogDirectory) { $LogDirectory = Join-Path $env:TEMP 'circle-setup-verification' }
if (-not $InstallationDirectory) { $InstallationDirectory = Join-Path $env:TEMP 'Circle-Installer-Verification' }

$required = @(
  'circle_windows.exe',
  'flutter_windows.dll',
  'msvcp140.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll',
  'data\icudtl.dat',
  'data\flutter_assets',
  'tools\apply_update.ps1',
  'tools\diagnose_windows.ps1',
  'tools\Circle-Diagnostics.cmd'
)
function Assert-Runtime([string]$Folder, [string]$Stage) {
  foreach ($item in $required) {
    $path = Join-Path $Folder $item
    if (-not (Test-Path -LiteralPath $path)) {
      throw "$Stage missing runtime: $item ($path)"
    }
  }
}

# Fail before invoking Inno if the Flutter release bundle itself is incomplete.
Assert-Runtime $ReleaseDirectory 'Flutter Release bundle'
$installers = @(Get-ChildItem -LiteralPath $InstallerDirectory -File -Filter '*_Setup.exe')
if ($installers.Count -ne 1) {
  throw "Expected exactly one Inno Setup EXE in $InstallerDirectory, found $($installers.Count)"
}
$installer = $installers[0]
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$logFile = Join-Path $LogDirectory 'inno-install.log'
if (Test-Path -LiteralPath $logFile) { Remove-Item -LiteralPath $logFile -Force }

# Keep the smoke install isolated from any previous Circle installation.
if (Test-Path -LiteralPath $InstallationDirectory) {
  Remove-Item -LiteralPath $InstallationDirectory -Force -Recurse
}

# Inno documents /DIR and /LOG as arguments whose paths must be quoted.
$arguments = @(
  '/SP-',
  '/VERYSILENT',
  '/SUPPRESSMSGBOXES',
  '/NORESTART',
  '/NOICONS',
  ('/DIR="{0}"' -f $InstallationDirectory),
  ('/LOG="{0}"' -f $logFile)
)
Write-Host "Checking initial installation of $($installer.Name)"
Write-Host "Installation directory: $InstallationDirectory"
Write-Host "Installer log: $logFile"
$passed = $false
try {
  # GUI EXEs can return immediately from the PowerShell call operator (&).
  # Only Start-Process -Wait -PassThru yields a dependable exit code.
  $process = Start-Process -FilePath $installer.FullName -ArgumentList $arguments -Wait -PassThru -ErrorAction Stop
  $exitCode = $process.ExitCode
  if ($null -eq $exitCode) {
    throw 'Inno Setup ended without an observable ExitCode'
  }
  Write-Host "Inno Setup exit code: $exitCode"
  if ($exitCode -ne 0) {
    throw "Inno Setup installation failed: exit code $exitCode"
  }
  Assert-Runtime $InstallationDirectory 'Installed Circle'
  $passed = $true
  Write-Host 'PASS: Inno Setup completed and all required Windows runtime files are installed.'
} finally {
  if (Test-Path -LiteralPath $logFile) {
    $tail = if ($passed) { 15 } else { 120 }
    Write-Host "----- Inno Setup install log (last $tail lines) -----"
    Get-Content -LiteralPath $logFile -Tail $tail | ForEach-Object { Write-Host $_ }
  } else {
    Write-Warning "Installer produced no log at $logFile. It may have failed before Inno initialized."
  }
}
