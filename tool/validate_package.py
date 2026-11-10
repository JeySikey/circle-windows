#!/usr/bin/env python3
"""Source package integrity checks independent of a Windows/Flutter toolchain."""
import re
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
php = Path(__file__).resolve().parents[2] / 'site' / 'api' / 'mobile.php'
required = [
    'pubspec.yaml', 'lib/main.dart', 'lib/api.dart', 'lib/design.dart',
    'lib/live_room.dart', 'lib/media_view.dart', 'lib/updater.dart',
    'lib/startup_log.dart', 'tool/package_windows.ps1', 'tool/verify_installer.ps1', 'tool/diagnose_windows.ps1',
    'tool/apply_update.ps1', 'tool/build_payload.py', 'tool/release_keys.py',
    'tool/self_test_update.py', 'tool/test_bootstrap_keys.py', 'tool/bootstrap_github_keys.py',
    'tool/validate_package.py', 'tool/sign_release.py', 'tool/package_windows.ps1',
    'tool/verify_installer.ps1', 'tool/diagnose_windows.ps1', 'tool/Circle-Diagnostics.cmd',
    'docs/GITHUB-AUTO-UPDATE.md',
    '.github/workflows/windows.yml', '.github/workflows/bootstrap-signing.yml', 'installer/Circle.iss',
    'assets/circle-mark.png', 'branding/circle.ico', 'README.md',
]
for rel in required:
    if not (root / rel).is_file():
        raise SystemExit(f'Missing required file: {rel}')

version = '0.5.1'
for rel in ['pubspec.yaml', 'lib/main.dart', 'installer/Circle.iss', 'build-installer.ps1', '.github/workflows/windows.yml']:
    if version not in (root / rel).read_text(encoding='utf-8'):
        raise SystemExit(f'Wrong version: {rel}')

# Regression checks for the exact analyzer errors reported in 0.4.0.
main_source = (root / 'lib/main.dart').read_text(encoding='utf-8')
design_source = (root / 'lib/design.dart').read_text(encoding='utf-8')
if "import 'dart:typed_data';" in main_source:
    raise SystemExit('Regression: unused dart:typed_data import breaks flutter analyze')
if 'CircleAvatar(' in main_source or 'class CircleAvatar' in design_source:
    raise SystemExit('Widget name still collides with Flutter Material CircleAvatar')
if 'class CircleUserAvatar extends StatefulWidget' not in design_source:
    raise SystemExit('Missing renamed avatar widget')
if 'errorBuilder: (_, _, _)' in design_source:
    raise SystemExit('Duplicate wildcard arguments in errorBuilder')
if 'runApp(const CircleApp());' not in main_source:
    raise SystemExit('Startup regression: main() must render the app without blocking plugins')
if 'MediaKit.ensureInitialized();' in main_source:
    raise SystemExit('Startup regression: native codecs cannot block runApp')
if 'try {' not in main_source[main_source.index('Future<void> restore() async {'):main_source.index('Future<void> login(')]:
    raise SystemExit('Startup regression: restoring the session must catch plugin failures')
if php.exists():
    mobile = php.read_text(encoding='utf-8')
    routes = set(re.findall(r"(?:call|upload|media)\('([a-z][a-z0-9-]+)'", (root / 'lib/main.dart').read_text(encoding='utf-8')))
    for route in sorted(routes):
        if f"'{route}'" not in mobile:
            print(f'WARNING: API route not found in PHP source: {route}')

# The installer regression guard is inline so GitHub uploads missing the optional
# tool/test_installer_ci.py cannot cause a misleading 'file not found' failure.
workflow_source = (root / '.github/workflows/windows.yml').read_text(encoding='utf-8')
installer_source = (root / 'tool/verify_installer.ps1').read_text(encoding='utf-8')
installer_checks = {
    'installer verification step': 'run: ./tool/verify_installer.ps1' in workflow_source,
    'diagnostics artifact': 'Circle-Installer-Diagnostics' in workflow_source,
    'wait for Inno GUI installer': 'Start-Process -FilePath $installer.FullName -ArgumentList $arguments -Wait -PassThru' in installer_source,
    'real process exit code': '$process.ExitCode' in installer_source,
    'installer log on failure': 'Get-Content -LiteralPath $logFile -Tail' in installer_source,
    'check release runtime': 'Assert-Runtime $ReleaseDirectory' in installer_source,
    'check installed runtime': 'Assert-Runtime $InstallationDirectory' in installer_source,
    'do not invoke installer without wait': '& $installer.FullName' not in workflow_source,
    'self-contained CI validation': 'python tool/test_installer_ci.py' not in workflow_source,
}
for description, ok in installer_checks.items():
    if not ok:
        raise SystemExit(f'Installer regression: {description}')

# Fail fast with a precise missing-file error when a partial GitHub upload
# drops one of the build's Python/PowerShell scripts.
for rel in sorted(set(re.findall(r'\bpython\s+(tool/[A-Za-z0-9_/-]+\.py)', workflow_source)
                      + re.findall(r'(?<![A-Za-z0-9_])\./(tool/[A-Za-z0-9_/-]+\.ps1)', workflow_source))):
    if not (root / rel).is_file():
        raise SystemExit(f'Missing GitHub Actions dependency: {rel}. Re-upload tool/ folder.')
print('Installer regression and workflow script dependencies: PASS')

zip_path = root.parent / f'Circle_Windows_Native_{version}_FIXED_GitHub.zip'
if zip_path.is_file():
    with zipfile.ZipFile(zip_path) as archive:
        if archive.testzip() is not None:
            raise SystemExit('Archive integrity failure')
    print(f'Source package structure, version and ZIP integrity: OK ({version})')
else:
    print(f'Source package structure and version: OK ({version}); ZIP not present, skipped integrity check')
