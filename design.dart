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
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: circleGold, width: 1.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      backgroundColor: circleGold, foregroundColor: const Color(0xFF1A1712),
      textStyle: const TextStyle(fontWeight: FontWeight.w700),
      minimumSize: const Size(0, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      foregroundColor: light ? const Color(0xFF80602B) : circleGoldBright,
      side: BorderSide(color: stroke),
      minimumSize: const Size(0, 43),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    )),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: muted)),
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
    Container(width: size, height: size, decoration: BoxDecoration(borderRadius: BorderRadius.circular(size * .25), border: Border.all(color: circleGold.withValues(alpha: .45)), color: circleGold.withValues(alpha: .09)), child: Padding(padding: EdgeInsets.all(size * .16), child: Image.asset('assets/circle-mark.png'))),
    if (!compact) ...[const SizedBox(width: 11), Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('Circle', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: size * .53, fontWeight: FontWeight.w800, letterSpacing: -.5, height: 1)),
      const SizedBox(height: 5), const Text('ТВОЙ КРУГ. ТВОИ ЛЮДИ.', style: TextStyle(fontSize: 8.5, letterSpacing: 1.4, color: circleGold, fontWeight: FontWeight.w700)),
    ])],
  ]);
}

class CircleSurface extends StatelessWidget {
  const CircleSurface({super.key, required this.child, this.padding = const EdgeInsets.all(20), this.radius = 18, this.accent = false});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool accent;
  @override Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      gradient: Theme.of(context).brightness == Brightness.dark
        ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF1C1E23), Color(0xFF17191D)])
        : null,
      color: Theme.of(context).brightness == Brightness.dark
        ? null : Theme.of(context).cardTheme.color,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: accent ? circleGold.withValues(alpha: .5) : Theme.of(context).dividerColor),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .13), blurRadius: 24, offset: const Offset(0, 9))],
    ), child: child);
}

class CircleSection extends StatelessWidget {
  const CircleSection({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override Widget build(BuildContext context) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.headlineSmall),
      if (subtitle != null) ...[const SizedBox(height: 5), Text(subtitle!, style: Theme.of(context).textTheme.bodySmall)],
    ])),
    if (trailing != null) trailing!,
  ]);
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
