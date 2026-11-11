import 'package:flutter/material.dart';
import 'api.dart';
import 'design.dart';

/// Native search UI backed by exactly the same access-scoped web search rules.
class CircleMessageSearchScreen extends StatefulWidget {
  const CircleMessageSearchScreen({super.key, required this.api,
    required this.onOpenChannel, required this.onOpenConversation});
  final CircleApi api;
  final void Function(int channelId, String channelName) onOpenChannel;
  final ValueChanged<int> onOpenConversation;
  @override State<CircleMessageSearchScreen> createState() => _CircleMessageSearchScreenState();
}
class _CircleMessageSearchScreenState extends State<CircleMessageSearchScreen> {
  final query = TextEditingController();
  final author = TextEditingController();
  final from = TextEditingController();
  final to = TextEditingController();
  Future<Map<String, dynamic>>? results;
  @override void dispose() {for(final field in [query, author, from, to]){field.dispose();}super.dispose();}
  void search() {
    final text = query.text.trim();
    if(text.length < 2) {ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Введите минимум два символа')));return;}
    setState(() => results = widget.api.call('desktop-message-search', query: {
      'q': text, 'author': author.text.trim(),
      'date_from': from.text.trim(), 'date_to': to.text.trim(),
    }));
  }
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 1060),
    child: ListView(padding: const EdgeInsets.all(24), children: [
      const CircleSection(title: 'Найди важный разговор',
        subtitle: 'Поиск по доступным тебе каналам и личным перепискам'),
      const SizedBox(height: 17),
      CircleSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: query, maxLength: 80, onSubmitted: (_) => search(),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded),
            labelText: 'Ключевые слова', hintText: 'Встреча, проект, идея...')),
        const SizedBox(height: 9),
        Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(width: 200, child: TextField(controller: author, maxLength: 24,
            decoration: const InputDecoration(labelText: 'Автор', hintText: 'Логин'))),
          SizedBox(width: 180, child: TextField(controller: from,
            decoration: const InputDecoration(labelText: 'Дата с', hintText: 'ГГГГ-ММ-ДД'))),
          SizedBox(width: 180, child: TextField(controller: to,
            decoration: const InputDecoration(labelText: 'Дата по', hintText: 'ГГГГ-ММ-ДД'))),
        ]),
        const SizedBox(height: 18),
        CircleAccentButton(label: 'Искать сообщения', icon: Icons.search_rounded,
          onPressed: search),
      ])),
      const SizedBox(height: 22),
      if (results == null) const CircleEmpty(title: 'Поиск ждёт твоего запроса',
        description: 'Используй слова, автора и диапазон дат.'),
      if (results != null) FutureBuilder<Map<String, dynamic>>(future: results,
        builder: (context, snapshot) {
          if(snapshot.hasError) return CircleEmpty(title: 'Поиск не удался',
            description: '${snapshot.error}', icon: Icons.wifi_off_outlined,
            action: CircleAccentButton(label: 'Повторить', primary: false, onPressed: search));
          if(!snapshot.hasData) return const CircleLoadingState(caption: 'Ищем в твоём круге...');
          final channels = (snapshot.data!['channels'] as List? ?? []).whereType<Map>().toList();
          final direct = (snapshot.data!['direct_messages'] as List? ?? []).whereType<Map>().toList();
          if(channels.isEmpty && direct.isEmpty) return const CircleEmpty(
            title: 'Совпадений нет', description: 'Попробуй изменить слова или фильтры.');
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleSection(title: 'Каналы', subtitle: '${channels.length} совпадений'),
            const SizedBox(height: 12),
            for (final hit in channels) Padding(padding: const EdgeInsets.only(bottom: 9),
              child: CircleSurface(interactive: true,
                onTap: () => widget.onOpenChannel(identifier(hit['channel_id']), '${hit['channel_name'] ?? ''}'),
                child: _SearchResult(icon: Icons.tag_rounded,
                  title: '${hit['community_name'] ?? ''} / #${hit['channel_name'] ?? ''}',
                  subtitle: '@${hit['username'] ?? ''} · ${circleDate(hit['created_at'])}',
                  body: '${hit['body'] ?? ''}'))),
            const SizedBox(height: 17),
            CircleSection(title: 'Личные сообщения', subtitle: '${direct.length} совпадений'),
            const SizedBox(height: 12),
            for (final hit in direct) Padding(padding: const EdgeInsets.only(bottom: 9),
              child: CircleSurface(interactive: true,
                onTap: () => widget.onOpenConversation(identifier(hit['conversation_id'])),
                child: _SearchResult(icon: Icons.chat_bubble_outline_rounded,
                  title: '@${hit['username'] ?? ''}',
                  subtitle: circleDate(hit['created_at']), body: '${hit['body'] ?? ''}'))),
          ]);
        }),
    ])));
}
class _SearchResult extends StatelessWidget {
  const _SearchResult({required this.icon, required this.title,
    required this.subtitle, required this.body});
  final IconData icon;
  final String title, subtitle, body;
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(icon, color: circleGold, size: 19),
        const SizedBox(width: 10), Expanded(child: Text(title,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium))]),
      const SizedBox(height: 6), Text(subtitle,
        style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 10), Text(body,
        maxLines: 4, overflow: TextOverflow.ellipsis),
    ]);
}

class CircleCommunityStatsScreen extends StatefulWidget {
  const CircleCommunityStatsScreen(this.api, this.communityId, {super.key});
  final CircleApi api;
  final int communityId;
  @override State<CircleCommunityStatsScreen> createState() => _CircleCommunityStatsScreenState();
}
class _CircleCommunityStatsScreenState extends State<CircleCommunityStatsScreen> {
  late Future<Map<String,dynamic>> response;
  @override void initState(){super.initState();refresh();}
  void refresh(){response=widget.api.call('desktop-community-stats',
    query:{'community_id':'${widget.communityId}'});}
  @override Widget build(BuildContext context) => FutureBuilder<Map<String,dynamic>>(
    future: response, builder: (context, snapshot) {
      if(snapshot.hasError) return CircleEmpty(title:'Статистика недоступна',
        description:'${snapshot.error}', icon:Icons.shield_outlined,
        action: CircleAccentButton(label:'Повторить', primary:false,
          onPressed:()=>setState(refresh)));
      if(!snapshot.hasData) return const CircleLoadingState(caption:'Считаем активность...');
      final summary = snapshot.data!['summary'] is Map
        ? Map<String,dynamic>.from(snapshot.data!['summary'] as Map) : <String,dynamic>{};
      final daily = (snapshot.data!['daily'] as List? ?? []).whereType<Map>().toList();
      final maxCount = daily.fold<int>(1, (current, day) {
        final total = identifier(day['total']);
        return total > current ? total : current;
      });
      return ListView(padding: const EdgeInsets.all(24), children: [
        CircleSection(title:'Пульс сообщества',
          subtitle:'${snapshot.data!['community_name'] ?? ''} · реальные показатели за последние 7 дней'),
        const SizedBox(height: 20),
        Wrap(spacing: 11, runSpacing: 11, children: [
          CircleProfileMetric(icon:Icons.people_alt_outlined,
            value:'${summary['members'] ?? 0}',label:'Участники'),
          CircleProfileMetric(icon:Icons.chat_bubble_outline_rounded,
            value:'${summary['messages'] ?? 0}',label:'Сообщения'),
          CircleProfileMetric(icon:Icons.history_rounded,
            value:'${summary['messages_week'] ?? 0}',label:'За 7 дней'),
          CircleProfileMetric(icon:Icons.person_outline_rounded,
            value:'${summary['active_week'] ?? 0}',label:'Активные авторы'),
          CircleProfileMetric(icon:Icons.person_add_alt_1_rounded,
            value:'${summary['new_members_week'] ?? 0}',label:'Новые участники'),
        ]),
        const SizedBox(height: 22),
        CircleSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Активность по дням',style:Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 17),
          if(daily.isEmpty) const Text('Сообщений пока нет.'),
          for (final day in daily) Padding(
            padding:const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              SizedBox(width: 97,child:Text('${day['day'] ?? ''}',
                style:Theme.of(context).textTheme.bodySmall)),
              Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(6),
                child:LinearProgressIndicator(
                  value:identifier(day['total']) / maxCount,
                  minHeight: 9,color:circleGold,
                  backgroundColor:circleGold.withValues(alpha:.09)))),
              const SizedBox(width: 12),
              SizedBox(width: 38,child:Text('${day['total'] ?? 0}',
                textAlign:TextAlign.end)),
            ])),
        ])),
      ]);
    });
}
