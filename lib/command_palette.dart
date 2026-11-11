import 'package:flutter/material.dart';
import 'design.dart';

/// Fast, local-only navigation. No network calls are made while typing.
class CircleCommand {
  const CircleCommand({required this.title, required this.subtitle,
    required this.icon, required this.onInvoke, this.keyHint});
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onInvoke;
  final String? keyHint;
}

Future<void> showCircleCommandPalette(BuildContext context, List<CircleCommand> commands) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _CircleCommandPalette(commands: commands),
  );
}

class _CircleCommandPalette extends StatefulWidget {
  const _CircleCommandPalette({required this.commands});
  final List<CircleCommand> commands;
  @override
  State<_CircleCommandPalette> createState() => _CircleCommandPaletteState();
}

class _CircleCommandPaletteState extends State<_CircleCommandPalette> {
  final TextEditingController search = TextEditingController();
  String query = '';

  @override
  void dispose() { search.dispose(); super.dispose(); }

  List<CircleCommand> get filtered {
    final needle = query.toLowerCase().trim();
    if (needle.isEmpty) return widget.commands;
    return widget.commands.where((action) =>
      '${action.title} ${action.subtitle}'.toLowerCase().contains(needle)).toList();
  }

  void _run(CircleCommand action) {
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) => action.onInvoke());
  }

  @override
  Widget build(BuildContext context) {
    final matches = filtered;
    final maxHeight = MediaQuery.sizeOf(context).height * .72;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: circleGold.withValues(alpha: .36))),
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 560,
        maxHeight: maxHeight.clamp(250.0, 650.0).toDouble()), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.fromLTRB(18, 19, 18, 14), child: Row(children: [
            const Icon(Icons.search_rounded, color: circleGoldBright, size: 25),
            const SizedBox(width: 13),
            Expanded(child: TextField(
              controller: search, autofocus: true,
              onChanged: (value) => setState(() => query = value),
              onSubmitted: (_) { if (matches.isNotEmpty) _run(matches.first); },
              decoration: const InputDecoration(
                hintText: 'Куда перейдём?', border: InputBorder.none,
                enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                filled: false, contentPadding: EdgeInsets.symmetric(vertical: 6)),
            )),
            Tooltip(message: 'Закрыть', child: IconButton(
              onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded))),
          ])),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Flexible(child: matches.isEmpty
            ? const Padding(padding: EdgeInsets.all(30),
                child: CircleEmpty(title: 'Ничего не найдено',
                  description: 'Попробуй другое название раздела', icon: Icons.search_off))
            : ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(12),
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final item = matches[index];
                  return Padding(padding: const EdgeInsets.only(bottom: 5),
                    child: _PaletteTile(key: ValueKey(item.title), action: item,
                      onTap: () => _run(item)));
                })),
          Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(20, 12, 20, 13),
            decoration: BoxDecoration(color: circleGold.withValues(alpha: .035),
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
            child: Text('Enter — открыть первый результат   ·   Esc — закрыть',
              style: Theme.of(context).textTheme.bodySmall)),
        ])),
    );
  }
}

class _PaletteTile extends StatefulWidget {
  const _PaletteTile({super.key, required this.action, required this.onTap});
  final CircleCommand action;
  final VoidCallback onTap;
  @override
  State<_PaletteTile> createState() => _PaletteTileState();
}

class _PaletteTileState extends State<_PaletteTile> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: AnimatedContainer(
        duration: CircleMotion.duration(context, CircleMotion.fast),
        decoration: BoxDecoration(
          color: circleGold.withValues(alpha: hover ? .12 : .02),
          border: Border.all(color: circleGold.withValues(alpha: hover ? .26 : 0)),
          borderRadius: BorderRadius.circular(14),
          boxShadow: hover ? [BoxShadow(color: circleGold.withValues(alpha: .08),
            blurRadius: 18)] : [],
        ),
        child: Material(color: Colors.transparent, child: InkWell(
          borderRadius: BorderRadius.circular(14), onTap: widget.onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            child: Row(children: [
              Icon(widget.action.icon, size: 21,
                color: hover ? circleGoldBright : circleMuted),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.action.title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 3),
                Text(widget.action.subtitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
              ])),
              if (widget.action.keyHint != null)
                Text(widget.action.keyHint!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 10),
              AnimatedRotation(turns: hover ? 0 : -.10,
                duration: CircleMotion.duration(context, CircleMotion.fast),
                child: const Icon(Icons.arrow_outward_rounded, size: 17, color: circleGold)),
            ])),
        )),
      ),
    );
  }
}
