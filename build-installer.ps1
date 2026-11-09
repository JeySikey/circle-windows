param(
  [string]$UpdateUrl = '',
  [string]$UpdatePublicKey = ''
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
flutter config --enable-windows-desktop
if ($LASTEXITCODE -ne 0) { throw 'Flutter config failed' }
if (-not (Test-Path windows)) { flutter create --platforms=windows --project-name=circle_windows .; if ($LASTEXITCODE -ne 0) { throw 'Flutter create failed' } }
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Flutter pub get failed' }
flutter analyze
if ($LASTEXITCODE -ne 0) { throw 'Dart analysis failed' }
flutter test
if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
$defs = @()
if ($UpdateUrl -and $UpdatePublicKey) {
  $defs += '--dart-define=CIRCLE_UPDATE_URL=' + $UpdateUrl
  $defs += '--dart-define=CIRCLE_UPDATE_PUBLIC_KEY=' + $UpdatePublicKey
}
flutter build windows --release @defs
if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed' }
$exe = 'build\windows\x64\runner\Release\circle_windows.exe'
if (-not (Test-Path $exe)) { throw "Missing $exe" }
$compiler = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "${env:ProgramFiles}\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $compiler) { throw 'Install Inno Setup 6' }
& $compiler '/DAppVersion=0.3.2' installer\Circle.iss
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
Write-Host 'Done: dist\Circle_Windows_0.3.2_Setup.exe'
