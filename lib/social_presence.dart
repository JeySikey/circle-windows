import 'package:flutter/material.dart';
import 'api.dart';
import 'design.dart';

const circlePresenceLabels = <String, String>{
  'ONLINE': 'В сети',
  'IDLE': 'Отошёл',
  'DND': 'Не беспокоить',
  'OFFLINE': 'Не в сети',
};

Color circlePresenceColor(String status) => switch (status) {
  'ONLINE' => circleGreen,
  'IDLE' => circleGoldBright,
  'DND' => circleRed,
  _ => circleMuted,
};

class CirclePresenceIndicator extends StatelessWidget {
  const CirclePresenceIndicator({super.key, required this.status, this.showText = false});
  final String status;
  final bool showText;
  @override Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle,
      color: circlePresenceColor(status), boxShadow: [BoxShadow(
        color: circlePresenceColor(status).withValues(alpha: .32), blurRadius: 9)])),
    if (showText) ...[
      const SizedBox(width: 8), Text(circlePresenceLabels[status] ?? 'Не в сети',
        style: Theme.of(context).textTheme.bodySmall),
    ],
  ]);
}

class CirclePeopleOnlineScreen extends StatefulWidget {
  const CirclePeopleOnlineScreen(this.api, {super.key, this.onOpenUser});
  final CircleApi api;
  final ValueChanged<int>? onOpenUser;
  @override State<CirclePeopleOnlineScreen> createState() => _CirclePeopleOnlineScreenState();
}

class _CirclePeopleOnlineScreenState extends State<CirclePeopleOnlineScreen> {
  late Future<List<Map<String, dynamic>>> future;
  bool onlyOnline = true;
  @override void initState() {super.initState(); refresh();}
  void refresh() {future = widget.api.call('desktop-presence-people').then(items);}
  @override Widget build(BuildContext context) {
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 920),
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          child: CircleSection(title: 'Люди в твоём круге',
            subtitle: 'Друзья и участники общих сообществ', trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              FilterChip(label: const Text('Только в сети'), selected: onlyOnline,
                onSelected: (value) => setState(() => onlyOnline = value)),
              const SizedBox(width: 8), IconButton(tooltip: 'Обновить список',
                onPressed: () => setState(refresh), icon: const Icon(Icons.refresh_rounded)),
            ]))),
        Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) return CircleEmpty(title: 'Не удалось получить статусы',
              description: '${snapshot.error}', icon: Icons.wifi_off_outlined,
              action: CircleAccentButton(label: 'Повторить', primary: false,
                onPressed: () => setState(refresh)));
            if (!snapshot.hasData) return const CircleLoadingState(caption: 'Проверяем, кто на связи...');
            final people = snapshot.data!.where((person) =>
              !onlyOnline || '${person['status']}' != 'OFFLINE').toList();
            if (people.isEmpty) return const CircleEmpty(title: 'Сейчас все заняты',
              description: 'Попробуй показать всех участников или вернись позже.',
              icon: Icons.people_outline_rounded);
            return ListView.builder(padding: const EdgeInsets.fromLTRB(24, 0, 24, 26),
              itemCount: people.length, cacheExtent: 300,
              itemBuilder: (context, index) {
                final person = people[index];
                final status = '${person['status'] ?? 'OFFLINE'}';
                final id = identifier(person['id']);
                return Padding(padding: const EdgeInsets.only(bottom: 10), child: CircleSurface(
                  interactive: widget.onOpenUser != null,
                  onTap: id > 0 ? () => widget.onOpenUser?.call(id) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                  child: Row(children: [
                    CircleUserAvatar(api: widget.api, user: person, radius: 24),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label(person), maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 5), Text('@${person['username'] ?? ''}',
                        style: Theme.of(context).textTheme.bodySmall),
                    ])),
                    CirclePresenceIndicator(status: status, showText: true),
                    const SizedBox(width: 12),
                    const Icon(Icons.chevron_right_rounded, size: 20, color: circleMuted),
                  ]),
                ));
              });
          })),
      ])));
  }
}
