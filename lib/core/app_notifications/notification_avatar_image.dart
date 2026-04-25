import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:sgtp_flutter/core/avatar/avatar_fallback.dart';

class NotificationAvatarImage {
  NotificationAvatarImage._();

  static Future<Uint8List?> resolve({
    Uint8List? avatarBytes,
    required String fallbackName,
    int size = 96,
  }) async {
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      return avatarBytes;
    }
    return _buildFallback(
      fallbackName: fallbackName,
      size: size,
    );
  }

  static Future<Uint8List?> _buildFallback({
    required String fallbackName,
    required int size,
  }) async {
    final name = AvatarFallback.normalizeName(fallbackName);
    final initial = AvatarFallback.initialForName(name);
    final gradient = AvatarFallback.gradientForName(name);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    );
    final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
    final paint = Paint()
      ..isAntiAlias = true
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        gradient.map((c) => c.toARGB32Color()).toList(),
      );
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2,
      paint,
    );

    final fontSize = (size * 0.38).clamp(22.0, 44.0);
    final textPainter = TextPainter(
      text: TextSpan(
        text: initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: fontSize.toDouble(),
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    final textOffset = Offset(
      (size - textPainter.width) / 2,
      (size - textPainter.height) / 2,
    );
    textPainter.paint(canvas, textOffset);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }
}

extension on Color {
  ui.Color toARGB32Color() => ui.Color(toARGB32());
}
