import 'package:flutter/material.dart';
import 'api.dart';
import 'design.dart';

/// Native counterpart of the legacy-report queue and moderation archive.
/// The API, not this widget, decides who is an administrator.
class CircleModerationCenter extends StatefulWidget {
  const CircleModerationCenter(this.api, {super.key, this.onOpenUser});
  final CircleApi api;
  final ValueChanged<int>? onOpenUser;
  @override
  State<CircleModerationCenter> createState() => _CircleModerationCenterState();
}

class _CircleModerationCenterState extends State<CircleModerationCenter> {
  late Future<Map<String, dynamic>> inbox;
  late Future<Map<String, dynamic>> archive;
  int page = 1;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    inbox = widget.api.call('desktop-moderation-inbox');
    archive = widget.api.call('desktop-moderation-archive', query: {'page': '$page'});
  }

  void _refresh() => setState(_reload);

  Future<void> _decide(Map<String, dynamic> report, String status) async {
    if (saving) return;
    final controller = TextEditingController();
    var warn = false;
    try {
      final decision = await showDialog<({String note, String sanction})>(
        context: context,
        builder: (dialog) => StatefulBuilder(builder: (dialog, update) => AlertDialog(
          title: Text(switch (status) {
            'REVIEWING' => 'Принять жалобу в работу',
            'RESOLVED' => 'Подтвердить жалобу',
            _ => 'Отклонить жалобу',
          }),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Обращение #${report['id']} · ${report['reporter'] ?? 'Пользователь'}',
                style: Theme.of(dialog).textTheme.bodySmall),
              const SizedBox(height: 16),
              TextField(controller: controller, autofocus: true, maxLength: 500, maxLines: 3,
                decoration: const InputDecoration(labelText: 'Основание решения',
                  hintText: 'Что было проверено и почему принято решение?')),
              if (status == 'RESOLVED') CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: warn,
                onChanged: (value) => update(() => warn = value ?? false),
                title: const Text('Записать предупреждение'),
                subtitle: const Text('Решение фиксируется в журнале модерации'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Отмена')),
            FilledButton(onPressed: () {
              final note = controller.text.trim();
              if (status != 'REVIEWING' && note.length < 3) return;
              Navigator.pop(dialog, (note: note,
                sanction: status == 'RESOLVED' && warn ? 'WARNING' : 'NONE'));
            }, child: const Text('Подтвердить решение')),
          ],
        )),
      );
      if (!mounted || decision == null) return;
      setState(() => saving = true);
      try {
        await widget.api.call('desktop-moderation-decide', body: {
          'report_id': identifier(report['id']),
          'status': status,
          'note': decision.note,
          'sanction': decision.sanction,
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Решение сохранено в журнале Circle')));
        _refresh();
      } catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error')));
      } finally {
        if (mounted) setState(() => saving = false);
      }
    } finally {
      controller.dispose();
    }
  }

  void _switchPage(int next) {
    if (next < 1 || next > 10000) return;
    setState(() { page = next; archive = widget.api.call(
      'desktop-moderation-archive', query: {'page': '$page'}); });
  }

  Widget _userLink(int id, String name) => TextButton.icon(
    onPressed: id > 0 && widget.onOpenUser != null
      ? () => widget.onOpenUser!(id) : null,
    icon: const Icon(Icons.person_outline_rounded, size: 17),
    label: Text(name, overflow: TextOverflow.ellipsis),
  );

  Widget _inbox() => FutureBuilder<Map<String, dynamic>>(
    future: inbox, builder: (context, snapshot) {
      if (snapshot.hasError) return CircleEmpty(title: 'Очередь недоступна',
        description: '${snapshot.error}', icon: Icons.lock_outline,
        action: OutlinedButton(onPressed: _refresh, child: const Text('Повторить')));
      if (!snapshot.hasData) return const CircleLoadingState(caption: 'Проверяем обращения...');
      final reports = items(snapshot.data!);
      return RefreshIndicator(onRefresh: () async { _refresh(); await inbox; },
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 30),
          cacheExtent: 300,
          itemCount: reports.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return Padding(padding: const EdgeInsets.only(bottom: 20),
              child: CircleSection(title: 'Жалобы пользователей',
                subtitle: 'Очередь рассмотрения · ${reports.length} обращений',
                trailing: OutlinedButton.icon(onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded), label: const Text('Обновить'))));
            final report = reports[index - 1];
            return Padding(padding: const EdgeInsets.only(bottom: 12), child: CircleSurface(
              padding: const EdgeInsets.all(18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Жалоба #${report['id']}', style: Theme.of(context).textTheme.titleMedium),
                    _ModerationTag(status: '${report['status']}'),
                    Text(circleDate(report['created_at']), style: Theme.of(context).textTheme.bodySmall),
                  ]),
                const SizedBox(height: 12),
                SelectableText('${report['reason'] ?? ''}',
                  style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 10),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 8,
                  children: [
                    Text('От: ${report['reporter'] ?? ''}',
                      style: Theme.of(context).textTheme.bodySmall),
                    _userLink(identifier(report['target_user_id']),
                      '${report['target'] ?? 'Пользователь'}'),
                  ]),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(onPressed: saving ? null : () => _decide(report, 'REVIEWING'),
                    icon: const Icon(Icons.rule_outlined, size: 17), label: const Text('В работу')),
                  CircleAccentButton(label: 'Подтвердить', icon: Icons.check_circle_outline,
                    compact: true, onPressed: saving ? null : () => _decide(report, 'RESOLVED')),
                  TextButton.icon(onPressed: saving ? null : () => _decide(report, 'REJECTED'),
                    icon: const Icon(Icons.block_outlined, size: 17), label: const Text('Отклонить')),
                ]),
              ]),
            ));
          },
        ));
    });

  Widget _archive() => FutureBuilder<Map<String, dynamic>>(
    future: archive, builder: (context, snapshot) {
      if (snapshot.hasError) return CircleEmpty(title: 'Архив недоступен',
        description: '${snapshot.error}', icon: Icons.archive_outlined,
        action: OutlinedButton(onPressed: _refresh, child: const Text('Повторить')));
      if (!snapshot.hasData) return const CircleLoadingState(caption: 'Открываем архив решений...');
      final data = snapshot.data!;
      final legacy = (data['legacy'] as List? ?? []).whereType<Map>().toList();
      final trust = (data['trust'] as List? ?? []).whereType<Map>().toList();
      final history = obj(data['history']);
      return ListView(padding: const EdgeInsets.fromLTRB(24, 22, 24, 26), children: [
        CircleSection(title: 'Архив решений',
          subtitle: 'Причины, даты, модераторы и история действий сохраняются',
          trailing: OutlinedButton.icon(onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded), label: const Text('Обновить'))),
        const SizedBox(height: 22),
        Text('Circle Trust', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        if (trust.isEmpty) const CircleSurface(child: Text('На этой странице нет закрытых сигналов')),
        for (final item in trust) _archiveCard(Map<String, dynamic>.from(item),
          'TRUST', history),
        const SizedBox(height: 22),
        Text('Жалобы на сообщения', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        if (legacy.isEmpty) const CircleSurface(child: Text('На этой странице нет закрытых жалоб')),
        for (final item in legacy) _archiveCard(Map<String, dynamic>.from(item),
          'LEGACY', history),
        const SizedBox(height: 18),
        Wrap(alignment: WrapAlignment.center, spacing: 12, crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(onPressed: page > 1 ? () => _switchPage(page - 1) : null,
              icon: const Icon(Icons.chevron_left), label: const Text('Назад')),
            Text('Страница $page', style: Theme.of(context).textTheme.bodySmall),
            OutlinedButton.icon(onPressed: legacy.length == 30 || trust.length == 30
              ? () => _switchPage(page + 1) : null,
              icon: const Icon(Icons.chevron_right), label: const Text('Дальше')),
          ]),
      ]);
    });

  Widget _archiveCard(Map<String, dynamic> item, String kind, Map<String, dynamic> history) {
    final key = '$kind:${item['id']}';
    final events = (history[key] as List? ?? []).whereType<Map>().toList();
    return Padding(padding: const EdgeInsets.only(bottom: 9), child: CircleSurface(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Text('#${item['id']} · ${item['target'] ?? 'Удалённый аккаунт'}'),
        subtitle: Text(circleDate(item['updated_at'] ?? item['reviewed_at']),
          style: Theme.of(context).textTheme.bodySmall),
        trailing: _ModerationTag(status: '${item['status']}'),
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 12), child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${item['reason'] ?? item['excerpt'] ?? ''}'),
              const SizedBox(height: 8),
              _userLink(identifier(item['target_user_id']),
                '${item['target'] ?? 'Аккаунт недоступен'}'),
              Text('Решение: ${item['resolution_note'] ?? '—'}',
                style: Theme.of(context).textTheme.bodySmall),
              Text('Модератор: ${item['moderator'] ?? 'Не указан'}',
                style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              if (events.isEmpty) Text('История отсутствует (старое решение)',
                style: Theme.of(context).textTheme.bodySmall),
              for (final action in events)
                Padding(padding: const EdgeInsets.only(bottom: 9), child: Row(children: [
                  const Icon(Icons.history_rounded, size: 17, color: circleGold),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    '${action['action']} · ${action['sanction']}\n'
                    '${action['actor'] ?? 'Модератор'} · ${circleDate(action['created_at'])}\n'
                    '${action['note'] ?? ''}',
                    style: Theme.of(context).textTheme.bodySmall)),
                ])),
            ])),
        ],
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(length: 2, child:
    Column(children: [
      Material(color: Theme.of(context).cardTheme.color,
        child: TabBar(tabs: const [
          Tab(icon: Icon(Icons.inbox_outlined), text: 'Новые обращения'),
          Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Архив решений'),
        ], indicatorColor: circleGoldBright, dividerColor: Theme.of(context).dividerColor)),
      Expanded(child: TabBarView(children: [_inbox(), _archive()])),
    ]));
}

class _ModerationTag extends StatelessWidget {
  const _ModerationTag({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final isOpen = status == 'OPEN' || status == 'REVIEWING';
    return Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (isOpen ? circleGold : circleGreen).withValues(alpha: .13),
        borderRadius: BorderRadius.circular(12)),
      child: Text(switch (status) {
        'OPEN' => 'Открыта', 'REVIEWING' => 'В работе',
        'RESOLVED' => 'Подтверждена', 'REJECTED' => 'Отклонена',
        'CONFIRMED' => 'Подтверждено', 'DISMISSED' => 'Отклонено',
        _ => status,
      }, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
        color: isOpen ? circleGoldBright : circleGreen)),
    );
  }
}
