# Bundle Microsoft's app-local VC++ runtime from the signed Visual Studio
# toolchain already installed on the Windows builder (see Flutter Windows docs).
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'circle_windows.exe'))) { throw 'Missing native EXE (flutter build windows --release first)' }
if (-not (Test-Path (Join-Path $release 'flutter_windows.dll'))) { throw 'Missing Flutter engine DLL' }
if (-not (Test-Path (Join-Path $release 'data\flutter_assets'))) { throw 'Missing Flutter assets directory' }
if (-not (Test-Path (Join-Path $release 'data\icudtl.dat'))) { throw 'Missing Flutter ICU data' }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found; install Visual Studio C++ build tools' }
$vsroot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if (-not $vsroot) { throw 'Visual Studio C++ toolchain not found' }
$redistRoot = Join-Path $vsroot 'VC\Redist\MSVC'
$folders = @(Get-ChildItem $redistRoot -Directory -ErrorAction Stop | Sort-Object Name -Descending)
$crt = $null
foreach ($folder in $folders) {
  $candidates = @(Get-ChildItem (Join-Path $folder.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  foreach ($candidate in $candidates) {
    if ((Test-Path (Join-Path $candidate.FullName 'msvcp140.dll')) -and (Test-Path (Join-Path $candidate.FullName 'vcruntime140.dll'))) {
      $crt = $candidate.FullName
      break
    }
  }
  if ($crt) { break }
}
if (-not $crt) { throw 'MSVC x64 CRT redistributable directory not found' }
Get-ChildItem -Path $crt -Filter '*.dll' -File | ForEach-Object {
  Copy-Item $_.FullName (Join-Path $release $_.Name) -Force
}
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
  if (-not (Test-Path (Join-Path $release $name))) { throw "CRT staging failed: $name" }
}
Write-Host "Windows payload ready: $release"
Write-Host "VC++ runtime copied from: $crt"
