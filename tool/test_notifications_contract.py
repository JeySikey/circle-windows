#!/usr/bin/env python3
"""Static smoke checks for 0.11 notification contracts, no database needed."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
php = (root / 'server_patch/api/mobile.php').read_text(encoding='utf-8')
service = (root / 'lib/desktop_notifications.dart').read_text(encoding='utf-8')
app = (root / 'lib/main.dart').read_text(encoding='utf-8')
model = (root / 'lib/notification_models.dart').read_text(encoding='utf-8')
checks = {
 'cursor after parameter': "$_GET['after']" in php and 'ORDER BY n.id ASC LIMIT 40' in php,
 'old before contract': "$_GET['before']" in php and 'next_before' in php,
 'notification ownership': 'WHERE n.id=? AND n.user_id=?' in php,
 'post access guard': "if($route==='post-detail')" in php and 'mobile_post_access($id,$uid)' in php,
 'native toast identity': 'WindowsNotification.registerAumid' in service,
 'native sound': 'NotificationAudio(sound:' in service,
 'click callback': 'NotificationEvent.activated' in service and 'onClick(id)' in service,
 'read notification on activation': "api.call('notification-read'" in service,
 'account scoped cursor': "api.base.host}_$userId" in service,
 'no private body in toast': 'event.summary' in service and 'event.heading' in service and 'payload[' not in service,
 'native post route': 'CirclePostDetailsScreen(client, target.id)' in app,
 'native messenger route': 'MessagesScreen(client, target.id' in app,
 'desktop message model': 'CircleNotificationDestination.conversation' in model,
 'notification service disposal': 'notificationService?.dispose()' in app,
}
for label, valid in checks.items():
    assert valid, f'FAIL: {label}'
    print(f'PASS: {label}')
