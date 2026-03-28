import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// sessionUUID → nickname (resolved from whitelist file names).
  final Map<String, String> peerNicknames;

  const MessageBubble({
    super.key,
    required this.message,
    this.peerNicknames = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final cs      = theme.colorScheme;
    final isMe    = message.isFromMe;
    final bgColor = isMe ? cs.primaryContainer : cs.surfaceContainerHighest;
    final textColor = isMe ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    final timeStr = _formatTime(message.receivedAt);

    // Nickname: "nick | uuid[0:8]" or just "uuid[0:8]" if no nick found
    final senderLabel = _buildSenderLabel();

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Container(
          margin: EdgeInsets.only(
            left: isMe ? 48 : 8,
            right: isMe ? 8 : 48,
            top: 4,
            bottom: 4,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
          ),
          child: _buildContent(
              context, theme, textColor, senderLabel, timeStr, isMe),
        ),
      ),
    );
  }

  String _buildSenderLabel() {
    if (message.isFromMe) return 'Me';
    final short = message.senderUUID.length >= 8
        ? message.senderUUID.substring(0, 8)
        : message.senderUUID;
    final nick = peerNicknames[message.senderUUID];
    return nick != null ? '$nick | $short' : short;
  }

  Widget _buildContent(BuildContext context, ThemeData theme, Color textColor,
      String senderLabel, String timeStr, bool isMe) {
    switch (message.type) {
      case MessageType.image:
        return _buildImageContent(context, theme, textColor, senderLabel,
            timeStr, isMe,
            animated: false);
      case MessageType.gif:
        return _buildImageContent(context, theme, textColor, senderLabel,
            timeStr, isMe,
            animated: true);
      case MessageType.video:
        return _buildVideoContent(
            context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.voice:
        return _buildVoiceContent(
            context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.text:
        return _buildTextContent(
            theme, textColor, senderLabel, timeStr, isMe);
    }
  }

  // ── Text ──────────────────────────────────────────────────────────────────

  Widget _buildTextContent(ThemeData theme, Color textColor, String senderLabel,
      String timeStr, bool isMe) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe) _senderLabel(theme, senderLabel),
          const SizedBox(height: 2),
          Text(message.content,
              style: theme.textTheme.bodyMedium?.copyWith(color: textColor)),
          const SizedBox(height: 4),
          _timeLabel(theme, textColor, timeStr),
        ],
      ),
    );
  }

  // ── Image / GIF ───────────────────────────────────────────────────────────

  Widget _buildImageContent(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe, {
    required bool animated,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(16),
        topRight: const Radius.circular(16),
        bottomLeft: Radius.circular(isMe ? 16 : 4),
        bottomRight: Radius.circular(isMe ? 4 : 16),
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _senderLabel(theme, senderLabel),
            ),
          GestureDetector(
            onTap: () => _showFullImage(context),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: Image.memory(
                message.imageBytes!,
                fit: BoxFit.contain,
                gaplessPlayback: animated,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.broken_image_outlined, size: 48),
                ),
              ),
            ),
          ),
          if (animated)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.gif_box_outlined,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: _timeLabel(theme, textColor, timeStr),
          ),
        ],
      ),
    );
  }

  void _showFullImage(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.memory(message.imageBytes!, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Video ─────────────────────────────────────────────────────────────────

  Widget _buildVideoContent(BuildContext context, ThemeData theme,
      Color textColor, String senderLabel, String timeStr, bool isMe) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe) _senderLabel(theme, senderLabel),
          const SizedBox(height: 4),
          _VideoThumbnail(
            videoBytes: message.videoBytes!,
            mediaName: message.mediaName ?? 'video',
          ),
          const SizedBox(height: 4),
          _timeLabel(theme, textColor, timeStr),
        ],
      ),
    );
  }

  // ── Voice ─────────────────────────────────────────────────────────────────

  Widget _buildVoiceContent(BuildContext context, ThemeData theme,
      Color textColor, String senderLabel, String timeStr, bool isMe) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe) _senderLabel(theme, senderLabel),
          const SizedBox(height: 4),
          _VoicePlayer(
            audioBytes: message.audioBytes!,
            mediaMime: message.mediaMime ?? 'audio/m4a',
          ),
          const SizedBox(height: 4),
          _timeLabel(theme, textColor, timeStr),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _senderLabel(ThemeData theme, String label) => Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      );

  Widget _timeLabel(ThemeData theme, Color textColor, String timeStr) =>
      Text(
        '${message.isFromHistory ? '~ ' : ''}$timeStr',
        style:
            theme.textTheme.labelSmall?.copyWith(color: textColor.withAlpha(160)),
      );

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ─── Video thumbnail + inline player (media_kit) ──────────────────────────────

class _VideoThumbnail extends StatefulWidget {
  final Uint8List videoBytes;
  final String mediaName;

  const _VideoThumbnail({required this.videoBytes, required this.mediaName});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  Player? _player;
  VideoController? _controller;
  bool _loading     = false;
  bool _initialized = false;
  String? _tmpPath;

  @override
  void dispose() {
    _player?.dispose();
    if (_tmpPath != null) File(_tmpPath!).delete().catchError((_) {});
    super.dispose();
  }

  Future<void> _init() async {
    if (_initialized || _loading) return;
    setState(() => _loading = true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final ext    = widget.mediaName.split('.').last;
      final file   = File('${tmpDir.path}/${widget.mediaName.hashCode}.$ext');
      if (!file.existsSync()) {
        await file.writeAsBytes(widget.videoBytes);
      }
      _tmpPath = file.path;

      final player     = Player();
      final controller = VideoController(player);
      await player.open(Media('file://${file.path}'), play: false);

      if (mounted) {
        setState(() {
          _player      = player;
          _controller  = controller;
          _initialized = true;
          _loading     = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Video load error: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        ));
      }
    }
  }

  Future<void> _togglePlay() async {
    if (!_initialized) {
      await _init();
      await _player?.play();
      return;
    }
    await _player?.playOrPause();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_initialized && _controller != null)
                    Video(controller: _controller!)
                  else
                    Container(
                      color: cs.surfaceContainerHighest,
                      child: Icon(Icons.videocam_outlined,
                          size: 48,
                          color: cs.onSurfaceVariant.withAlpha(120)),
                    ),
                  GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      color: Colors.transparent,
                      child: _loading
                          ? Container(
                              decoration: BoxDecoration(
                                color: cs.primaryContainer.withAlpha(200),
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(12),
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: cs.onPrimaryContainer),
                              ),
                            )
                          : (!_initialized
                              ? Container(
                                  decoration: BoxDecoration(
                                    color: cs.primaryContainer.withAlpha(200),
                                    shape: BoxShape.circle,
                                  ),
                                  padding: const EdgeInsets.all(12),
                                  child: Icon(Icons.play_arrow_rounded,
                                      size: 28, color: cs.onPrimaryContainer),
                                )
                              : const SizedBox.shrink()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_initialized && _player != null) ...[
            const SizedBox(height: 4),
            StreamBuilder<Duration>(
              stream: _player!.stream.position,
              builder: (context, posSnap) {
                final pos = posSnap.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: _player!.stream.duration,
                  builder: (context, durSnap) {
                    final dur = durSnap.data ?? Duration.zero;
                    final progress = dur.inMilliseconds == 0
                        ? 0.0
                        : (pos.inMilliseconds / dur.inMilliseconds)
                            .clamp(0.0, 1.0);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape:
                                const RoundSliderThumbShape(enabledThumbRadius: 5),
                            overlayShape:
                                const RoundSliderOverlayShape(overlayRadius: 10),
                          ),
                          child: Slider(
                            value: progress,
                            onChanged: dur.inMilliseconds > 0
                                ? (v) {
                                    final seek = Duration(
                                        milliseconds:
                                            (v * dur.inMilliseconds).round());
                                    _player!.seek(seek);
                                  }
                                : null,
                            activeColor: cs.primary,
                            inactiveColor: cs.outline.withAlpha(80),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_fmt(pos),
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: cs.onSurfaceVariant)),
                              Text(_fmt(dur),
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                widget.mediaName,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ─── Voice player ─────────────────────────────────────────────────────────────

class _VoicePlayer extends StatefulWidget {
  final Uint8List audioBytes;
  final String mediaMime;

  const _VoicePlayer({required this.audioBytes, required this.mediaMime});

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final _player    = AudioPlayer();
  bool _playing    = false;
  bool _loading    = false;
  /// true once we've fetched metadata (duration) even without playing
  bool _metaReady  = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _tmpPath;

  @override
  void initState() {
    super.initState();

    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s.name == 'playing');
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() { _duration = d; _metaReady = true; });
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    });

    // Prefetch duration so the timeline shows before first play
    _prefetchDuration();
  }

  @override
  void dispose() {
    _player.dispose();
    if (_tmpPath != null) File(_tmpPath!).delete().catchError((_) {});
    super.dispose();
  }

  /// Write bytes to a tmp file and load metadata without playing.
  Future<void> _prefetchDuration() async {
    try {
      await _prepareTmp();
      // setSourceDeviceFile triggers onDurationChanged without starting playback
      await _player.setSourceDeviceFile(_tmpPath!);
    } catch (_) {
      // Non-fatal: user can still hit Play and it will work
    }
  }

  Future<void> _prepareTmp() async {
    if (_tmpPath != null) return;
    final tmpDir = await getTemporaryDirectory();
    final ext    = _mimeToExt(widget.mediaMime);
    final file   = File(
        '${tmpDir.path}/voice_play_${widget.audioBytes.hashCode}.$ext');
    if (!file.existsSync()) {
      await file.writeAsBytes(widget.audioBytes);
    }
    _tmpPath = file.path;
  }

  String _mimeToExt(String mime) => switch (mime) {
        'audio/m4a'  => 'm4a',
        'audio/aac'  => 'aac',
        'audio/opus' => 'opus',
        'audio/mpeg' => 'mp3',
        _            => 'audio',
      };

  Future<void> _togglePlay() async {
    if (_loading) return;

    if (_playing) {
      await _player.pause();
      return;
    }

    setState(() => _loading = true);
    try {
      await _prepareTmp();
      await _player.play(DeviceFileSource(_tmpPath!));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Playback error: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        ));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _seek(double value) async {
    final pos =
        Duration(milliseconds: (value * _duration.inMilliseconds).round());
    await _player.seek(pos);
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final cs       = theme.colorScheme;
    final progress = _duration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);

    // Show "--:--" until metadata is loaded (instead of "00:00")
    final durationLabel = _metaReady ? _fmt(_duration) : '--:--';

    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 40,
              height: 40,
              decoration:
                  BoxDecoration(color: cs.primary, shape: BoxShape.circle),
              child: _loading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: cs.onPrimary),
                    )
                  : Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      color: cs.onPrimary,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: progress,
                    onChanged:
                        _duration.inMilliseconds > 0 ? _seek : null,
                    activeColor: cs.primary,
                    inactiveColor: cs.outline.withAlpha(80),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(_position),
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                      Text(durationLabel,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.mic, size: 14, color: cs.primary),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
