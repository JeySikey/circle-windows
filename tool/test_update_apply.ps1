# Windows-only end-to-end self-test for the *actual shipped updater*.
# CI uses a disposable fake installation, not the GitHub runner's working build.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run this self-test only in GitHub Actions' }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseExe = Join-Path $repo 'build\windows\x64\runner\Release\circle_windows.exe'
$package = @(Get-ChildItem (Join-Path $repo 'dist') -File -Filter '*_Payload.zip' | Select-Object -First 1)
if (-not (Test-Path -LiteralPath $releaseExe) -or !$package) {throw 'Build first; EXE and Payload ZIP must exist'}
$base = Join-Path $env:RUNNER_TEMP ('circle-update-verification-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $base 'Circle'
New-Item -ItemType Directory -Path $install -Force | Out-Null
$old = Join-Path $install 'circle_windows.exe'
[IO.File]::WriteAllText($old, 'old-circle-test-binary')
[IO.File]::WriteAllText((Join-Path $install 'obsolete.dat'), 'old-only')
[IO.File]::WriteAllText((Join-Path $install 'unins000.exe'), 'inno-test-uninstaller')
[IO.File]::WriteAllText((Join-Path $install 'unins000.dat'), 'inno-test-uninstall-metadata')
# Test against a copy: the production updater intentionally deletes its input ZIP.
$testPackage = Join-Path $base 'verified-payload.zip'
Copy-Item -LiteralPath $package.FullName -Destination $testPackage
$hash = (Get-FileHash -LiteralPath $testPackage -Algorithm SHA256).Hash.ToLowerInvariant()
$updater = Join-Path $repo 'tool\apply_update.ps1'
Write-Host 'Testing real ZIP extraction, handshake, atomic swap and uninstall metadata...'
$handshake = Join-Path $base 'ready.txt'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $updater -Archive $testPackage -ExpectedSha256 $hash -ExePath $old -ParentPid 999999 -Version 0.7.1 -HandshakeFile $handshake -CITestSkipLaunch
if ($LASTEXITCODE -ne 0) {throw "Real updater failed with $LASTEXITCODE"}
if ([IO.File]::ReadAllText($handshake) -ne 'ready') {throw 'Updater did not write readiness handshake'}
if (-not (Test-Path -LiteralPath $old)) {throw 'Updated EXE missing'}
if ((Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $releaseExe -Algorithm SHA256).Hash) {throw 'Installed EXE differs from built EXE'}
if (Test-Path -LiteralPath (Join-Path $install 'obsolete.dat')) {throw 'Swap left obsolete files in active installation'}
if ([IO.File]::ReadAllText((Join-Path $install 'unins000.exe')) -ne 'inno-test-uninstaller') {throw 'Inno Setup uninstaller was lost'}
if ([IO.File]::ReadAllText((Join-Path $install 'unins000.dat')) -ne 'inno-test-uninstall-metadata') {throw 'Uninstall metadata was lost'}
if (@(Get-ChildItem -LiteralPath $base -Directory -Filter 'Circle.backup.*').Count -ne 1) {throw 'Previous installation backup missing'}
$resultFile = Join-Path $env:LOCALAPPDATA 'Circle\updates\last_result.json'
if ((Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json).state -ne 'success') {throw 'Updater did not record success'}
Write-Host 'Full swap, binary hash, metadata, handshake and backup: PASS'

# Simulate an error after the real directory swap and check automatic rollback.
$rollbackZip = Join-Path $base 'rollback-payload.zip'
Copy-Item -LiteralPath $package.FullName -Destination $rollbackZip -Force
$beforeRollback = (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $updater -Archive $rollbackZip -ExpectedSha256 $hash -ExePath $old -ParentPid 999999 -Version 0.7.2 -CITestSkipLaunch -CITestForcePostSwapFailure
if ($LASTEXITCODE -eq 0) {throw 'Forced post-swap failure was not rejected'}
if (-not (Test-Path -LiteralPath $old) -or (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ne $beforeRollback) {throw 'Rollback failed to restore previous EXE'}
if ([IO.File]::ReadAllText((Join-Path $install 'unins000.dat')) -ne 'inno-test-uninstall-metadata') {throw 'Rollback lost uninstall metadata'}
if ((Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json).state -ne 'failed') {throw 'Updater did not record post-swap failure'}
Write-Host 'Post-swap failure, failure report and automatic rollback: PASS'

# A tampered ZIP must never touch the working install.
$badZip = Join-Path $base 'tampered.zip'
[IO.File]::WriteAllText($badZip, 'not a real signed package')
$before = (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $updater -Archive $badZip -ExpectedSha256 $hash -ExePath $old -ParentPid 999999 -Version 0.7.2 -CITestSkipLaunch
if ($LASTEXITCODE -eq 0) {throw 'Tampered archive incorrectly accepted'}
if (-not (Test-Path -LiteralPath $old) -or (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ne $before) {throw 'Tampered archive changed installed Circle'}
Write-Host 'Tampered ZIP rejection and active installation preservation: PASS'

# Preserve reports in CI, not user source files.
$reportDir = Join-Path $env:RUNNER_TEMP 'circle-update-verification'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$updateLog = Join-Path $env:LOCALAPPDATA 'Circle\updates\update.log'
if (Test-Path -LiteralPath $updateLog) {
  Copy-Item -LiteralPath $updateLog -Destination (Join-Path $reportDir 'update.log') -Force
}
Write-Host 'Circle in-place updater integration test: PASS'

# Negative-path tests above intentionally run powershell.exe processes that return 1.
# GitHub Actions' pwsh wrapper propagates the last native exit code unless
# explicitly cleared, even when every assertion has passed.
$global:LASTEXITCODE = 0
exit 0
