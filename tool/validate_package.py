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
    'lib/startup_log.dart', 'tool/package_windows.ps1', 'tool/diagnose_windows.ps1', 'tool/verify_installer.ps1',
    '.github/workflows/windows.yml', 'installer/Circle.iss',
    'assets/circle-mark.png', 'branding/circle.ico', 'README.md',
]
for rel in required:
    if not (root / rel).is_file():
        raise SystemExit(f'Missing required file: {rel}')

version = '0.4.2'
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
# Regression checks for the Windows installer validation step. Inno Setup is a
# GUI process: use a waited Process object; $LASTEXITCODE can remain null.
ci = (root / '.github/workflows/windows.yml').read_text(encoding='utf-8')
verify = (root / 'tool/verify_installer.ps1').read_text(encoding='utf-8')
if 'run: ./tool/verify_installer.ps1' not in ci:
    raise SystemExit('CI must run the installer validation script')
if not all(part in verify for part in ('Start-Process', '-Wait', '-PassThru', '$proc.ExitCode', 'circle-install-verification.txt')):
    raise SystemExit('Installer verification must wait for the GUI process and record its exit code')
if 'run: |\n          $installer = Get-ChildItem dist/*.exe' in ci:
    raise SystemExit('Regression: direct GUI invocation with $LASTEXITCODE is unreliable')
if php.exists():
    mobile = php.read_text(encoding='utf-8')
    routes = set(re.findall(r"(?:call|upload|media)\('([a-z][a-z0-9-]+)'", (root / 'lib/main.dart').read_text(encoding='utf-8')))
    for route in sorted(routes):
        if f"'{route}'" not in mobile:
            print(f'WARNING: API route not found in PHP source: {route}')

zip_path = root.parent / f'Circle_Windows_Native_{version}_FIXED_GitHub.zip'
if zip_path.is_file():
    with zipfile.ZipFile(zip_path) as archive:
        if archive.testzip() is not None:
            raise SystemExit('Archive integrity failure')
    print(f'Source package structure, version and ZIP integrity: OK ({version})')
else:
    print(f'Source package structure and version: OK ({version}); ZIP not present, skipped integrity check')
