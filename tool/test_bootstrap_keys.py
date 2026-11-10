#!/usr/bin/env python3
"""Offline tests for Actions signing-key bootstrap: do not contact GitHub."""
import base64
import os
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bootstrap_github_keys as bootstrap


class TestBootstrap(unittest.TestCase):
    def test_creates_pem_secret_in_stdin_not_in_command_line(self):
        call_history = []
        stored = {'present': False}
        def fake_run(args, *, secret_input=None):
            call_history.append((args, secret_input))
            if args[:2] == ['secret','list']:
                return '[{"name":"CIRCLE_UPDATE_PRIVATE_KEY_PEM"}]' if stored['present'] else '[]'
            if args[:2] == ['secret','set']:
                private = serialization.load_pem_private_key(secret_input.encode(), password=None)
                self.assertIsInstance(private, Ed25519PrivateKey)
                self.assertFalse('PRIVATE KEY' in ' '.join(args))
                stored['present'] = True
                return ''
            self.fail(f'Unexpected CLI call {args}')
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)/'summary.md'
            with patch.dict(os.environ, {'GH_TOKEN':'fake_pat_for_test','GITHUB_STEP_SUMMARY': str(out)}), \
                 patch.object(bootstrap,'run_gh',side_effect=fake_run):
                self.assertTrue(bootstrap.bootstrap('owner/circle-windows'))
                self.assertFalse(bootstrap.bootstrap('owner/circle-windows'))
            self.assertEqual(len([c for c in call_history if c[0][:2] == ['secret','set']]), 1)
            content=out.read_text()
            self.assertIn('Public key',content)
            self.assertNotIn('PRIVATE KEY',content)

    def test_invalid_repos_blocked(self):
        with patch.dict(os.environ, {'GH_TOKEN':'fake'}):
            with self.assertRaises(ValueError):
                bootstrap.bootstrap('../other')
            with self.assertRaises(ValueError):
                bootstrap.bootstrap('owner/repo/extra')

    def test_no_pat_fails(self):
        with patch.dict(os.environ, {'GH_TOKEN':''}):
            with self.assertRaises(RuntimeError):
                bootstrap.bootstrap('owner/repo')


if __name__=='__main__':
    unittest.main()
