#!/usr/bin/env python3
"""Fail-safe GitHub stable release decision for Circle Windows.

GitHub Actions artifacts are not releases. This tool publishes a stable release
on a successful default-branch build only for a strictly newer semver.
Do not treat API failures, private repositories, or a conflicting tag as 'no update'.
"""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

_VERSION = re.compile(r'^(?:v)?(\d+)\.(\d+)\.(\d+)$')


def parsed_version(value: str) -> tuple[int, int, int]:
    match = _VERSION.fullmatch(value)
    if not match:
        raise ValueError(f'Unsupported release version: {value!r}')
    return tuple(map(int, match.groups()))


def decide_release(version: str, ref: str, latest: str | None, tag_exists: bool) -> tuple[bool, str, str]:
    parsed = parsed_version(version)
    tag = f'v{version}'
    if ref.startswith('refs/tags/'):
        if ref != f'refs/tags/{tag}':
            raise ValueError(f'Git tag {ref!r} does not match source version {tag}')
    elif ref not in ('refs/heads/main', 'refs/heads/master'):
        raise ValueError(f'Only the main/master branch or {tag} can publish an update (got {ref!r})')
    if latest is not None:
        published = parsed_version(latest)
        if published > parsed:
            raise ValueError(f'Source version {version} is older than latest published release {latest}. Bump version.')
        if published == parsed:
            return False, tag, f'{tag} already published; increment version for a new update'
    if tag_exists and not ref.startswith('refs/tags/'):
        raise ValueError(f'Tag {tag} already exists but is not the latest published release. Do not reuse a version; bump it.')
    return True, tag, f'Publish {tag} because it is newer than {latest or "no stable release"}'


def github_json(url: str, token: str, allow_404: bool = False):
    request = Request(url, headers={
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Circle-Windows-Release-CI',
    })
    try:
        with urlopen(request, timeout=20) as response:
            return json.load(response)
    except HTTPError as exc:
        if allow_404 and exc.code == 404:
            return None
        raise RuntimeError(f'GitHub API returned HTTP {exc.code} for {url}') from exc
    except (URLError, TimeoutError) as exc:
        raise RuntimeError(f'Cannot reach GitHub API: {exc}') from exc


def run(version: str) -> None:
    repository = os.environ.get('GITHUB_REPOSITORY', '')
    token = os.environ.get('GH_TOKEN', '')
    ref = os.environ.get('GITHUB_REF', '')
    output = os.environ.get('GITHUB_OUTPUT', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or '..' in repository:
        raise ValueError('GITHUB_REPOSITORY must be OWNER/REPO')
    if not token or not output:
        raise ValueError('Missing GH_TOKEN or GITHUB_OUTPUT in GitHub Actions')
    base = f'https://api.github.com/repos/{repository}'
    meta = github_json(base, token)
    if meta.get('private', True):
        raise ValueError('GitHub repository is private: installed clients cannot download unauthenticated Releases. Publish the update feed in a public repository.')
    latest = github_json(base + '/releases/latest', token, allow_404=True)
    latest_tag = latest['tag_name'] if latest is not None else None
    tag = 'v' + version
    existing_tag = github_json(base + '/git/ref/tags/' + tag, token, allow_404=True)
    publish, tag, message = decide_release(version, ref, latest_tag, existing_tag is not None)
    with Path(output).open('a', encoding='utf-8') as file:
        file.write(f'publish={str(publish).lower()}\n')
        file.write(f'tag={tag}\n')
    print('Circle release decision:', message)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    run(args.version)
