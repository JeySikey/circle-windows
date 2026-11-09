#!/usr/bin/env python3
"""Offline signing tool. KEEP THE PRIVATE KEY OUTSIDE THE DISTRIBUTION AND WEB ROOT."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

p = argparse.ArgumentParser()
p.add_argument('--generate-key', action='store_true')
p.add_argument('--private-key', default='release-private-key.pem')
p.add_argument('--package')
p.add_argument('--version')
p.add_argument('--url')
p.add_argument('--output', default='update-manifest.json')
a = p.parse_args()
if a.generate_key:
    target = Path(a.private_key)
    if target.exists():
        p.error('Refusing to overwrite an existing signing key')
    key = Ed25519PrivateKey.generate()
    target.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    try: target.chmod(0o600)
    except OSError: pass
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    print('PUBLIC_KEY_BASE64=' + base64.b64encode(public).decode())
else:
    if not (a.package and a.version and a.url): p.error('--package, --version and --url required')
    if not a.url.startswith('https://'): p.error('A HTTPS package URL is required')
    package = Path(a.package)
    key = serialization.load_pem_private_key(Path(a.private_key).read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey): p.error('Key must be Ed25519')
    payload = json.dumps({'version': a.version, 'download_url': a.url,
      'sha256': hashlib.file_digest(package.open('rb'), 'sha256').hexdigest()},
      separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    envelope = {'payload': base64.b64encode(payload).decode(),
       'signature': base64.b64encode(key.sign(payload)).decode()}
    Path(a.output).write_text(json.dumps(envelope, indent=2) + '\n', encoding='utf-8')
    print('Signed manifest:', a.output)
