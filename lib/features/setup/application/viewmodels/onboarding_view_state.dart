import 'dart:typed_data';

import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';

class OnboardingViewState {
  const OnboardingViewState({
    this.step = 0,
    this.isVerifying = false,
    this.isSaving = false,
    this.isRestoring = false,
    this.error,
    this.resolvedHost,
    this.resolvedPort,
    this.resolvedTransport,
    this.resolvedTls = false,
    this.resolvedOptions,
    this.avatarBytes,
    this.completed = false,
  });

  final int step;
  final bool isVerifying;
  final bool isSaving;
  final bool isRestoring;
  final String? error;

  final String? resolvedHost;
  final int? resolvedPort;
  final SgtpTransportFamily? resolvedTransport;
  final bool resolvedTls;
  final SgtpServerOptions? resolvedOptions;

  final Uint8List? avatarBytes;

  /// Set to true when onboarding completes (Navigator.pop(true)).
  final bool completed;

  String? get availableTransportsLabel =>
      resolvedOptions?.availableLabels().join(', ');
}
