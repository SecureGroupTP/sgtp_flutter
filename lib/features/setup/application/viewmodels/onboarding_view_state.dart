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
    this.resolvedDiscoveryPort,
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
  final int? resolvedDiscoveryPort;
  final int? resolvedPort;
  final SgtpTransportFamily? resolvedTransport;
  final bool resolvedTls;
  final SgtpServerOptions? resolvedOptions;

  final Uint8List? avatarBytes;

  /// Set to true when onboarding completes (Navigator.pop(true)).
  final bool completed;

  String? get availableTransportsLabel =>
      resolvedOptions?.availableLabels().join(', ');

  List<SgtpTransportFamily> get availableTransportFamilies {
    final opts = resolvedOptions;
    if (opts == null) return const <SgtpTransportFamily>[];
    return SgtpTransportFamily.values
        .where((family) =>
            opts.supports(family, tls: false) || opts.supports(family, tls: true))
        .toList(growable: false);
  }

  bool get canChangeTransport =>
      resolvedOptions != null && availableTransportFamilies.length > 1;

  bool get tlsToggleEnabled {
    final opts = resolvedOptions;
    final transport = resolvedTransport;
    if (opts == null || transport == null) return false;
    final hasPlain = opts.supports(transport, tls: false);
    final hasTls = opts.supports(transport, tls: true);
    return hasPlain && hasTls;
  }

  bool get selectedTransportHasTls {
    final opts = resolvedOptions;
    final transport = resolvedTransport;
    if (opts == null || transport == null) return false;
    return opts.supports(transport, tls: true);
  }

  bool get selectedTransportHasPlain {
    final opts = resolvedOptions;
    final transport = resolvedTransport;
    if (opts == null || transport == null) return false;
    return opts.supports(transport, tls: false);
  }
}
