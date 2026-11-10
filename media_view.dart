import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'design.dart';
import 'startup_log.dart';

/// Authenticated media never receive bearer tokens through a public URL.
/// Files are downloaded from Circle API, then decoded locally.
class CircleMedia extends StatefulWidget {
  const CircleMedia({super.key, required this.api, required this.route, required this.id, required this.mime, this.compact = false});
  final CircleApi api;
  final String route;
  final int id;
  final String mime;
  final bool compact;
  @override State<CircleMedia> createState() => _CircleMediaState();
}
class _CircleMediaState extends State<CircleMedia> {
  Future<List<int>>? bytes;
  Player? player;
  VideoController? controller;
  File? local;
  bool preparing = false;
  bool playing = false;
  @override void initState() {super.initState(); _load();}
  void _load() {
    // Videos and audio are fetched only when the user presses Play.
    bytes = widget.mime.startsWith('image/') ? widget.api.media(widget.route, widget.id) : null;
  }
  @override void didUpdateWidget(covariant CircleMedia old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.route != widget.route || old.api != widget.api) {
      _clear(); _load();
    }
  }
  Future<void> _prepare() async {
    if (preparing || player != null) return;
    setState(() => preparing = true);
    try {
      final dir = await getTemporaryDirectory();
      final extension = widget.mime.contains('webm') ? 'webm' : widget.mime.contains('ogg') ? 'ogg' : widget.mime.contains('wav') ? 'wav' : widget.mime.contains('mp4') ? 'mp4' : 'mp3';
      final path = '${dir.path}${Platform.pathSeparator}circle_${widget.route}_${widget.id}.$extension';
      final file = File(path);
      await widget.api.downloadMediaToFile(widget.route, widget.id, file);
      if (!mounted) {try {await file.delete();} catch (_) {} return;}
      // Loading native media libraries is optional; a missing codec must not
      // stop the entire Circle app before the first screen is visible.
      MediaKit.ensureInitialized();
      final p = Player();
      final v = widget.mime.startsWith('video/') ? VideoController(p) : null;
      await p.open(Media(file.path));
      if (!mounted) {await p.dispose(); return;}
      setState(() {player = p; controller = v; local = file; playing = true;});
    } catch (error, stack) {CircleStartupLog.report('media player', error, stack); if (mounted) setState(() => preparing = false); if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Медиа: $error')));}
    finally {if (mounted) setState(() => preparing = false);}
  }
  void _clear() {
    final old = player;
    final cached = local;
    player = null; controller = null; local = null; playing = false;
    if (old != null) {
      old.dispose().then((_) async {
        if (cached != null && await cached.exists()) {
          try {await cached.delete();} catch (_) { /* Temporary Windows file may still be in use. */ }
        }
      });
    }
  }
  String _clock(Duration duration) {
    final m = duration.inMinutes.toString().padLeft(2, '0');
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
  @override void dispose() {_clear(); super.dispose();}
  @override Widget build(BuildContext context) {
    if (widget.mime.startsWith('image/')) {
      return ClipRRect(borderRadius: BorderRadius.circular(14), child: FutureBuilder<List<int>>(future: bytes, builder: (context, snapshot) {
        if (snapshot.hasError) return const CircleEmpty(title: 'Не удалось загрузить фото', icon: Icons.broken_image_outlined);
        if (!snapshot.hasData) return const SizedBox(height: 180, child: Center(child: CircularProgressIndicator(color: circleGold)));
        return Image.memory((snapshot.data! is Uint8List ? snapshot.data! as Uint8List : Uint8List.fromList(snapshot.data!)), width: double.infinity, height: widget.compact ? 160 : 345, fit: BoxFit.contain,
          cacheWidth: widget.compact ? 800 : 1600, gaplessPlayback: true);
      }));
    }
    if (widget.mime.startsWith('video/')) {
      if (controller != null) return ClipRRect(borderRadius: BorderRadius.circular(14), child: AspectRatio(aspectRatio: 16 / 9, child: Video(controller: controller!, controls: MaterialVideoControls)));
      return InkWell(onTap: _prepare, child: Container(height: widget.compact ? 120 : 260, decoration: BoxDecoration(color: circlePanel2, borderRadius: BorderRadius.circular(14)), child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(preparing ? Icons.hourglass_empty : Icons.play_circle_outline, size: 48, color: circleGold),
        const SizedBox(height: 10), Text(preparing ? 'Загружаю видео...' : 'Воспроизвести видео'),
      ]))));
    }
    return Container(padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8), decoration: BoxDecoration(color: circleGold.withValues(alpha: .09), borderRadius: BorderRadius.circular(12)), child: Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(tooltip: playing ? 'Пауза' : 'Воспроизвести', onPressed: () async {
        if (player == null) {await _prepare(); return;}
        await player!.playOrPause();
        if (mounted) setState(() => playing = !playing);
      }, icon: Icon(preparing ? Icons.hourglass_bottom : playing ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 30, color: circleGold)),
      const SizedBox(width: 8), const Icon(Icons.graphic_eq, color: circleGold), const SizedBox(width: 9),
      if (player == null) const Text('Голосовое сообщение', style: TextStyle(fontSize: 12))
      else SizedBox(width: widget.compact ? 150 : 240, child: StreamBuilder<Duration>(
        stream: player!.stream.position,
        builder: (context, snapshot) {
          final maxMs = player!.state.duration.inMilliseconds;
          final maxValue = maxMs > 0 ? maxMs.toDouble() : 1.0;
          final current = (snapshot.data?.inMilliseconds ?? 0).clamp(0, maxMs > 0 ? maxMs : 1).toDouble();
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Slider(value: current, max: maxValue, activeColor: circleGold, onChanged: maxMs == 0 ? null : (value) => player?.seek(Duration(milliseconds: value.round()))),
            Text('${_clock(Duration(milliseconds: current.round()))} / ${_clock(player!.state.duration)}', style: const TextStyle(color: circleMuted, fontSize: 10)),
          ]);
        },
      )),
    ]));
  }
}
