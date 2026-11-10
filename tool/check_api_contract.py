#!/usr/bin/env python3
"""Static compatibility and authorization guard for Circle desktop additions.

This cannot substitute an integration test with live PHP/MySQL. It catches
missing endpoints/permissions if package files drift apart.
"""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
client = (root / 'lib/main.dart').read_text(encoding='utf8')
server = (root / 'server_patch/api/mobile.php').read_text(encoding='utf8')
required = {
    'post-edit': 'author_id',
    'post-delete': 'author_id',
    'post-repost': 'mobile_post_access',
    'post-pin': 'author_id',
    'post-comment-delete': 'user_id',
    'dm-open': 'friendships',
    'profile-cover-upload': 'is_uploaded_file',
}
for name, authorizer in required.items():
    if f"'{name}'" not in client:
        raise SystemExit(f'UI route absent: {name}')
    m = re.search(r"if\(\$route==='" + re.escape(name) + r"'\)\{(.*?)(?=\n    if\(\$route==='|\Z)", server, re.S)
    if not m:
        raise SystemExit(f'PHP API route absent: {name}')
    block = m.group(1)
    if "mobile_method('POST')" not in block or authorizer not in block:
        raise SystemExit(f'PHP route lacks POST/auth checks: {name}')
if 'mobile_post_stats_bulk' not in server or 'MAX(CASE WHEN user_id=? THEN 1 ELSE 0 END) AS mine FROM social_post_reposts' not in server:
    raise SystemExit('Reposts must be aggregated in a batch query')
if "db()->rollBack();mobile_fail('FRIENDS_ONLY',403)" not in server:
    raise SystemExit('DM opener must not leave transaction open when users are not friends')
if 'parent_comment_id=NULL WHERE parent_comment_id' not in server:
    raise SystemExit('Comment deletion must retain existing replies')
print('PASS: desktop feature routes exist and guard author/member access')
