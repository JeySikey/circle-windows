#!/usr/bin/env python3
"""Generate or derive the public Ed25519 update key, without printing private data."""
import argparse
import base64
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

p = argparse.ArgumentParser()
p.add_argument('--generate', action='store_true')
p.add_argument('--private-key', default='circle-update-private.pem')
a = p.parse_args()
path = Path(a.private_key)
if a.generate:
    if path.exists(): p.error('Will not overwrite signing key')
    private = Ed25519PrivateKey.generate()
    path.write_bytes(private.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    try: path.chmod(0o600)
    except OSError: pass
else:
    private = serialization.load_pem_private_key(path.read_bytes(), password=None)
    if not isinstance(private, Ed25519PrivateKey): p.error('Expected Ed25519 PEM')
public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
print('PUBLIC_KEY_BASE64=' + base64.b64encode(public).decode())
if a.generate:
    print('Private PEM stored locally at:', path, '(store as GitHub Actions secret)')
