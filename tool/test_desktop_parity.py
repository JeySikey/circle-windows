#!/usr/bin/env python3
"""Static safety regressions for 0.8.0 desktop parity; not live DB tests."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
api=(root/'server_patch/api/desktop_ext.php').read_text(encoding='utf8')
mobile=(root/'server_patch/api/mobile.php').read_text(encoding='utf8')
main=(root/'lib/main.dart').read_text(encoding='utf8')
design=(root/'lib/design.dart').read_text(encoding='utf8')
presence=(root/'lib/social_presence.dart').read_text(encoding='utf8')
discovery=(root/'lib/desktop_discovery.dart').read_text(encoding='utf8')
checks={
 'desktop router authenticated': "circle_desktop_dispatch($route,$actor)" in mobile and 'mobile_auth()' in mobile,
 'saved route POST only': "if($route==='desktop-saved-chat'){\n        desktop_feature('direct-messages');mobile_method('POST')" in api,
 'saved room membership validated': 'in_array((int)$q->fetchColumn(),[1,2],true)' in mobile,
 'presence friends or shared groups': "f.status='ACCEPTED'" in api and 'community_members a JOIN community_members b' in api,
 'presence never accepts OFFLINE as writable': "in_array($status,['ONLINE','IDLE','DND'],true)" in api,
 'presence heartbeat does not overwrite DND': 'ON DUPLICATE KEY UPDATE last_seen_at=NOW()' in api,
 'client favorites API wired': "'desktop-saved-chat'" in main and "'desktop-conversations'" in main,
 'native presence UI wired': "'desktop-presence-people'" in presence and 'CirclePeopleOnlineScreen' in main,
 'brand motion and reduced motion': 'class CircleAccentButton' in design and 'disableAnimations' in design,
 'modern adaptive feed': 'SliverList.builder' in main and 'CustomScrollView' in main,
 'offscreen rendering paused': 'TickerMode(' in main and 'RepaintBoundary(' in main,
 'private chat search scoped to member': 'JOIN dm_members mine ON mine.conversation_id=m.conversation_id AND mine.user_id=?' in api,
 'community search scoped to member': 'JOIN community_members cm ON cm.community_id=c.id AND cm.user_id=?' in api,
 'community stats permission': "desktop_member($community,$uid)" in api and "'desktop-community-stats'" in discovery,
 'search route available natively': "'desktop-message-search'" in discovery and 'CircleMessageSearchScreen' in main,
 'no WebView': 'package:webview' not in main+design+presence+discovery,
}
for name, ok in checks.items():
    if not ok: raise SystemExit('FAIL: '+name)
print(f'PASS: {len(checks)} desktop feature/UI/security regression guards')
