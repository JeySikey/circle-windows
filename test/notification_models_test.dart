import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/notification_models.dart';

void main() {
  test('trusted notification kinds route to the correct native screen', () {
    final cases = <(String, Map<String, dynamic>, CircleNotificationDestination, int)>[
      ('dm_message', {'conversation_id': 19}, CircleNotificationDestination.conversation, 19),
      ('dm_group_invite', {'conversation_id': '31'}, CircleNotificationDestination.conversation, 31),
      ('post_comment', {'post_id': 24}, CircleNotificationDestination.post, 24),
      ('post_reaction', {'post_id': '33'}, CircleNotificationDestination.post, 33),
      ('friend_request', {}, CircleNotificationDestination.friends, 0),
      ('role_mention', {'community_id': 9, 'channel_id': 11}, CircleNotificationDestination.channel, 11),
      ('role_assigned', {'community_id': 9}, CircleNotificationDestination.community, 9),
      ('voice_meeting_invite', {'meeting_id': 14}, CircleNotificationDestination.meeting, 14),
      ('cinema_invite', {'cinema_id': 12}, CircleNotificationDestination.cinema, 12),
      ('security_login', {}, CircleNotificationDestination.inbox, 0),
    ];
    for (final (kind, payload, destination, id) in cases) {
      final event = CircleEvent.fromJson({'id': 51, 'kind': kind, 'payload': payload});
      expect(event.target.destination, destination, reason: kind);
      expect(event.target.id, id, reason: kind);
    }
  });

  test('destination precedence equals the web notification router', () {
    final event = CircleEvent.fromJson({'id': 10, 'kind': 'post_comment',
      'payload': {'conversation_id': 19, 'post_id': 24, 'community_id': 9}});
    expect(event.target.destination, CircleNotificationDestination.post);
    expect(event.target.id, 24);
  });

  test('untrusted URLs and negative IDs cannot redirect to browser or file system', () {
    final event = CircleEvent.fromJson({'id': '5', 'kind': 'dm_message',
      'actor_name': 'Друг', 'payload': {'conversation_id': '-1', 'url': 'file:///C:/secret'}});
    expect(event.target.destination, CircleNotificationDestination.inbox);
    expect(event.target.id, 0);
    expect(event.summary, isNot(contains('file:')));
  });

  test('private message content is not included in a Windows toast', () {
    final event = CircleEvent.fromJson({'id': 33, 'kind': 'dm_message',
      'actor_name': 'Тест', 'payload': {'message': 'very-private-body', 'conversation_id': 6}});
    expect(event.summary, isNot(contains('very-private-body')));
    expect(event.target.id, 6);
  });

  test('unread items newer than cursor are sorted chronologically', () {
    final events = [
      CircleEvent.fromJson({'id': 11, 'read': false}),
      CircleEvent.fromJson({'id': 8, 'read': false}),
      CircleEvent.fromJson({'id': 12, 'read': true}),
    ];
    expect(newerEvents(events, 9).map((e) => e.id).toList(), [11]);
  });
}
