#!/usr/bin/env python3
"""Add a Visual Studio 2026 compatibility definition to generated Windows CMake.

Usage: python tool/enable_windows_notification_coroutines.py

Flutter regenerates windows/CMakeLists.txt via `flutter create`. We patch that
*generated* file after flutter pub get and before flutter build, rather than
editing files in pub cache or disabling native toast notifications.
"""

from __future__ import annotations

import argparse
from pathlib import Path

ANCHOR = 'include(flutter/generated_plugins.cmake)'
DEFINE = '_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'
BLOCK = '''# Circle / Visual Studio 2026 STL1011 compatibility for native notification plugins.
# Remove when every dependency uses standard C++20 coroutine headers.
if(MSVC)
  add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
endif()
'''


def patch_cmake(content: str) -> str:
    if content.count(ANCHOR) != 1:
        raise ValueError('Expected exactly one Flutter plugin include in windows/CMakeLists.txt')
    include_pos = content.index(ANCHOR)
    if DEFINE in content[:include_pos]:
        return content  # Already configured; idempotent.
    if DEFINE in content[include_pos:]:
        raise ValueError('Existing STL1011 definition occurs too late (after plugin include)')
    line_ending = '\r\n' if '\r\n' in content else '\n'
    return content.replace(ANCHOR, BLOCK.replace('\n', line_ending) + line_ending + ANCHOR, 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cmake', type=Path, default=Path('windows/CMakeLists.txt'))
    parser.add_argument('--check', action='store_true', help='Check whether the fix is present; do not edit')
    args = parser.parse_args()
    try:
        with args.cmake.open('r', encoding='utf-8', newline='') as handle:
            before = handle.read()
        after = patch_cmake(before)
        if args.check:
            if before != after:
                raise ValueError('Missing or misplaced STL1011 workaround')
            print('PASS: Windows plugin CMake defines MSVC coroutine compatibility')
            return 0
        if before != after:
            with args.cmake.open('w', encoding='utf-8', newline='') as handle:
                handle.write(after)
            print(f'Patched {args.cmake}: added STL1011 MSVC definition before Flutter plugin inclusion')
        else:
            print(f'Already patched: {args.cmake}')
        return 0
    except (OSError, ValueError) as error:
        parser.exit(1, f'Circle CMake fix failed: {error}\n')


if __name__ == '__main__':
    raise SystemExit(main())
