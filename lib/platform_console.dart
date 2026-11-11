import 'package:flutter/material.dart';
import 'api.dart';
import 'design.dart';

/// Native platform administration. Requires server-side OWNER/ADMIN authorization;
/// it never tries to modify feature flags through browser session forms.
class CirclePlatformConsole extends StatefulWidget {
  const CirclePlatformConsole(this.api, {super.key});
  final CircleApi api;
  @override State<CirclePlatformConsole> createState() => _CirclePlatformConsoleState();
}

class _CirclePlatformConsoleState extends State<CirclePlatformConsole> {
  final search = TextEditingController();
  late Future<Map<String, dynamic>> data;
  String filter = '';
  String? savingFeature;

  @override
  void initState() { super.initState(); _reload(); }
  @override
  void dispose() { search.dispose(); super.dispose(); }
  void _reload() { data = widget.api.call('desktop-platform-console'); }
  void _refresh() => setState(_reload);

  Future<void> _toggle(Map<String, dynamic> feature, bool enabled) async {
    if (savingFeature != null) return;
    final key = '${feature['feature_key'] ?? ''}';
    if (key.isEmpty) return;
    if (!enabled) {
      final confirmation = await showDialog<bool>(context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Отключить модуль?'),
          content: Text('Функция «${feature['description'] ?? key}» станет недоступна всем пользователям Circle.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Отключить')),
          ],
        ));
      if (!mounted || confirmation != true) return;
    }
    setState(() => savingFeature = key);
    try {
      await widget.api.call('desktop-feature-toggle', body: {
        'feature_key': key, 'enabled': enabled,
      });
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось изменить модуль: $error')));
    } finally {
      if (mounted) setState(() => savingFeature = null);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: data, builder: (context, snapshot) {
      if (snapshot.hasError) return CircleEmpty(title: 'Нет доступа к управлению',
        description: '${snapshot.error}', icon: Icons.admin_panel_settings_outlined,
        action: OutlinedButton(onPressed: _refresh, child: const Text('Повторить')));
      if (!snapshot.hasData) return const CircleLoadingState(
        caption: 'Загружаем состояние платформы...');
      final response = snapshot.data!;
      final all = (response['features'] as List? ?? []).whereType<Map>().toList();
      final logs = (response['audit'] as List? ?? []).whereType<Map>().toList();
      final selected = all.where((feature) =>
        '${feature['feature_key']} ${feature['description']}'
          .toLowerCase().contains(filter.toLowerCase().trim())).toList();
      final enabledCount = all.where((item) => item['enabled'] == true).length;
      return DefaultTabController(length: 2, child: Column(children: [
        Material(color: Theme.of(context).cardTheme.color, child: TabBar(
          indicatorColor: circleGoldBright,
          tabs: const [Tab(icon: Icon(Icons.tune_rounded), text: 'Модули'),
            Tab(icon: Icon(Icons.history_rounded), text: 'Журнал действий')],
        )),
        Expanded(child: TabBarView(children: [
          Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(24, 22, 24, 16), child:
              CircleSection(title: 'Системы Circle',
                subtitle: '$enabledCount из ${all.length} модулей включены',
                trailing: OutlinedButton.icon(onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded), label: const Text('Обновить')))),
            Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: TextField(controller: search,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Найти модуль или функцию'),
                onChanged: (value) => setState(() => filter = value))),
            Expanded(child: selected.isEmpty
              ? const CircleEmpty(title: 'Модули не найдены', icon: Icons.search_off)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  cacheExtent: 350,
                  itemCount: selected.length,
                  itemBuilder: (context, index) {
                    final feature = Map<String, dynamic>.from(selected[index]);
                    final key = '${feature['feature_key']}';
                    final active = feature['enabled'] == true;
                    return Padding(padding: const EdgeInsets.only(bottom: 9),
                      child: CircleSurface(padding: const EdgeInsets.symmetric(
                        horizontal: 17, vertical: 12), child: Row(children: [
                          Container(width: 39, height: 39,
                            decoration: BoxDecoration(shape: BoxShape.circle,
                              color: circleGold.withValues(alpha: active ? .14 : .06)),
                            child: Icon(active ? Icons.toggle_on_outlined : Icons.toggle_off_outlined,
                              color: active ? circleGoldBright : circleMuted)),
                          const SizedBox(width: 14),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${feature['description'] ?? key}',
                                style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 4),
                              Text(key, style: Theme.of(context).textTheme.bodySmall),
                            ])),
                          const SizedBox(width: 14),
                          Switch(value: active, onChanged: savingFeature != null
                            ? null : (value) => _toggle(feature, value)),
                        ])));
                  },
                )),
          ]),
          ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: logs.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return Padding(padding: const EdgeInsets.only(bottom: 18),
                child: CircleSection(title: 'Последние действия',
                  subtitle: 'Журнал для администраторов · ${logs.length} событий'));
              final entry = logs[index - 1];
              return Padding(padding: const EdgeInsets.only(bottom: 8),
                child: CircleSurface(padding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 14), child: Row(children: [
                    const Icon(Icons.history_toggle_off_rounded, color: circleGold),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${entry['action'] ?? ''}',
                          style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 5),
                        Text('${entry['username'] ?? 'Система'} · ${circleDate(entry['created_at'])}',
                          style: Theme.of(context).textTheme.bodySmall),
                      ])),
                  ])));
            },
          ),
        ])),
      ]));
    },
  );
}
