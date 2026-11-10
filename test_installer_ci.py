#!/usr/bin/env python3
"""Regression guard for the Inno Setup GUI invocation in Windows CI."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
workflow = (root / '.github/workflows/windows.yml').read_text(encoding='utf-8')
script = (root / 'tool/verify_installer.ps1').read_text(encoding='utf-8')
assert 'run: ./tool/verify_installer.ps1' in workflow
assert 'Circle-Installer-Diagnostics' in workflow
assert 'Start-Process -FilePath $installer.FullName -ArgumentList $arguments -Wait -PassThru' in script
assert '$process.ExitCode' in script
assert 'Get-Content -LiteralPath $logFile -Tail' in script
assert 'Assert-Runtime $ReleaseDirectory' in script
assert 'Assert-Runtime $InstallationDirectory' in script
assert '& $installer.FullName' not in workflow
print('Installer CI regression checks: PASS')
