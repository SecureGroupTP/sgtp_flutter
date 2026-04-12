import 'package:format/format.dart';
import 'package:logging/logging.dart';

// ── Structured log payload ─────────────────────────────────────────────────

/// Carried as [LogRecord.object] through the logging pipeline.
///
/// [LogRecord.message] holds the already-rendered human-readable string
/// (result of [toString]). Listeners that want structured data cast
/// `record.object as LogPayload`.
class LogPayload {
  final String message;
  final String messageTemplate;
  final Map<String, Object?> parameters;

  const LogPayload({
    required this.message,
    required this.messageTemplate,
    required this.parameters,
  });

  @override
  String toString() => message;
}

// ── AppLog wrapper ─────────────────────────────────────────────────────────

/// Per-class structured logger.
///
/// Usage:
/// ```dart
/// final _log = AppLog('MyClassName');
///
/// _log.debug('Connected to {host}:{port}', parameters: {'host': host, 'port': port});
/// _log.error('Failed: {error}', parameters: {'error': e}, error: e, stackTrace: st);
/// ```
///
/// One [AppLog] instance owns one [Logger] from the `logging` package.
/// Listeners wired in [LogSetup] handle console printing and file writing.
class AppLog {
  final Logger _logger;

  AppLog(String name) : _logger = Logger(name);

  String get name => _logger.name;

  void debug(
    String messageTemplate, {
    Map<String, Object?>? parameters,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _emit(Level.FINE, messageTemplate, parameters, error, stackTrace);

  void info(
    String messageTemplate, {
    Map<String, Object?>? parameters,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _emit(Level.INFO, messageTemplate, parameters, error, stackTrace);

  void warning(
    String messageTemplate, {
    Map<String, Object?>? parameters,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _emit(Level.WARNING, messageTemplate, parameters, error, stackTrace);

  void error(
    String messageTemplate, {
    Map<String, Object?>? parameters,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _emit(Level.SEVERE, messageTemplate, parameters, error, stackTrace);

  // ── Internal ──────────────────────────────────────────────────────────────

  void _emit(
    Level level,
    String messageTemplate,
    Map<String, Object?>? parameters,
    Object? error,
    StackTrace? stackTrace,
  ) {
    final params = parameters ?? const {};
    final message = params.isEmpty
        ? messageTemplate
        : messageTemplate.format(params);
    final payload = LogPayload(
      message: message,
      messageTemplate: messageTemplate,
      parameters: params,
    );
    _logger.log(level, payload, error, stackTrace);
  }
}
