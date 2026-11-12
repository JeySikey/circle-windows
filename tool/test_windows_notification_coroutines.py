#!/usr/bin/env python3
"""CI regression test: the workaround is idempotent, safe, and inherited by plugins."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

module_path = Path(__file__).with_name('enable_windows_notification_coroutines.py')
spec = importlib.util.spec_from_file_location('circle_notification_cmake', module_path)
assert spec and spec.loader
fix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fix)

CMAKE = '''cmake_minimum_required(VERSION 3.14)
project(circle_build_test LANGUAGES CXX)
set(MSVC TRUE) # Simulate MSVC when running this test on Linux.
include(flutter/generated_plugins.cmake)
'''

class CoroutineCmakeTests(unittest.TestCase):
    def test_idempotent(self):
        fixed = fix.patch_cmake(CMAKE)
        self.assertEqual(fixed, fix.patch_cmake(fixed))
        self.assertLess(fixed.index(fix.DEFINE), fixed.index(fix.ANCHOR))
        self.assertIn('if(MSVC)', fixed)

    def test_preserves_windows_crlf(self):
        before = CMAKE.replace('\n', '\r\n')
        fixed = fix.patch_cmake(before)
        self.assertNotIn('\n', fixed.replace('\r\n', ''))
        self.assertEqual(fixed, fix.patch_cmake(fixed))

    def test_missing_plugin_include_fails(self):
        with self.assertRaises(ValueError):
            fix.patch_cmake('project(x)')

    def test_too_late_definition_fails(self):
        with self.assertRaises(ValueError):
            fix.patch_cmake(CMAKE + fix.BLOCK)

    @unittest.skipUnless(shutil.which('cmake'), 'CMake unavailable')
    def test_fake_plugin_inherits_macro(self):
        with tempfile.TemporaryDirectory(prefix='circle-cmake-') as temp:
            root = Path(temp)
            (root / 'flutter').mkdir()
            (root / 'plugin').mkdir()
            (root / 'CMakeLists.txt').write_text(fix.patch_cmake(CMAKE), encoding='utf-8')
            (root / 'flutter/generated_plugins.cmake').write_text('add_subdirectory(plugin)\n', encoding='utf-8')
            (root / 'plugin/CMakeLists.txt').write_text(
                'add_library(circle_notification_plugin STATIC plugin.cpp)\n'
                'get_directory_property(circle_defs COMPILE_DEFINITIONS)\n'
                'file(WRITE \"${CMAKE_BINARY_DIR}/plugin-defs.txt\" \"${circle_defs}\")\n',
                encoding='utf-8')
            (root / 'plugin/plugin.cpp').write_text('void f() {}\n', encoding='utf-8')
            result = subprocess.run(['cmake', '-S', str(root), '-B', str(root / 'build')], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            plugin_defs = (root / 'build/plugin-defs.txt').read_text(encoding='utf-8')
            self.assertIn(fix.DEFINE, plugin_defs)

if __name__ == '__main__':
    unittest.main(verbosity=2)
