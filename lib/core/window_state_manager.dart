import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sgtp_flutter/core/app_log.dart';

final _log = AppLog('WindowStateManager');

/// Manages window state for desktop platforms (Windows, macOS, Linux).
/// Persists window width/height between application launches.
class WindowStateManager {
  static const String _stateFile = '.window_state.json';

  /// Get the application documents directory
  Future<Directory> _getAppDir() async {
    return getApplicationDocumentsDirectory();
  }

  /// Get the window state file path
  Future<File> _getStateFile() async {
    final appDir = await _getAppDir();
    return File('${appDir.path}/$_stateFile');
  }

  /// Save current window size
  Future<void> saveWindowSize(int width, int height) async {
    if (!_isDesktop()) return;

    try {
      final file = await _getStateFile();
      final state = {
        'windowWidth': width,
        'windowHeight': height,
        'savedAt': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(state), flush: true);
      _log.debug('[WindowState] Saved: {width}x{height}', parameters: {'width': width, 'height': height});
    } catch (e) {
      _log.warning('[WindowState] Error saving: {error}', parameters: {'error': e});
    }
  }

  /// Load saved window size
  /// Returns (width, height) or null if not found/error
  Future<(int, int)?> loadWindowSize() async {
    if (!_isDesktop()) return null;

    try {
      final file = await _getStateFile();
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      final width = json['windowWidth'] as int?;
      final height = json['windowHeight'] as int?;

      if (width != null && height != null) {
        _log.debug('[WindowState] Loaded: {width}x{height}', parameters: {'width': width, 'height': height});
        return (width, height);
      }
    } catch (e) {
      _log.warning('[WindowState] Error loading: {error}', parameters: {'error': e});
    }
    return null;
  }

  /// Check if running on a desktop platform
  bool _isDesktop() {
    return !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  }
}

// Global instance
final windowStateManager = WindowStateManager();
