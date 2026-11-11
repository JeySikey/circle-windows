#!/usr/bin/env python3
"""Static route, authorization and parity guards; not live database tests."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
api = (root / 'server_patch/api/desktop_ext.php').read_text(encoding='utf-8')
main = (root / 'lib/main.dart').read_text(encoding='utf-8')
moderation = (root / 'lib/moderation_center.dart').read_text(encoding='utf-8')
commands = (root / 'lib/command_palette.dart').read_text(encoding='utf-8')
required = {
    'active reports': "if($route==='desktop-moderation-inbox')",
    'archive read': "if($route==='desktop-moderation-archive')",
    'report action': "if($route==='desktop-moderation-decide')",
    'user DM report': "if($route==='desktop-dm-report')",
    'platform read': "if($route==='desktop-platform-console')",
    'feature toggles': "if($route==='desktop-feature-toggle')",
}
for name, token in required.items():
    assert token in api, f'Missing API route: {name}'
for name, pattern in {
    'admin access': 'mobile_method(\'GET\');desktop_admin($actor)',
    'locking and conflict detection': 'FOR UPDATE',
    'report decision validation': "in_array($status,['REVIEWING','RESOLVED','REJECTED'],true)",
    'decision audit': "audit_event($uid,'moderation.report_status'",
    'report quota': "source_type='DM_REPORT' AND created_at>DATE_SUB(NOW(),INTERVAL 1 DAY)",
    'report membership': 'mobile_dm_access((int)$message[\'conversation_id\'],$uid)',
    'report duplication guard': "if($old->fetchColumn())mobile_fail('REPORT_ALREADY_EXISTS',409)",
    'review archive excludes open': "WHERE r.status IN ('RESOLVED','REJECTED')",
}.items():
    assert pattern in api, f'Security regression: {name}'
assert 'desktop-dm-report' in main
assert 'CircleModerationCenter(client' in main
assert 'desktop-moderation-inbox' in moderation
assert 'desktop-moderation-archive' in moderation
assert 'desktop-moderation-decide' in moderation
console = (root / 'lib/platform_console.dart').read_text(encoding='utf-8')
assert 'desktop-feature-toggle' in console and 'desktop-platform-console' in console
assert "desktop_admin($actor);$d=desktop_input()" in api
assert "SELECT feature_key FROM platform_features WHERE feature_key=? FOR UPDATE" in api
assert 'Ctrl+K' in main and 'showCircleCommandPalette' in main
assert 'showDialog<void>' in commands
print('PASS: reports/DM moderation guards + native navigation route checks')
