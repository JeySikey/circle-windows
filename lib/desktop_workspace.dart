import 'package:flutter/material.dart';
import 'design.dart';

/// Header actions adapt to the workspace width and Windows text scaling.
class CircleWorkspaceHeader extends StatelessWidget {
  const CircleWorkspaceHeader(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.leading,
      required this.actionsBuilder});

  final String title;
  final String subtitle;
  final Widget leading;
  final List<Widget> Function(BuildContext, bool compact) actionsBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
        final scale =
            (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 1.6);
        final compact = size.maxWidth < 900 * scale;
        final light = Theme.of(context).brightness == Brightness.light;
        return Container(
          height: 78 * scale,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 22),
          decoration: BoxDecoration(
            color: light ? Theme.of(context).cardTheme.color : null,
            gradient: light
                ? null
                : const LinearGradient(colors: [
                    Color(0xFF202027),
                    circlePanel,
                    Color(0xFF17191C)
                  ]),
            border: Border(
                bottom: BorderSide(color: circleGold.withValues(alpha: .17))),
          ),
          child: Row(children: [
            leading,
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ])),
            const SizedBox(width: 12),
            ...actionsBuilder(context, compact),
          ]),
        );
      });
}

/// Keeps the desktop navigation visible while a secondary screen is open.
/// Screens pushed by their own buttons join this navigator as well, so Back
/// follows the same history instead of leaving the workspace.
class CircleWorkspace extends StatefulWidget {
  const CircleWorkspace({super.key, required this.home, this.onRouteChanged});

  final Widget home;
  final ValueChanged<String?>? onRouteChanged;

  @override
  State<CircleWorkspace> createState() => CircleWorkspaceState();
}

class CircleWorkspaceState extends State<CircleWorkspace> {
  final navigator = GlobalKey<NavigatorState>();
  late final observer = _WorkspaceObserver((title) {
    if (mounted) widget.onRouteChanged?.call(title);
  });

  Future<void> open(String title, Widget screen) async {
    await navigator.currentState?.push<void>(MaterialPageRoute<void>(
      settings: RouteSettings(name: title),
      builder: (_) => screen,
    ));
  }

  Future<bool> showHome() async {
    final currentNavigator = navigator.currentState;
    if (currentNavigator == null) return false;
    while (mounted && currentNavigator.mounted) {
      final top = observer.topRoute;
      if (top == null) return false;
      if (top.isFirst) return true;
      // A live call or an unsaved form gets the same chance to finish or
      // cancel as it does with Back. maybePop may report a veto as handled,
      // so verify that the current route actually changed before continuing.
      await currentNavigator.maybePop();
      if (!mounted || identical(observer.topRoute, top)) return false;
    }
    return false;
  }

  Future<void> back() async {
    await navigator.currentState?.maybePop();
  }

  @override
  Widget build(BuildContext context) => _WorkspaceHome(
        home: widget.home,
        child: Navigator(
          key: navigator,
          observers: [observer],
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/'),
            builder: (context) => _WorkspaceHome.of(context),
          ),
        ),
      );
}

class _WorkspaceHome extends InheritedWidget {
  const _WorkspaceHome({required this.home, required super.child});
  final Widget home;

  static Widget of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WorkspaceHome>()!.home;

  @override
  bool updateShouldNotify(_WorkspaceHome oldWidget) => home != oldWidget.home;
}

class _WorkspaceObserver extends NavigatorObserver {
  _WorkspaceObserver(this.onChanged);
  final ValueChanged<String?> onChanged;
  final _sections = <Route<dynamic>, String?>{};
  int revision = 0;
  Route<dynamic>? topRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sections[route] = route.isFirst
        ? null
        : route.settings.name ?? _sections[previousRoute] ?? '';
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sections.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sections.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final section = _sections.remove(oldRoute);
    if (newRoute != null) {
      _sections[newRoute] =
          newRoute.isFirst ? null : newRoute.settings.name ?? section;
    }
  }

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    this.topRoute = topRoute;
    final current = ++revision;
    final title = topRoute.isFirst
        ? null
        : _sections[topRoute] ??
            topRoute.settings.name ??
            _sections[previousTopRoute] ??
            '';
    // Navigator notifications happen during route construction. Report after
    // layout, and discard intermediate notifications while returning home.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (revision == current) onChanged(title);
    });
  }
}
