#!/usr/bin/env python3
"""One-time GitHub Actions bootstrap: generate Ed25519 signing key in memory.

Requires a short-lived fine-grained PAT (GH_TOKEN) limited to this repository
with repository Secrets read/write. Never prints or uploads private material to
logs/artifacts/repo. Persists only in GitHub Actions encrypted repository secret.
"""

import argparse
import base64
import json
import os
import re
import subprocess
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

SECRET_NAME = 'CIRCLE_UPDATE_PRIVATE_KEY_PEM'


def run_gh(args, *, secret_input=None):
    try:
        proc = subprocess.run(['gh', *args], input=secret_input, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=False, timeout=40)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError('GitHub CLI failed or timed out (no secret printed)') from None
    if proc.returncode != 0:
        # Do not echo stderr, which can contain untrusted text. Report exit only.
        raise RuntimeError(f'GitHub CLI failed (exit {proc.returncode}); verify token Secrets read/write permission')
    return proc.stdout


def secret_names(repository):
    raw = run_gh(['secret', 'list', '--app', 'actions', '--repo', repository, '--json', 'name'])
    try:
        return {item['name'] for item in json.loads(raw)}
    except (ValueError, KeyError, TypeError):
        raise RuntimeError('Unexpected GitHub CLI secret list format') from None


def bootstrap(repository):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or '..' in repository:
        raise ValueError('Expected owner/repository')
    if not os.environ.get('GH_TOKEN'):
        raise RuntimeError('Missing temporary CIRCLE_BOOTSTRAP_TOKEN credential')
    if SECRET_NAME in secret_names(repository):
        print('Signing key already exists in repository secrets. Rotation blocked; no changes made.')
        return False

    key = Ed25519PrivateKey.generate()
    private_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode('ascii')
    public = base64.b64encode(key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )).decode('ascii')
    # gh CLI uses GitHub's repository public key to encrypt secret before upload.
    # The actual private PEM never passes through command line argv, stdout or files.
    run_gh(['secret', 'set', SECRET_NAME, '--app', 'actions', '--repo', repository],
           secret_input=private_pem)
    if SECRET_NAME not in secret_names(repository):
        raise RuntimeError('Signing key persistence could not be verified')
    print('GitHub Actions signing secret created. No private key was printed.')
    print('PUBLIC_KEY_BASE64=' + public)
    summary_path = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary_path:
        with open(summary_path, 'a', encoding='utf-8') as summary:
            summary.write('## Circle release signing key configured\n\n'
                          'Private Ed25519 key is stored only in GitHub Actions repository secret '
                          f'`{SECRET_NAME}`.\n\n'
                          f'Public key (safe to disclose): `{public}`\n\n'
                          '**Next:** delete/revoke the temporary PAT, remove '
                          '`CIRCLE_BOOTSTRAP_TOKEN` from repository secrets, then run '
                          '`Circle Windows build` again.\n\n'
                          '**Do not rotate this key** while old Circle clients are deployed.\n')
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', required=True)
    args = parser.parse_args()
    try:
        bootstrap(args.repository)
    except (RuntimeError, ValueError) as error:
        parser.exit(1, f'Error: {error}\n')
