#!/usr/bin/env python3
"""Non-Windows offline tests for the signed update delivery chain.

The PowerShell binary swap itself is tested by GitHub's Windows CI and by a
real installation; this script validates ZIP construction and Ed25519 protocol.
"""
from __future__ import annotations
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from zipfile import ZipFile

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[1]
PY = sys.executable


def run(*args: str) -> str:
    return subprocess.check_output([PY, *args], cwd=ROOT, text=True)


def test_roundtrip() -> None:
    with tempfile.TemporaryDirectory(prefix='circle-release-test-') as tmp:
        directory = Path(tmp)
        release = directory / 'Release'
        (release / 'tools').mkdir(parents=True)
        (release / 'data' / 'flutter_assets').mkdir(parents=True)
        for relative in ('circle_windows.exe','flutter_windows.dll','data/icudtl.dat','data/flutter_assets/AssetManifest.bin'):
            target = release / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'Circle Windows offline package test')
        (release / 'tools' / 'apply_update.ps1').write_bytes((ROOT / 'tool' / 'apply_update.ps1').read_bytes())
        out = directory / 'dist'
        run('tool/build_payload.py', '--release-dir', str(release), '--version', '0.5.1', '--output-dir', str(out))
        zippath = out / 'Circle_Windows_0.5.1_Payload.zip'
        with ZipFile(zippath) as z:
            assert z.testzip() is None
            assert 'tools/apply_update.ps1' in z.namelist()
            assert 'data/flutter_assets/AssetManifest.bin' in z.namelist()
            assert len(z.namelist()) == len(set(z.namelist()))
        keyfile = directory / 'private.pem'
        output = run('tool/release_keys.py', '--generate', '--private-key', str(keyfile))
        assert 'PUBLIC_KEY_BASE64=' in output
        assert keyfile.is_file()
        signature_file = directory / 'manifest.json'
        download_url = 'https://github.com/circle-org/circle-windows/releases/download/v0.5.1/Circle_Windows_0.5.1_Payload.zip'
        run('tool/sign_release.py', '--private-key', str(keyfile), '--package', str(zippath),
            '--version', '0.5.1', '--url', download_url, '--output', str(signature_file))
        envelope = json.loads(signature_file.read_text())
        payload = base64.b64decode(envelope['payload'])
        sig = base64.b64decode(envelope['signature'])
        pub = serialization.load_pem_private_key(keyfile.read_bytes(), password=None).public_key()
        assert isinstance(serialization.load_pem_private_key(keyfile.read_bytes(), password=None), Ed25519PrivateKey)
        pub.verify(sig, payload)
        body = json.loads(payload)
        assert body['version'] == '0.5.1'
        assert body['download_url'] == download_url
        assert body['sha256'] == hashlib.sha256(zippath.read_bytes()).hexdigest()
        try:
            pub.verify(sig, payload + b'.')
        except Exception:
            pass
        else:
            raise AssertionError('tampered signed payload was accepted')
        assert 'PRIVATE KEY' not in str(envelope)
        print('PASS: runtime ZIP CRC, payload layout, Ed25519 signature, tamper rejection, SHA-256')


if __name__ == '__main__':
    test_roundtrip()
