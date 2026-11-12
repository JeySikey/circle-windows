// Pure data and routing rules for Circle desktop notifications.
// Payload values are *identifiers*, never executable URLs or arbitrary routes.
import 'dart:convert';

enum CircleNotificationDestination { conversation, post, friends, community, channel, meeting, cinema, profile, inbox }

class CircleNotificationTarget {
  const CircleNotificationTarget(this.destination, [this.id = 0, this.secondaryId = 0]);
  final CircleNotificationDestination destination;
  final int id;
  final int secondaryId;
}

int _positiveId(dynamic raw) {
  final id = raw is int ? raw : int.tryParse('$raw') ?? 0;
  return id > 0 ? id : 0;
}

Map<String, dynamic> _payload(dynamic raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  return {};
}

class CircleEvent {
  const CircleEvent({required this.id, required this.kind, required this.actor,
    required this.read, required this.payload, this.createdAt = ''});
  final int id;
  final String kind;
  final String actor;
  final bool read;
  final String createdAt;
  final Map<String, dynamic> payload;

  factory CircleEvent.fromJson(Map<String, dynamic> json) => CircleEvent(
    id: _positiveId(json['id']),
    kind: '${json['kind'] ?? ''}',
    actor: '${json['actor_name'] ?? 'Circle'}'.trim().isEmpty ? 'Circle' : '${json['actor_name']}',
    read: json['read'] == true || json['read'] == 1,
    createdAt: '${json['created_at'] ?? ''}',
    payload: _payload(json['payload']),
  );

  String get category {
    if (kind.startsWith('dm_') || kind == 'message_mention' || kind == 'voice_meeting_invite') return 'messages';
    if (kind.startsWith('friend')) return 'friends';
    if (kind.startsWith('post_') || kind == 'comment_repost') return 'posts';
    if (kind.startsWith('community_') || kind.startsWith('role_') || kind == 'everyone_mention' || kind == 'cinema_invite') return 'communities';
    if (kind.startsWith('security_')) return 'security_alerts';
    return 'system';
  }

  String get heading => switch(kind) {
    'dm_message' => 'Новое сообщение',
    'dm_group_invite' => 'Приглашение в беседу',
    'message_mention' => 'Вас упомянули',
    'friend_request' => 'Заявка в друзья',
    'friend_accepted' || 'friendship_accepted' => 'Новый друг',
    'post_comment' || 'post_reply' => 'Комментарий к записи',
    'post_like' || 'post_reaction' => 'Реакция на публикацию',
    'comment_repost' => 'Репост комментария',
    'voice_meeting_invite' => 'Приглашение во встречу',
    'cinema_invite' => 'Приглашение в кинозал',
    'security_login' => 'Новый вход в аккаунт',
    'community_banned' => 'Ограничение в сообществе',
    'role_assigned' => 'Назначение роли',
    'role_mention' || 'everyone_mention' => 'Упоминание в сообществе',
    'report_received' => 'Жалоба получена',
    _ => 'Новое событие Circle',
  };

  // Do not place private message text, post bodies, or arbitrary server HTML in a toast.
  String get summary => actor == 'Circle' ? heading : switch (category) {
    'security_alerts' => 'Проверьте безопасность аккаунта',
    'system' => heading,
    _ => '$actor · $heading',
  };

  CircleNotificationTarget get target {
    final p = payload;
    final conv = _positiveId(p['conversation_id']);
    final post = _positiveId(p['post_id']);
    final community = _positiveId(p['community_id']);
    final channel = _positiveId(p['channel_id']);
    final meeting = _positiveId(p['meeting_id']);
    final cinema = _positiveId(p['cinema_id']);
    // Follow the exact same precedence as the website's
    // circle_notification_destination(), without trusting an external URL.
    if (kind == 'cinema_invite' && cinema > 0) {
      return CircleNotificationTarget(CircleNotificationDestination.cinema, cinema);
    }
    if (post > 0 && const {'post_comment', 'post_like', 'post_reaction', 'comment_repost', 'post_reply'}.contains(kind)) {
      return CircleNotificationTarget(CircleNotificationDestination.post, post, _positiveId(p['comment_id']));
    }
    if (const {'friend_request', 'friend_accepted', 'friendship_accepted'}.contains(kind)) {
      return const CircleNotificationTarget(CircleNotificationDestination.friends);
    }
    if (conv > 0) return CircleNotificationTarget(CircleNotificationDestination.conversation, conv, _positiveId(p['message_id']));
    if (meeting > 0) return CircleNotificationTarget(CircleNotificationDestination.meeting, meeting);
    if (community > 0 && kind != 'community_banned') {
      if (channel > 0) return CircleNotificationTarget(CircleNotificationDestination.channel, channel, _positiveId(p['message_id']));
      return CircleNotificationTarget(CircleNotificationDestination.community, community);
    }
    return const CircleNotificationTarget(CircleNotificationDestination.inbox);
  }
}

/// Highest ID may advance even when user muted a category; no duplicate toasts.
List<CircleEvent> newerEvents(List<CircleEvent> events, int previous) =>
    events.where((e) => e.id > previous && !e.read).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
