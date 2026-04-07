import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:sgtp_flutter/core/app_logger.dart';

/// Saves and restores desktop window size between launches.
/// Uses window_manager package (Windows / macOS / Linux only).
class WindowSizeService {
  static const String _filename = '.sgtp_window.json';
  static const Size _defaultSize = Size(1000, 720);
  static const Size _minSize = Size(640, 480);

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Call once at startup after windowManager.ensureInitialized().
  static Future<void> restoreSize() async {
    if (!_isDesktop) return;
    try {
      final saved = await _loadSize();
      final size = saved ?? _defaultSize;

      await windowManager.setMinimumSize(_minSize);
      await windowManager.setSize(size);
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();

      AppLogger.i(
        '[Window] Restored size: ${size.width.toInt()}x${size.height.toInt()}',
        tag: 'WINDOW',
        source: 'WindowSizeService',
      );
    } catch (e) {
      AppLogger.w(
        '[Window] restoreSize error: $e',
        tag: 'WINDOW',
        source: 'WindowSizeService',
      );
    }
  }

  /// Call whenever the window is resized (hook into WindowListener).
  static Future<void> saveCurrentSize() async {
    if (!_isDesktop) return;
    try {
      final size = await windowManager.getSize();
      await _saveSize(size);
    } catch (e) {
      AppLogger.w(
        '[Window] saveCurrentSize error: $e',
        tag: 'WINDOW',
        source: 'WindowSizeService',
      );
    }
  }

  // ---------------------------------------------------------------------------

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_filename');
  }

  static Future<Size?> _loadSize() async {
    try {
      final file = await _getFile();
      if (!file.existsSync()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final w = (json['width'] as num?)?.toDouble();
      final h = (json['height'] as num?)?.toDouble();
      if (w != null &&
          h != null &&
          w >= _minSize.width &&
          h >= _minSize.height) {
        return Size(w, h);
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _saveSize(Size size) async {
    try {
      final file = await _getFile();
      await file.writeAsString(jsonEncode({
        'width': size.width.toInt(),
        'height': size.height.toInt(),
        'savedAt': DateTime.now().toIso8601String(),
      }));
      AppLogger.d(
        '[Window] Saved: ${size.width.toInt()}x${size.height.toInt()}',
        tag: 'WINDOW',
        source: 'WindowSizeService',
      );
    } catch (_) {}
  }
}
