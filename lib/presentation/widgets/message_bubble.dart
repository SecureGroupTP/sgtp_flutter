import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isMe = message.isFromMe;

    final bgColor = isMe ? cs.primaryContainer : cs.surfaceContainerHighest;
    final textColor = isMe ? cs.onPrimaryContainer : cs.onSurfaceVariant;

    final timeStr = _formatTime(message.receivedAt);
    final senderLabel = isMe ? 'Me' : message.senderUUID.substring(0, 8);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
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
          child: _buildContent(context, theme, textColor, senderLabel, timeStr, isMe),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe,
  ) {
    switch (message.type) {
      case MessageType.image:
        return _buildImageContent(context, theme, textColor, senderLabel, timeStr, isMe, animated: false);
      case MessageType.gif:
        return _buildImageContent(context, theme, textColor, senderLabel, timeStr, isMe, animated: true);
      case MessageType.video:
        return _buildVideoContent(context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.voice:
        return _buildVoiceContent(context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.text:
        return _buildTextContent(theme, textColor, senderLabel, timeStr, isMe);
    }
  }

  // ── Text ──────────────────────────────────────────────────────────────────

  Widget _buildTextContent(
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _senderLabel(theme, senderLabel),
            ),
          GestureDetector(
            onTap: () => _showFullImage(context),
            child: Image.memory(
              message.imageBytes!,
              fit: BoxFit.cover,
              // gaplessPlayback: animated allows GIF animation to loop
              gaplessPlayback: animated,
              errorBuilder: (_, __, ___) => const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.broken_image_outlined, size: 48),
              ),
            ),
          ),
          if (animated)
            Padding(
              padding: const EdgeInsets.only(right: 4, top: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.gif_box_outlined, size: 16, color: theme.colorScheme.primary),
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

  Widget _buildVideoContent(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe,
  ) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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

  Widget _buildVoiceContent(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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

  Widget _timeLabel(ThemeData theme, Color textColor, String timeStr) => Text(
        '${message.isFromHistory ? '~ ' : ''}$timeStr',
        style: theme.textTheme.labelSmall?.copyWith(color: textColor.withAlpha(160)),
      );

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ─── Video thumbnail / player widget ─────────────────────────────────────────

class _VideoThumbnail extends StatefulWidget {
  final Uint8List videoBytes;
  final String mediaName;

  const _VideoThumbnail({required this.videoBytes, required this.mediaName});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  bool _loading = false;

  Future<void> _openVideo(BuildContext context) async {
    if (_loading) return;
    setState(() => _loading = true);

    try {
      final tmpDir = await getTemporaryDirectory();
      final ext = widget.mediaName.split('.').last;
      final file = File('${tmpDir.path}/${widget.mediaName.hashCode}.$ext');
      await file.writeAsBytes(widget.videoBytes);

      if (!context.mounted) return;
      await _showVideoDialog(context, file.path);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Cannot open video: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showVideoDialog(BuildContext context, String filePath) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _VideoPlayerDialog(filePath: filePath),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => _openVideo(context),
      child: Container(
        width: 220,
        height: 140,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outline.withAlpha(80)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.videocam_outlined, size: 48,
                color: theme.colorScheme.onSurfaceVariant.withAlpha(120)),
            if (_loading)
              const CircularProgressIndicator()
            else
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(12),
                child: Icon(Icons.play_arrow_rounded, size: 32,
                    color: theme.colorScheme.onPrimaryContainer),
              ),
            Positioned(
              bottom: 8,
              left: 8,
              child: Text(
                widget.mediaName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoPlayerDialog extends StatefulWidget {
  final String filePath;
  const _VideoPlayerDialog({required this.filePath});

  @override
  State<_VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<_VideoPlayerDialog> {
  // NOTE: video_player package is used here. Add to pubspec.yaml:
  //   video_player: ^2.9.2
  // For now we show a placeholder if the package is not available.

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.video_file_outlined, size: 64, color: Colors.white54),
                  const SizedBox(height: 16),
                  Text(
                    widget.filePath.split('/').last,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Video saved to device storage.\nAdd video_player package for inline playback.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
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
    );
  }
}

// ─── Voice player widget ──────────────────────────────────────────────────────

class _VoicePlayer extends StatefulWidget {
  final Uint8List audioBytes;
  final String mediaMime;

  const _VoicePlayer({required this.audioBytes, required this.mediaMime});

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  bool _playing = false;
  bool _preparing = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _tmpPath;

  @override
  void dispose() {
    _stopPlayback();
    super.dispose();
  }

  Future<void> _prepareTmpFile() async {
    if (_tmpPath != null) return;
    final tmpDir = await getTemporaryDirectory();
    final ext = _mimeToExt(widget.mediaMime);
    final file = File('${tmpDir.path}/voice_${widget.audioBytes.hashCode}.$ext');
    if (!file.existsSync()) {
      await file.writeAsBytes(widget.audioBytes);
    }
    _tmpPath = file.path;
  }

  String _mimeToExt(String mime) {
    return switch (mime) {
      'audio/m4a' => 'm4a',
      'audio/aac' => 'aac',
      'audio/opus' => 'opus',
      'audio/mpeg' => 'mp3',
      _ => 'audio',
    };
  }

  Future<void> _togglePlay() async {
    if (_preparing) return;
    setState(() => _preparing = true);

    try {
      await _prepareTmpFile();
      // NOTE: Use audioplayers or just_audio package for actual playback.
      // Add to pubspec.yaml: audioplayers: ^6.1.0
      // For now, just toggle the visual state as placeholder.
      setState(() {
        _playing = !_playing;
        _preparing = false;
      });
    } catch (e) {
      setState(() => _preparing = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Cannot play audio: $e')));
      }
    }
  }

  void _stopPlayback() {
    _playing = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
              child: _preparing
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
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
              children: [
                // Waveform placeholder
                CustomPaint(
                  size: const Size(double.infinity, 24),
                  painter: _WaveformPainter(
                    progress: _position.inMilliseconds /
                        (_duration.inMilliseconds == 0
                            ? 1
                            : _duration.inMilliseconds),
                    color: cs.primary,
                    backgroundColor: cs.outline.withAlpha(60),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatDuration(_playing ? _position : _duration),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.mic, size: 16, color: cs.primary),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color backgroundColor;

  const _WaveformPainter({
    required this.progress,
    required this.color,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeCap = StrokeCap.round..strokeWidth = 2.5;
    const barCount = 28;
    final barWidth = size.width / (barCount * 2);
    final rng = [0.4, 0.8, 0.5, 1.0, 0.6, 0.9, 0.3, 0.7, 0.5, 0.85,
                  0.4, 0.65, 0.9, 0.5, 0.75, 0.3, 0.8, 0.6, 0.95, 0.4,
                  0.7, 0.55, 0.85, 0.45, 0.75, 0.35, 0.6, 0.5];

    for (int i = 0; i < barCount; i++) {
      final x = barWidth + i * barWidth * 2;
      final fraction = i / barCount;
      paint.color = fraction <= progress ? color : backgroundColor;
      final h = (rng[i % rng.length] * size.height).clamp(4.0, size.height);
      final top = (size.height - h) / 2;
      canvas.drawLine(Offset(x, top), Offset(x, top + h), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.color != color;
}
