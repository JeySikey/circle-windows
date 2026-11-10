import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'design.dart';

/// Native LiveKit audio/video view. A PHP-authenticated token is obtained by
/// the caller immediately before entry and is never logged or persisted.
class CircleLiveRoom extends StatefulWidget {
  const CircleLiveRoom({super.key, required this.title, required this.credentials, this.onFinish, this.startVideo = false});
  final String title;
  final Future<Map<String, dynamic>> Function() credentials;
  final Future<void> Function()? onFinish;
  final bool startVideo;
  @override State<CircleLiveRoom> createState() => _CircleLiveRoomState();
}
class _CircleLiveRoomState extends State<CircleLiveRoom> {
  Room? room;
  bool connected = false;
  bool microphone = true;
  bool camera = false;
  bool closing = false;
  String error = '';
  @override void initState() {super.initState(); connect();}
  void updated() {if (mounted) setState(() {});}
  Future<void> connect() async {
    Room? candidate;
    try {
      final credentials = await widget.credentials();
      final url = '${credentials['url'] ?? ''}';
      final token = '${credentials['token'] ?? ''}';
      if (!url.startsWith('wss://') || token.isEmpty) throw StateError('Сервер не предоставил безопасные параметры подключения LiveKit');
      candidate = Room();
      candidate.addListener(updated);
      await candidate.connect(url, token, roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true));
      await candidate.localParticipant?.setMicrophoneEnabled(true);
      if (widget.startVideo) await candidate.localParticipant?.setCameraEnabled(true);
      if (!mounted) {await candidate.disconnect(); await candidate.dispose(); return;}
      setState(() {room = candidate; connected = true; camera = widget.startVideo;});
      candidate = null;
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось подключиться к звонку: $e');
      if (candidate != null) {candidate.removeListener(updated); await candidate.dispose();}
    }
  }
  Future<void> setMic() async {
    try {await room?.localParticipant?.setMicrophoneEnabled(!microphone); if (mounted) setState(() => microphone = !microphone);}
    catch (e) {if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Микрофон: $e')));}
  }
  Future<void> setCamera() async {
    try {await room?.localParticipant?.setCameraEnabled(!camera); if (mounted) setState(() => camera = !camera);}
    catch (e) {if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Камера: $e')));}
  }
  Future<void> finish() async {
    if (closing) return;
    setState(() => closing = true);
    try {
      await room?.disconnect();
      await widget.onFinish?.call();
    } catch (_) { /* The server will expire abandoned calls automatically. */ }
    if (mounted) Navigator.pop(context);
  }
  @override void dispose() {
    room?.removeListener(updated);
    room?.disconnect();
    room?.dispose();
    super.dispose();
  }
  @override Widget build(BuildContext context) {
    final remote = room?.remoteParticipants.values.toList() ?? [];
    final local = room?.localParticipant;
    return PopScope(canPop: closing, onPopInvokedWithResult: (didPop, _) {if (!didPop) finish();}, child: Scaffold(
      appBar: AppBar(title: Text(widget.title), automaticallyImplyLeading: false, actions: [const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Center(child: Text('LIVE', style: TextStyle(color: circleGold, letterSpacing: 2, fontWeight: FontWeight.w800))))]),
      body: Column(children: [
        Expanded(child: error.isNotEmpty ? CircleEmpty(title: 'Соединение не установлено', description: error, icon: Icons.wifi_off) : !connected ? const Center(child: CircularProgressIndicator(color: circleGold)) : Padding(padding: const EdgeInsets.all(23), child: LayoutBuilder(builder: (context, constraints) {
          final tiles = <Widget>[
            _personCard(local?.name.isNotEmpty == true ? local!.name : 'Вы', local == null ? null : _video(local.videoTrackPublications.map((p) => p.track).toList()), isLocal: true),
            for (final participant in remote) _personCard(participant.name.isNotEmpty ? participant.name : participant.identity, _video(participant.videoTrackPublications.map((p) => p.track).toList())),
          ];
          final columns = constraints.maxWidth > 950 ? 3 : constraints.maxWidth > 560 ? 2 : 1;
          final tileWidth = (constraints.maxWidth - 14 * (columns - 1)) / columns;
          return SingleChildScrollView(child: Wrap(spacing: 14, runSpacing: 14, children: [for (final tile in tiles) SizedBox(width: tileWidth, height: 270, child: tile)]));
        }))),
        Container(padding: const EdgeInsets.all(17), decoration: BoxDecoration(color: circlePanel, border: Border(top: BorderSide(color: Theme.of(context).dividerColor))), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          OutlinedButton.icon(onPressed: connected ? setMic : null, icon: Icon(microphone ? Icons.mic : Icons.mic_off), label: Text(microphone ? 'Микрофон' : 'Выключен')),
          const SizedBox(width: 12), OutlinedButton.icon(onPressed: connected ? setCamera : null, icon: Icon(camera ? Icons.videocam : Icons.videocam_off), label: Text(camera ? 'Камера' : 'Без видео')),
          const SizedBox(width: 12), FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: circleRed, foregroundColor: Colors.white), onPressed: closing ? null : finish, icon: const Icon(Icons.call_end), label: const Text('Завершить')),
        ])),
      ]),
    ));
  }
  VideoTrack? _video(List<VideoTrack?> tracks) {
    for (final track in tracks) {if (track != null) return track;}
    return null;
  }
  Widget _personCard(String name, VideoTrack? video, {bool isLocal = false}) => CircleSurface(padding: EdgeInsets.zero, child: ClipRRect(borderRadius: BorderRadius.circular(17), child: Stack(fit: StackFit.expand, children: [
    if (video != null) VideoTrackRenderer(video) else Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.person_outline, color: circleGold, size: 52), const SizedBox(height: 12), Text(name, style: const TextStyle(fontWeight: FontWeight.w700))])),
    Positioned(left: 12, bottom: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .7), borderRadius: BorderRadius.circular(8)), child: Text(isLocal ? '$name · Вы' : name, style: const TextStyle(color: Colors.white, fontSize: 12)))),
  ])));
}
