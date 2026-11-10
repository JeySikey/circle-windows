param(
  [string]$Executable = '',
  [int]$Seconds = 8,
  [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
$now = Get-Date
$directory = Join-Path $env:LOCALAPPDATA 'Circle\diagnostics'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report = Join-Path $directory 'last-launch-report.txt'
"Circle Windows launch diagnosis - $($now.ToString('yyyy-MM-dd HH:mm:ss'))" | Set-Content $report -Encoding UTF8
function Report([string]$value) { Add-Content -Path $report -Value $value -Encoding UTF8; Write-Host $value }
if (-not $Executable) {
  $Executable = Join-Path $env:LOCALAPPDATA 'Programs\Circle\circle_windows.exe'
}
Report "EXE: $Executable"
Report "Windows: $([System.Environment]::OSVersion.VersionString)"
if (-not (Test-Path $Executable)) {
  Report 'FAIL: Executable not found. Install Circle, or specify -Executable path.'
  exit 2
}
$folder = Split-Path $Executable -Parent
foreach ($dependency in @('flutter_windows.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','data\icudtl.dat','data\flutter_assets')) {
  $exists = Test-Path (Join-Path $folder $dependency)
  Report "$(if ($exists) {'OK'} else {'MISSING'}): $dependency"
}
if (-not $NoLaunch) {
  try {
    $process = Start-Process -FilePath $Executable -WorkingDirectory $folder -PassThru -ErrorAction Stop
    Start-Sleep -Seconds $Seconds
    $process.Refresh()
    if ($process.HasExited) {
      Report "FAIL: Process exited quickly. Exit code: $($process.ExitCode); hex=0x$('{0:X8}' -f ($process.ExitCode -band 0xFFFFFFFF))"
    } else {
      Report "OK: Process is alive after $Seconds seconds (PID $($process.Id))."
      Report "Window handle: $($process.MainWindowHandle)"
      if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        Report 'WARNING: Process is running, but no visible main window was found.'
      }
      Report 'Close the Circle window normally after checking whether it is visible.'
    }
  } catch {
    Report "FAIL: Windows could not launch executable. $($_.Exception.GetType().Name): $($_.Exception.Message)"
  }
}
$logFile = Join-Path $env:LOCALAPPDATA 'Circle\logs\startup.log'
if (Test-Path $logFile) {
  Report '--- Last 25 lines of Circle startup log ---'
  Get-Content $logFile -Tail 25 | ForEach-Object { Report $_ }
} else {
  Report 'No Dart startup log. If EXE never reaches Dart, check missing dependencies / Windows event log.'
}
Report '--- Windows application errors since script started (brief) ---'
try {
  Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$now.AddSeconds(-10)} -ErrorAction Stop |
    Where-Object { $_.ProviderName -in @('Application Error','Windows Error Reporting','SideBySide') } |
    Select-Object -First 8 | ForEach-Object {
      Report "Event $($_.Id) [$($_.ProviderName)] at $($_.TimeCreated)"
      # Avoid copying potentially private crash-report payloads by default.
    }
} catch { Report 'Windows Event Log is unavailable in this session.' }
Report "Report saved to: $report"
