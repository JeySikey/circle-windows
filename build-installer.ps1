# Initial Circle Windows installation from source. Future signed ZIP releases
# are installed inside the app without running Inno Setup again.
param(
  [string]$Repository = $env:CIRCLE_GITHUB_REPO,
  [string]$PublicKey = $env:CIRCLE_UPDATE_PUBLIC_KEY
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
flutter config --enable-windows-desktop
if ($LASTEXITCODE -ne 0) { throw 'Flutter config failed' }
flutter create --platforms=windows --project-name=circle_windows .
if ($LASTEXITCODE -ne 0) { throw 'Flutter create failed' }
Copy-Item branding\circle.ico windows\runner\resources\app_icon.ico -Force
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Flutter pub get failed' }
flutter analyze --no-fatal-infos
if ($LASTEXITCODE -ne 0) { throw 'Dart analysis failed' }
flutter test
if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
$defs = @('--dart-define=CIRCLE_GITHUB_REPO=' + $Repository, '--dart-define=CIRCLE_UPDATE_PUBLIC_KEY=' + $PublicKey)
flutter build windows --release @defs
if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed' }
$exe = 'build\windows\x64\runner\Release\circle_windows.exe'
if (-not (Test-Path $exe)) { throw "Missing $exe" }
& .\tool\package_windows.ps1
if ($LASTEXITCODE -ne 0) { throw 'Windows runtime staging failed' }
$compiler = @( "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "${env:ProgramFiles}\Inno Setup 6\ISCC.exe" ) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $compiler) { throw 'Install Inno Setup 6' }
& $compiler '/DAppVersion=0.8.1' installer\Circle.iss
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
Write-Host 'Done: dist\Circle_Windows_0.8.1_Setup.exe'
if (-not ($Repository -and $PublicKey)) {
  Write-Warning 'Unsigned/unconfigured channel: set CIRCLE_GITHUB_REPO and CIRCLE_UPDATE_PUBLIC_KEY, or build via GitHub Actions with signing secret.'
}
