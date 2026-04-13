import 'package:sgtp_flutter/core/network/events/network_event.dart';

enum SgtpConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class SgtpConnectionStateChanged extends NetworkEvent {
  const SgtpConnectionStateChanged({
    required this.status,
    this.errorMessage,
  });

  final SgtpConnectionStatus status;
  final String? errorMessage;

  @override
  String get type => 'sgtp.connection.state_changed';
}
