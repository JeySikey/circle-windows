#!/usr/bin/env python3
"""Deterministic full Windows runtime ZIP for in-place upgrades.

Packages the compiled Flutter Release directory; user files and credentials are
not contained here. Directory swap replaces app binaries, not an installer.
"""
import argparse
import hashlib
import shutil
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

parser = argparse.ArgumentParser()
parser.add_argument('--release-dir', default='build/windows/x64/runner/Release')
parser.add_argument('--version', required=True)
parser.add_argument('--output-dir', default='dist')
a = parser.parse_args()
source = Path(a.release_dir).resolve()
assert source.is_dir(), f'Release dir missing: {source}'
for required in ['circle_windows.exe', 'flutter_windows.dll', 'data/icudtl.dat', 'tools/apply_update.ps1']:
    if not (source / required).is_file():
        raise SystemExit(f'Missing update payload file: {required}')
if not (source / 'data/flutter_assets').is_dir():
    raise SystemExit('Missing Flutter assets')
name = f'Circle_Windows_{a.version}_Payload.zip'
output = Path(a.output_dir).resolve()
output.mkdir(exist_ok=True, parents=True)
target = output / name
with ZipFile(target, 'w', compression=ZIP_DEFLATED, compresslevel=6) as z:
    for file in sorted(source.rglob('*')):
        if not file.is_file():
            continue
        rel = file.relative_to(source).as_posix()
        if rel.startswith('../') or ':' in rel or '\\' in rel:
            raise SystemExit('Illegal payload path: ' + rel)
        stat = file.stat()
        if stat.st_size > 512 * 1024 * 1024:
            raise SystemExit('Individual payload file too large: ' + rel)
        info = ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with file.open('rb') as src, z.open(info, 'w') as dst:
            shutil.copyfileobj(src, dst, length=1024 * 1024)
with ZipFile(target) as z:
    if z.testzip() is not None: raise SystemExit('Payload ZIP CRC error')
    print('Payload files:', len(z.namelist()))
print('Payload:', target)
with target.open('rb') as f:
    print('SHA-256:', hashlib.file_digest(f, 'sha256').hexdigest())
