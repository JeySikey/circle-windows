import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'api.dart';

// Circle 5.2.3 design tokens, from assets/style.css. Keep in sync with the site.
const circleBackground = Color(0xFF101113);
const circleSidebar = Color(0xFF151619);
const circlePanel = Color(0xFF191B1F);
const circlePanel2 = Color(0xFF202329);
const circleField = Color(0xFF111317);
const circleStroke = Color(0xFF30343B);
const circleGold = Color(0xFFC6A15B);
const circleGoldBright = Color(0xFFE2C17C);
const circleGoldGlow = Color(0x33D7AB53);
const circleText = Color(0xFFF1F1EF);
const circleMuted = Color(0xFFA1A5AD);
const circleGreen = Color(0xFF42C58A);
const circleRed = Color(0xFFE15B64);

ThemeData circleTheme({bool light = false}) {
  final bg = light ? const Color(0xFFF3F0E9) : circleBackground;
  final surface = light ? const Color(0xFFFFFFFF) : circlePanel;
  final text = light ? const Color(0xFF29251E) : circleText;
  final muted = light ? const Color(0xFF6E695E) : circleMuted;
  final stroke = light ? const Color(0xFFD6CFC1) : circleStroke;
  const gold = circleGold;
  final scheme = ColorScheme.fromSeed(
    seedColor: gold,
    brightness: light ? Brightness.light : Brightness.dark,
    surface: surface,
    primary: light ? const Color(0xFF9F782F) : circleGoldBright,
    onSurface: text,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: light ? Brightness.light : Brightness.dark,
    scaffoldBackgroundColor: bg,
    colorScheme: scheme,
    fontFamily: 'Segoe UI',
    dividerColor: stroke,
    cardTheme: CardThemeData(
      color: surface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: stroke),
        borderRadius: BorderRadius.circular(20),
      ),
    ),
    textTheme: TextTheme(
      headlineMedium: TextStyle(fontSize: 29, fontWeight: FontWeight.w700, color: text, letterSpacing: -.5),
      headlineSmall: TextStyle(fontSize: 23, fontWeight: FontWeight.w700, color: text),
      titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: text, letterSpacing: -.25),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: text),
      bodyMedium: TextStyle(fontSize: 14, height: 1.52, color: text),
      bodySmall: TextStyle(fontSize: 12, color: muted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: light ? const Color(0xFFF9F7F3) : circleField,
      hintStyle: TextStyle(color: muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: stroke)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: stroke)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: circleGoldBright, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 19, vertical: 12)),
      animationDuration: const Duration(milliseconds: 180),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w700, letterSpacing: .15)),
      foregroundColor: const WidgetStatePropertyAll(Color(0xFF1B1710)),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return circleGold.withValues(alpha: .28);
        return states.contains(WidgetState.hovered) ? circleGoldBright : circleGold;
      }),
      shadowColor: WidgetStatePropertyAll(circleGold.withValues(alpha: .26)),
      elevation: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.hovered) ? 5 : 0),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: ButtonStyle(
      animationDuration: const Duration(milliseconds: 180),
      minimumSize: const WidgetStatePropertyAll(Size(0, 43)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 11)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      foregroundColor: WidgetStatePropertyAll(light ? const Color(0xFF80602B) : circleGoldBright),
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.hovered) ? circleGold.withValues(alpha: .11) : Colors.transparent),
      side: WidgetStateProperty.resolveWith((states) => BorderSide(color:
        states.contains(WidgetState.hovered) ? circleGold.withValues(alpha: .7) : stroke,
        width: states.contains(WidgetState.hovered) ? 1.15 : 1)),
    )),
    textButtonTheme: TextButtonThemeData(style: ButtonStyle(
      animationDuration: const Duration(milliseconds: 160),
      foregroundColor: WidgetStatePropertyAll(light ? const Color(0xFF9F782F) : circleGoldBright),
      overlayColor: WidgetStatePropertyAll(circleGold.withValues(alpha: .10)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(11))),
    )),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: muted, hoverColor: gold.withValues(alpha: .1), highlightColor: gold.withValues(alpha: .13))),
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.windows: FadeForwardsPageTransitionsBuilder()}),
    appBarTheme: AppBarTheme(backgroundColor: surface, foregroundColor: text, elevation: 0, scrolledUnderElevation: 0, surfaceTintColor: Colors.transparent, titleTextStyle: TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.w700)),
    dialogTheme: DialogThemeData(backgroundColor: surface, shape: RoundedRectangleBorder(side: BorderSide(color: stroke), borderRadius: BorderRadius.circular(18))),
    snackBarTheme: SnackBarThemeData(backgroundColor: light ? const Color(0xFF29251E) : circlePanel2, contentTextStyle: const TextStyle(color: circleText)),
    chipTheme: ChipThemeData(backgroundColor: surface, side: BorderSide(color: stroke), selectedColor: const Color(0x33C6A15B), labelStyle: TextStyle(color: text)),
  );
}

class CircleLogo extends StatelessWidget {
  const CircleLogo({super.key, this.compact = false, this.size = 44});
  final bool compact;
  final double size;
  @override Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: size, height: size, decoration: BoxDecoration(borderRadius: BorderRadius.circular(size * .25), border: Border.all(color: circleGold.withValues(alpha: .47)), color: circleGold.withValues(alpha: .09), boxShadow: [BoxShadow(color: circleGold.withValues(alpha: .12), blurRadius: 18, spreadRadius: 1)]), child: Padding(padding: EdgeInsets.all(size * .16), child: Image.asset('assets/circle-mark.png'))),
    if (!compact) ...[const SizedBox(width: 11), Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('Circle', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: size * .53, fontWeight: FontWeight.w800, letterSpacing: -.5, height: 1)),
      const SizedBox(height: 5), const Text('ТВОЙ КРУГ. ТВОИ ЛЮДИ.', style: TextStyle(fontSize: 8.5, letterSpacing: 1.4, color: circleGold, fontWeight: FontWeight.w700)),
    ])],
  ]);
}

/// Interactive cards use a single implicit animation on hover; no ticking
/// animation controller is created for long feeds or off-screen cards.
class CircleSurface extends StatefulWidget {
  const CircleSurface({super.key, required this.child,
    this.padding = const EdgeInsets.all(20), this.radius = 20,
    this.accent = false, this.interactive = false, this.onTap});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool accent;
  final bool interactive;
  final VoidCallback? onTap;
  @override State<CircleSurface> createState() => _CircleSurfaceState();
}
class _CircleSurfaceState extends State<CircleSurface> {
  bool hovered = false;
  @override Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selected = widget.accent || (hovered && (widget.interactive || widget.onTap != null));
    return MouseRegion(
      onEnter: widget.interactive || widget.onTap != null ? (_) => setState(() => hovered = true) : null,
      onExit: widget.interactive || widget.onTap != null ? (_) => setState(() => hovered = false) : null,
      child: AnimatedContainer(
        duration: CircleMotion.duration(context, CircleMotion.normal), curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: dark ? null : Theme.of(context).cardTheme.color,
          gradient: dark ? LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: selected
              ? const [Color(0xFF242321), Color(0xFF1A1C20), Color(0xFF17191D)]
              : const [Color(0xFF1D2025), Color(0xFF181A1F)]) : null,
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(color: selected
            ? circleGold.withValues(alpha: hovered ? .69 : .42)
            : Theme.of(context).dividerColor.withValues(alpha: .68)),
          boxShadow: [
            if (dark && selected) BoxShadow(color: circleGold.withValues(alpha: hovered ? .15 : .07), blurRadius: hovered ? 32 : 22, spreadRadius: -3),
            BoxShadow(color: Colors.black.withValues(alpha: dark ? .14 : .035), blurRadius: hovered ? 22 : 11, offset: const Offset(0, 7)),
          ],
        ),
        child: Material(color: Colors.transparent, child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(widget.radius),
          child: Padding(padding: widget.padding, child: widget.child),
        )),
      ),
    );
  }
}

class CircleSection extends StatelessWidget {
  const CircleSection({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
    final heading = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: Theme.of(context).textTheme.headlineSmall),
      if (subtitle != null) ...[const SizedBox(height: 5), Text(subtitle!, style: Theme.of(context).textTheme.bodySmall)],
    ]);
    if (trailing == null) return heading;
    if (c.maxWidth < 620) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading, const SizedBox(height: 12), trailing!,
    ]);
    return Row(children: [Expanded(child: heading), const SizedBox(width: 16), trailing!]);
  });
}

class CircleUserAvatar extends StatefulWidget {
  const CircleUserAvatar({super.key, required this.api, required this.user, this.radius = 23});
  final CircleApi api;
  final Map<String, dynamic> user;
  final double radius;
  @override State<CircleUserAvatar> createState() => _CircleUserAvatarState();
}
class _CircleUserAvatarState extends State<CircleUserAvatar> {
  Future<List<int>>? future;
  @override void initState() {super.initState(); _load();}
  @override void didUpdateWidget(covariant CircleUserAvatar old) {super.didUpdateWidget(old); if (old.user['id'] != widget.user['id'] || old.api != widget.api) _load();}
  void _load() {
    final id = identifier(widget.user['id']);
    future = id > 0 && widget.user['avatar_url'] != null ? widget.api.media('avatar', id) : null;
  }
  @override Widget build(BuildContext context) {
    final name = label(widget.user);
    final initials = name.trim().isEmpty ? 'C' : name.trim().substring(0, 1).toUpperCase();
    return Container(width: widget.radius * 2, height: widget.radius * 2,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: circleGold.withValues(alpha: .48), width: 1.5), color: circleGold.withValues(alpha: .13)),
      child: future == null ? Center(child: Text(initials, style: TextStyle(fontSize: widget.radius * .8, fontWeight: FontWeight.w800, color: circleGoldBright))) : FutureBuilder<List<int>>(
        future: future, builder: (context, snapshot) => snapshot.hasData ? Image.memory(snapshot.data! is Uint8List ? snapshot.data! as Uint8List : Uint8List.fromList(snapshot.data!), fit: BoxFit.cover, cacheWidth: (widget.radius * 2 * MediaQuery.devicePixelRatioOf(context)).ceil(), gaplessPlayback: true, errorBuilder: (imageContext, imageError, stackTrace) => Center(child: Text(initials, style: const TextStyle(color: circleGoldBright)))) : Center(child: Text(initials, style: const TextStyle(color: circleGoldBright))),
      ),
    );
  }
}

class CircleEmpty extends StatelessWidget {
  const CircleEmpty({super.key, required this.title, this.description, this.icon = Icons.auto_awesome_outlined, this.action});
  final String title;
  final String? description;
  final IconData icon;
  final Widget? action;
  @override Widget build(BuildContext context) => Center(child:Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(shape: BoxShape.circle, color: circleGold.withValues(alpha: .1)), child: Icon(icon, size: 32, color: circleGold)),
    const SizedBox(height: 16), Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
    if (description != null) ...[const SizedBox(height: 8), Text(description!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall)],
    if (action != null) ...[const SizedBox(height: 16), action!],
  ])));
}

String circleDate(dynamic raw) {
  final text = '$raw';
  final time = DateTime.tryParse(text.replaceFirst(' ', 'T'));
  if (time == null) return text;
  final now = DateTime.now();
  if (now.difference(time).inDays == 0 && now.day == time.day && now.month == time.month) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
  return '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}.${time.year}';
}

class CircleRemoteImage extends StatefulWidget {
  const CircleRemoteImage({super.key, required this.api, required this.route, required this.id, this.fit = BoxFit.cover});
  final CircleApi api;
  final String route;
  final int id;
  final BoxFit fit;
  @override State<CircleRemoteImage> createState() => _CircleRemoteImageState();
}
class _CircleRemoteImageState extends State<CircleRemoteImage> {
  late Future<List<int>> request;
  @override void initState() {super.initState(); _load();}
  @override void didUpdateWidget(covariant CircleRemoteImage old) {super.didUpdateWidget(old); if (old.api != widget.api || old.route != widget.route || old.id != widget.id) _load();}
  void _load() {request = widget.api.media(widget.route, widget.id);}
  @override Widget build(BuildContext context) => FutureBuilder<List<int>>(future: request, builder: (context, snapshot) {
    if (!snapshot.hasData) return const SizedBox.shrink();
    return Image.memory(snapshot.data! is Uint8List ? snapshot.data! as Uint8List : Uint8List.fromList(snapshot.data!), width: double.infinity, height: double.infinity, fit: widget.fit, cacheWidth: 1800, gaplessPlayback: true);
  });
}


/// Motion tokens used across the desktop interface. Respect reduced motion
/// on supported Windows accessibility configurations.
class CircleMotion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 230);
  static const slow = Duration(milliseconds: 340);
  static Duration duration(BuildContext context, Duration fallback) =>
    MediaQuery.maybeOf(context)?.disableAnimations == true ? Duration.zero : fallback;
}

/// Branded button: hover lift, press compression, a restrained gold halo.
/// InkWell provides keyboard activation and semantic focus out of the box.
class CircleAccentButton extends StatefulWidget {
  const CircleAccentButton({super.key, required this.label, required this.onPressed,
    this.icon, this.primary = true, this.compact = false, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary;
  final bool compact;
  final bool busy;
  @override State<CircleAccentButton> createState() => _CircleAccentButtonState();
}
class _CircleAccentButtonState extends State<CircleAccentButton> {
  bool hovered = false;
  bool pressed = false;
  @override Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    final bright = enabled && (hovered || pressed);
    final duration = CircleMotion.duration(context, CircleMotion.fast);
    return MouseRegion(
      onEnter: enabled ? (_) => setState(() => hovered = true) : null,
      onExit: enabled ? (_) => setState(() {hovered = false; pressed = false;}) : null,
      child: AnimatedScale(
        scale: pressed && enabled ? .975 : hovered && enabled ? 1.018 : 1,
        duration: duration, curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: duration,
          decoration: BoxDecoration(
            gradient: widget.primary ? LinearGradient(colors: [
              bright ? circleGoldBright : circleGold,
              bright ? const Color(0xFFEACB90) : const Color(0xFFD4B271),
            ]) : null,
            color: widget.primary ? null : circleGold.withValues(alpha: bright ? .15 : .075),
            borderRadius: BorderRadius.circular(widget.compact ? 11 : 14),
            border: Border.all(color: circleGold.withValues(alpha: widget.primary ? .9 : bright ? .78 : .35)),
            boxShadow: enabled && bright ? [BoxShadow(
              color: circleGold.withValues(alpha: widget.primary ? .23 : .12),
              blurRadius: 24, spreadRadius: -2,
            )] : [],
          ),
          child: Material(color: Colors.transparent, child: InkWell(
            borderRadius: BorderRadius.circular(widget.compact ? 11 : 14),
            onTap: enabled ? widget.onPressed : null,
            onHighlightChanged: (value) {if (mounted) setState(() => pressed = value);},
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.compact ? 13 : 20, vertical: widget.compact ? 10 : 13),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (widget.busy) ...[
                  SizedBox(width: 17, height: 17, child: CircularProgressIndicator(
                    strokeWidth: 2, color: widget.primary ? const Color(0xFF15120C) : circleGoldBright)),
                  const SizedBox(width: 10),
                ] else if (widget.icon != null) ...[
                  Icon(widget.icon, size: widget.compact ? 17 : 19,
                    color: widget.primary ? const Color(0xFF19150F) : circleGoldBright),
                  const SizedBox(width: 9),
                ],
                Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: enabled
                    ? widget.primary ? const Color(0xFF19150F) : circleGoldBright
                    : circleMuted, fontWeight: FontWeight.w700, letterSpacing: .12)),
              ]),
            ),
          )),
        ),
      ),
    );
  }
}

/// Single navigation design for the main rail and secondary actions.
class CircleNavItem extends StatefulWidget {
  const CircleNavItem({super.key, required this.icon, required this.title,
    required this.onTap, this.active = false, this.compact = false});
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool active;
  final bool compact;
  @override State<CircleNavItem> createState() => _CircleNavItemState();
}
class _CircleNavItemState extends State<CircleNavItem> {
  bool hovered = false;
  @override Widget build(BuildContext context) {
    final lit = widget.active || hovered;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Tooltip(message: widget.title, waitDuration: const Duration(milliseconds: 700),
        child: MouseRegion(
          onEnter: (_) => setState(() => hovered = true),
          onExit: (_) => setState(() => hovered = false),
          child: AnimatedContainer(
            duration: CircleMotion.duration(context, CircleMotion.normal),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              gradient: lit ? LinearGradient(colors: [
                circleGold.withValues(alpha: widget.active ? .18 : .085),
                circleGold.withValues(alpha: .015),
              ]) : null,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: lit ? circleGold.withValues(alpha: widget.active ? .58 : .28) : Colors.transparent),
              boxShadow: widget.active ? [BoxShadow(color: circleGold.withValues(alpha: .13), blurRadius: 20, spreadRadius: -5)] : [],
            ),
            child: Material(color: Colors.transparent, child: InkWell(
              borderRadius: BorderRadius.circular(14), onTap: widget.onTap,
              child: SizedBox(height: 48, child: Row(children: [
                AnimatedContainer(duration: CircleMotion.duration(context, CircleMotion.fast),
                  width: 3, height: widget.active ? 25 : hovered ? 16 : 0,
                  decoration: BoxDecoration(color: circleGoldBright,
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: lit ? [BoxShadow(color: circleGold.withValues(alpha: .35), blurRadius: 9)] : [])),
                Expanded(child: Row(mainAxisAlignment: widget.compact ? MainAxisAlignment.center : MainAxisAlignment.start, children: [
                  AnimatedScale(scale: hovered ? 1.10 : 1, duration: CircleMotion.duration(context, CircleMotion.fast),
                    child: Icon(widget.icon, size: 21,
                      color: lit ? circleGoldBright : Theme.of(context).textTheme.bodySmall?.color)),
                  if (!widget.compact) ...[
                    const SizedBox(width: 14), Expanded(child: Text(widget.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: widget.active ? FontWeight.w700 : FontWeight.w500,
                        color: lit ? Theme.of(context).colorScheme.onSurface : circleMuted))),
                    if (hovered && !widget.active) const Icon(Icons.chevron_right_rounded, size: 15, color: circleGold),
                    const SizedBox(width: 10),
                  ],
                ])),
              ])),
            )),
          ),
        ),
      ));
  }
}

/// Deliberately small startup/refresh animation (never an expensive full-screen shader).
class CircleLoadingState extends StatefulWidget {
  const CircleLoadingState({super.key, this.caption = 'Загружаем твой круг...', this.size = 43});
  final String caption;
  final double size;
  @override State<CircleLoadingState> createState() => _CircleLoadingStateState();
}
class _CircleLoadingStateState extends State<CircleLoadingState> with SingleTickerProviderStateMixin {
  late final AnimationController pulse = AnimationController(vsync: this,
    duration: const Duration(milliseconds: 1550));
  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeOf(context)?.disableAnimations == true) {
      pulse.stop();
    } else if (!pulse.isAnimating) {
      pulse.repeat(reverse: true);
    }
  }
  @override void dispose() {pulse.dispose(); super.dispose();}
  @override Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations == true;
    return Center(child: AnimatedBuilder(animation: pulse, builder: (context, _) {
      final fade = reduce ? .65 : .35 + .4 * pulse.value;
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: widget.size, height: widget.size,
          decoration: BoxDecoration(shape: BoxShape.circle,
            border: Border.all(color: circleGold.withValues(alpha: fade), width: 1.7),
            boxShadow: [BoxShadow(color: circleGold.withValues(alpha: fade * .22), blurRadius: 24)]),
          child: const Icon(Icons.auto_awesome_rounded, size: 21, color: circleGoldBright)),
        const SizedBox(height: 18),
        Text(widget.caption, style: Theme.of(context).textTheme.bodySmall),
      ]);
    }));
  }
}

class CircleAmbientBackground extends StatelessWidget {
  const CircleAmbientBackground({super.key, required this.child});
  final Widget child;
  @override Widget build(BuildContext context) {
    if (Theme.of(context).brightness == Brightness.light) return child;
    return DecoratedBox(decoration: const BoxDecoration(
      gradient: RadialGradient(center: Alignment(.60, -1.2), radius: 1.7,
        colors: [Color(0xFF302A21), Color(0xFF17191D), circleBackground],
        stops: [0, .32, 1])), child: child);
  }
}

class CircleSavedAvatar extends StatelessWidget {
  const CircleSavedAvatar({super.key});
  @override Widget build(BuildContext context) => Container(
    width: 42, height: 42,
    decoration: BoxDecoration(shape: BoxShape.circle,
      gradient: LinearGradient(colors: [circleGold.withValues(alpha: .23), circleGold.withValues(alpha: .06)]),
      border: Border.all(color: circleGold.withValues(alpha: .50))),
    child: const Icon(Icons.bookmark_rounded, color: circleGoldBright, size: 21));
}

/// Compact desktop control with animated halo and proper keyboard focus.
class CircleIconAction extends StatefulWidget {
  const CircleIconAction({super.key, required this.icon, required this.tooltip,
    required this.onPressed, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  @override State<CircleIconAction> createState() => _CircleIconActionState();
}
class _CircleIconActionState extends State<CircleIconAction> {
  bool hovered = false;
  @override Widget build(BuildContext context) {
    final glow = widget.active || hovered;
    return Tooltip(message: widget.tooltip, child: MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: AnimatedContainer(
        duration: CircleMotion.duration(context, CircleMotion.fast),
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: circleGold.withValues(alpha: glow ? .12 : .025),
          border: Border.all(color: circleGold.withValues(alpha: glow ? .47 : .08)),
          borderRadius: BorderRadius.circular(12),
          boxShadow: glow ? [BoxShadow(color: circleGold.withValues(alpha: .13), blurRadius: 18)] : [],
        ),
        child: Material(color: Colors.transparent, child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Center(child: AnimatedScale(
            scale: hovered ? 1.13 : 1, duration: CircleMotion.duration(context, CircleMotion.fast),
            child: Icon(widget.icon, size: 20,
              color: glow ? circleGoldBright : Theme.of(context).textTheme.bodySmall?.color))),
        )),
      ),
    ));
  }
}

class CircleProfileMetric extends StatelessWidget {
  const CircleProfileMetric({super.key, required this.icon, required this.value,
    required this.label});
  final IconData icon;
  final String value;
  final String label;
  @override Widget build(BuildContext context) => Container(
    width: 175, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(15),
      gradient: LinearGradient(colors: [circleGold.withValues(alpha: .085),
        circleGold.withValues(alpha: .02)]),
      border: Border.all(color: circleGold.withValues(alpha: .18)),
    ),
    child: Row(children: [
      Icon(icon, color: circleGold, size: 22), const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AnimatedSwitcher(duration: CircleMotion.duration(context, CircleMotion.normal),
          child: Text(value, key: ValueKey(value),
            style: const TextStyle(color: circleGoldBright, fontSize: 19,
              fontWeight: FontWeight.w800))),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]),
    ]),
  );
}

/// Animated chat preview that adapts to compact desktop windows.
class CircleConversationTile extends StatefulWidget {
  const CircleConversationTile({super.key, required this.api,
    required this.conversation, required this.active, required this.onTap});
  final CircleApi api;
  final Map<String, dynamic> conversation;
  final bool active;
  final VoidCallback onTap;
  @override State<CircleConversationTile> createState() => _CircleConversationTileState();
}
class _CircleConversationTileState extends State<CircleConversationTile> {
  bool hovered = false;
  @override Widget build(BuildContext context) {
    final lit = hovered || widget.active;
    final saved = widget.conversation['saved'] == true;
    final person = widget.conversation['peer'] is Map
      ? Map<String, dynamic>.from(widget.conversation['peer'] as Map) : <String, dynamic>{};
    final title = saved ? 'Избранное' : label(person);
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: AnimatedContainer(
          duration: CircleMotion.duration(context, CircleMotion.normal),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            gradient: lit ? LinearGradient(colors: [
              circleGold.withValues(alpha: widget.active ? .16 : .085),
              circleGold.withValues(alpha: .014),
            ]) : null,
            border: Border.all(color: lit
              ? circleGold.withValues(alpha: widget.active ? .48 : .20)
              : Colors.transparent),
            boxShadow: widget.active ? [BoxShadow(
              color: circleGold.withValues(alpha: .08), blurRadius: 18)] : [],
          ),
          child: Material(color: Colors.transparent, child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: widget.onTap,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 13),
              child: Row(children: [
                if (saved) const CircleSavedAvatar()
                else CircleUserAvatar(api: widget.api, user: person, radius: 21),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5,
                      fontWeight: widget.active ? FontWeight.w700 : FontWeight.w600,
                      color: widget.active ? circleGoldBright : Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: 6),
                  Text('${widget.conversation['last_message'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
                ])),
                const SizedBox(width: 7),
                AnimatedOpacity(opacity: lit ? 1 : 0, duration: CircleMotion.duration(context, CircleMotion.fast),
                  child: Icon(Icons.chevron_right_rounded, size: 16,
                    color: widget.active ? circleGoldBright : circleMuted)),
              ])),
          )),
        ),
      ),
    );
  }
}

/// Message-specific surface: reacts to the pointer without creating a ticker
/// for each visible message. This keeps long conversations inexpensive.
class CircleMessageShell extends StatefulWidget {
  const CircleMessageShell({super.key, required this.mine, required this.child});
  final bool mine;
  final Widget child;
  @override
  State<CircleMessageShell> createState() => _CircleMessageShellState();
}

class _CircleMessageShellState extends State<CircleMessageShell> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: AnimatedContainer(
        duration: CircleMotion.duration(context, CircleMotion.fast),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 8),
        decoration: BoxDecoration(
          gradient: isDark ? LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: widget.mine
              ? const [Color(0xFF2A2924), Color(0xFF211F1B)]
              : const [Color(0xFF212329), Color(0xFF1A1C20)],
          ) : null,
          color: isDark ? null : Theme.of(context).cardTheme.color,
          border: Border.all(color: circleGold.withValues(alpha:
            hover ? .55 : widget.mine ? .28 : .085)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(17),
            topRight: const Radius.circular(17),
            bottomLeft: Radius.circular(widget.mine ? 17 : 5),
            bottomRight: Radius.circular(widget.mine ? 5 : 17)),
          boxShadow: hover ? [BoxShadow(color: circleGold.withValues(alpha: .075),
            blurRadius: 20, spreadRadius: -5)] : [],
        ),
        child: widget.child,
      ),
    );
  }
}
