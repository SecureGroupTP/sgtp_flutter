import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

class VideoNoteMetadata extends Equatable {
  final int durationMs;
  final int width;
  final int height;
  final bool hasAudio;
  final int fileSizeBytes;
  final Uint8List? thumbnailBytes;
  final int thumbnailWidth;
  final int thumbnailHeight;
  final int thumbnailSourceTimestampMs;
  final String? dominantColorHex;

  const VideoNoteMetadata({
    required this.durationMs,
    required this.width,
    required this.height,
    required this.hasAudio,
    required this.fileSizeBytes,
    this.thumbnailBytes,
    this.thumbnailWidth = 0,
    this.thumbnailHeight = 0,
    this.thumbnailSourceTimestampMs = 0,
    this.dominantColorHex,
  });

  Map<String, dynamic> toPayloadJson() => {
        'duration_seconds': durationMs / 1000,
        'dimensions': {
          'width': width,
          'height': height,
        },
        'has_audio': hasAudio,
        'file_size_bytes': fileSizeBytes,
        if (thumbnailBytes != null)
          'thumbnail': {
            'data': base64.encode(thumbnailBytes!),
            'width': thumbnailWidth,
            'height': thumbnailHeight,
            'source_timestamp_ms': thumbnailSourceTimestampMs,
            if (dominantColorHex != null) 'dominant_color': dominantColorHex,
          },
      };

  static VideoNoteMetadata? fromPayloadJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final dimensions = map['dimensions'] is Map
        ? Map<String, dynamic>.from(map['dimensions'] as Map)
        : const <String, dynamic>{};
    final thumb = map['thumbnail'] is Map
        ? Map<String, dynamic>.from(map['thumbnail'] as Map)
        : const <String, dynamic>{};
    final thumbData = thumb['data'] as String?;
    return VideoNoteMetadata(
      durationMs:
          (((map['duration_seconds'] as num?) ?? 0).toDouble() * 1000).round(),
      width: (dimensions['width'] as num?)?.toInt() ?? 0,
      height: (dimensions['height'] as num?)?.toInt() ?? 0,
      hasAudio: (map['has_audio'] as bool?) ?? false,
      fileSizeBytes: (map['file_size_bytes'] as num?)?.toInt() ?? 0,
      thumbnailBytes: thumbData == null ? null : base64.decode(thumbData),
      thumbnailWidth: (thumb['width'] as num?)?.toInt() ?? 0,
      thumbnailHeight: (thumb['height'] as num?)?.toInt() ?? 0,
      thumbnailSourceTimestampMs:
          (thumb['source_timestamp_ms'] as num?)?.toInt() ?? 0,
      dominantColorHex: thumb['dominant_color'] as String?,
    );
  }

  @override
  List<Object?> get props => [
        durationMs,
        width,
        height,
        hasAudio,
        fileSizeBytes,
        thumbnailBytes,
        thumbnailWidth,
        thumbnailHeight,
        thumbnailSourceTimestampMs,
        dominantColorHex,
      ];
}
