import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../domain/entities/video_note_metadata.dart';

class PreparedVideoNote {
  final XFile xFile;
  final String mime;
  final VideoNoteMetadata metadata;

  const PreparedVideoNote({
    required this.xFile,
    required this.mime,
    required this.metadata,
  });
}

class VideoNotePipeline {
  static const int targetSize = 480;
  static const int maxDurationSeconds = 60;

  static Future<PreparedVideoNote> prepare({
    required XFile sourceFile,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Video note processing is not supported on web.');
    }

    final tmpDir = await getTemporaryDirectory();
    final basename = DateTime.now().millisecondsSinceEpoch;
    final normalizedPath = '${tmpDir.path}/videonote_$basename.mp4';

    final filters = <String>[
      'crop=min(iw\\,ih):min(iw\\,ih):(iw-min(iw\\,ih))/2:(ih-min(iw\\,ih))/2',
      'scale=$targetSize:$targetSize:flags=bicubic',
      'setsar=1',
      'setdar=1',
      'format=yuv420p',
    ];

    await _runFfmpeg([
      '-y',
      '-i',
      sourceFile.path,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-vf',
      filters.join(','),
      '-r',
      '30',
      '-c:v',
      'libx264',
      '-profile:v',
      'baseline',
      '-level',
      '3.0',
      '-pix_fmt',
      'yuv420p',
      '-preset',
      'veryfast',
      '-b:v',
      '1000k',
      '-g',
      '30',
      '-keyint_min',
      '30',
      '-c:a',
      'aac',
      '-ac',
      '1',
      '-ar',
      '44100',
      '-b:a',
      '64k',
      '-movflags',
      '+faststart',
      '-shortest',
      '-t',
      '$maxDurationSeconds',
      '-metadata:s:v:0',
      'rotate=0',
      normalizedPath,
    ]);

    final videoFile = File(normalizedPath);
    final fileSize = await videoFile.length();
    final mediaInfo = await _probeMediaInfo(normalizedPath);
    final durationMs = mediaInfo.durationMs.clamp(0, maxDurationSeconds * 1000);

    final thumbnail = await _buildThumbnail(normalizedPath, tmpDir.path);

    return PreparedVideoNote(
      xFile: XFile(normalizedPath),
      mime: 'video/mp4',
      metadata: VideoNoteMetadata(
        durationMs: durationMs,
        width: targetSize,
        height: targetSize,
        hasAudio: mediaInfo.hasAudio,
        fileSizeBytes: fileSize,
        thumbnailBytes: thumbnail.bytes,
        thumbnailWidth: thumbnail.width,
        thumbnailHeight: thumbnail.height,
        thumbnailSourceTimestampMs: thumbnail.timestampMs,
        dominantColorHex: thumbnail.dominantColorHex,
      ),
    );
  }

  static Future<void> _runFfmpeg(List<String> arguments) async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      final session = await FFmpegKit.execute(_quoteArgs(arguments));
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        throw StateError('ffmpeg normalize failed: $logs');
      }
      return;
    }

    final result = await Process.run('ffmpeg', arguments);
    if (result.exitCode != 0) {
      throw StateError('ffmpeg normalize failed: ${result.stderr}');
    }
  }

  static Future<_MediaProbeResult> _probeMediaInfo(String path) async {
    final arguments = [
      '-i',
      path,
      '-f',
      'null',
      '-',
    ];

    String logs = '';
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      final session = await FFmpegKit.execute(_quoteArgs(arguments));
      logs = await session.getAllLogsAsString() ?? '';
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) &&
          !(logs.contains('Duration:') || logs.contains('Stream #'))) {
        throw StateError('ffmpeg probe failed: $logs');
      }
    } else {
      final result = await Process.run('ffmpeg', arguments);
      logs = '${result.stdout}\n${result.stderr}';
      if (result.exitCode != 0 &&
          !(logs.contains('Duration:') || logs.contains('Stream #'))) {
        throw StateError('ffmpeg probe failed: ${result.stderr}');
      }
    }

    final durationMatch = RegExp(
      r'Duration:\s*(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?',
    ).firstMatch(logs);
    final hours = int.tryParse(durationMatch?.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(durationMatch?.group(2) ?? '') ?? 0;
    final seconds = int.tryParse(durationMatch?.group(3) ?? '') ?? 0;
    final fractionRaw = durationMatch?.group(4) ?? '0';
    final fractionMs = int.tryParse(
          fractionRaw.padRight(3, '0').substring(0, 3),
        ) ??
        0;
    final durationMs =
        (((hours * 60 + minutes) * 60) + seconds) * 1000 + fractionMs;
    final hasAudio =
        RegExp(r'Stream #.*Audio:', caseSensitive: false).hasMatch(logs);
    return _MediaProbeResult(durationMs: durationMs, hasAudio: hasAudio);
  }

  static Future<_ThumbnailResult> _buildThumbnail(
    String videoPath,
    String tempDirPath,
  ) async {
    final candidates = <int>[500, 1000, 1500, 2000, 2500];
    _ThumbnailResult? best;
    for (final ms in candidates) {
      final thumb = await _extractThumbnailAt(
        videoPath: videoPath,
        tempDirPath: tempDirPath,
        timestampMs: ms,
      );
      if (thumb == null) continue;
      if (!thumb.isBlack && !thumb.isOverexposed) {
        return thumb;
      }
      best ??= thumb;
    }

    if (best != null) return best;

    final placeholder = img.Image(width: 120, height: 120);
    img.fill(placeholder, color: img.ColorRgb8(128, 128, 128));
    return _ThumbnailResult(
      bytes: Uint8List.fromList(img.encodeJpg(placeholder, quality: 65)),
      width: 120,
      height: 120,
      timestampMs: 0,
      dominantColorHex: '#808080',
      isBlack: false,
      isOverexposed: false,
    );
  }

  static Future<_ThumbnailResult?> _extractThumbnailAt({
    required String videoPath,
    required String tempDirPath,
    required int timestampMs,
  }) async {
    final outputPath = '$tempDirPath/videonote_thumb_$timestampMs.jpg';
    try {
      await _runFfmpeg([
        '-y',
        '-ss',
        (timestampMs / 1000).toStringAsFixed(3),
        '-i',
        videoPath,
        '-frames:v',
        '1',
        '-vf',
        'scale=120:120:force_original_aspect_ratio=decrease,pad=120:120:(ow-iw)/2:(oh-ih)/2:color=black',
        '-q:v',
        '5',
        outputPath,
      ]);
    } catch (_) {
      return null;
    }
    final file = File(outputPath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    var total = 0.0;
    var r = 0;
    var g = 0;
    var b = 0;
    final pixelCount = math.max(1, decoded.width * decoded.height);
    for (final pixel in decoded) {
      total += (pixel.r + pixel.g + pixel.b) / 3;
      r += pixel.r.toInt();
      g += pixel.g.toInt();
      b += pixel.b.toInt();
    }

    final avg = total / pixelCount;
    final avgR = (r / pixelCount).round().clamp(0, 255);
    final avgG = (g / pixelCount).round().clamp(0, 255);
    final avgB = (b / pixelCount).round().clamp(0, 255);

    return _ThumbnailResult(
      bytes: bytes,
      width: decoded.width,
      height: decoded.height,
      timestampMs: timestampMs,
      dominantColorHex:
          '#${avgR.toRadixString(16).padLeft(2, '0')}${avgG.toRadixString(16).padLeft(2, '0')}${avgB.toRadixString(16).padLeft(2, '0')}',
      isBlack: avg < 15,
      isOverexposed: avg > 245,
    );
  }

  static String _quoteArgs(List<String> arguments) {
    return arguments.map((arg) {
      final escaped = arg.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      return '"$escaped"';
    }).join(' ');
  }
}

class _MediaProbeResult {
  final int durationMs;
  final bool hasAudio;

  const _MediaProbeResult({
    required this.durationMs,
    required this.hasAudio,
  });
}

class _ThumbnailResult {
  final Uint8List bytes;
  final int width;
  final int height;
  final int timestampMs;
  final String dominantColorHex;
  final bool isBlack;
  final bool isOverexposed;

  const _ThumbnailResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.timestampMs,
    required this.dominantColorHex,
    required this.isBlack,
    required this.isOverexposed,
  });
}
