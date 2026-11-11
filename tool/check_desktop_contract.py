#!/usr/bin/env python3
"""Static desktop/API checks; not a replacement for integration or Flutter tests."""
from pathlib import Path
import re

root=Path(__file__).resolve().parents[1]
client=(root/'lib/desktop_features.dart').read_text(encoding='utf-8')
main=(root/'lib/main.dart').read_text(encoding='utf-8')
presence=(root/'lib/social_presence.dart').read_text(encoding='utf-8')
client += presence
client += (root/'lib/desktop_discovery.dart').read_text(encoding='utf-8')
api=(root/'server_patch/api/desktop_ext.php').read_text(encoding='utf-8')
mobile=(root/'server_patch/api/mobile.php').read_text(encoding='utf-8')
required={
 'desktop-security','desktop-password-change','desktop-username-change','desktop-device-revoke',
 'desktop-totp-start','desktop-totp-enable','desktop-totp-disable',
 'desktop-community-create','desktop-community-leave','desktop-community-panel',
 'desktop-community-appearance','desktop-community-image-upload',
 'desktop-voice-channel-create','desktop-voice-channel-lock',
 'desktop-channel-create','desktop-channel-rename','desktop-channel-delete',
 'desktop-role-create','desktop-role-permissions','desktop-role-assign','desktop-member-ban',
 'desktop-invite-create','desktop-invite-revoke','desktop-automod',
 'desktop-dm-edit','desktop-dm-delete','desktop-dm-archive','desktop-dm-archives',
 'desktop-channel-edit','desktop-channel-message-delete','desktop-channel-pin','desktop-channel-report',
 'desktop-meetings','desktop-meeting-create','desktop-meeting-token',
 'desktop-trust-panel','desktop-trust-rule-add','desktop-trust-rule-toggle','desktop-trust-import','desktop-trust-review',
 'desktop-presence','desktop-presence-set','desktop-presence-ping',
 'desktop-presence-people','desktop-saved-chat','desktop-conversations',
 'desktop-message-search','desktop-community-stats',
}
for route in sorted(required):
    if f"'{route}'" not in client+main:
        raise SystemExit('Missing client use: '+route)
    if f"'{route}'" not in api:
        raise SystemExit('Missing PHP route: '+route)

# Dynamic/indirect routes must be declared explicitly on the server.
usage=set(re.findall(r"['\"](desktop-[a-z-]+)['\"]",main+client))
missing=usage-required
if missing:
    raise SystemExit('Unexpected client desktop routes: '+', '.join(sorted(missing)))

safety={
 'authenticated router':"circle_desktop_dispatch($route,$actor)" in mobile and 'mobile_auth()' in mobile,
 'upload path uses API-local helper':'desktop_store_community_image($file,$max)' in api and 'function desktop_store_community_image' in api,
 'upload membership permission':"desktop_manage($id,$uid)" in api,
 'community role escalation protected':"desktop_permission_set($perms,$valid)" in api,
 'owner transfer guard':"TRANSFER_OWNERSHIP_FIRST" in api,
 'direct messaging authorization':"mobile_dm_access($cid,$uid)" in api,
 'meeting friend validation':"FRIENDS_ONLY" in api,
 'platform moderation permission':"desktop_admin($actor)" in api,
 'self-chat membership access explicitly allows one member': 'in_array((int)$q->fetchColumn(),[1,2],true)' in mobile,
 'presence cannot show unrelated users': "f.status='ACCEPTED'" in api and 'community_members a JOIN community_members b' in api,
 'presence supports only trusted status set': "['ONLINE','IDLE','DND']" in api,
 'saved chat ownership protected': 'FOR UPDATE' in api and 'dm_members m ON m.conversation_id=d.id AND m.user_id=?' in api,
 'no embedded browser package': "import 'package:webview" not in main+client,
}
for name,ok in safety.items():
    if not ok:raise SystemExit('API security regression: '+name)
print('PASS: ',len(required),'desktop routes and static permission checks')
