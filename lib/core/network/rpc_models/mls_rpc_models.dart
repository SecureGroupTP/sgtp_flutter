import 'dart:convert';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';

class KeyPackageDto {
  final Uint8List keyPackageBytes;
  final bool isLastResort;
  final int expiresAtUs;

  const KeyPackageDto({
    required this.keyPackageBytes,
    required this.isLastResort,
    required this.expiresAtUs,
  });

  Map<String, dynamic> toMap() => {
        'keyPackageBytes': keyPackageBytes,
        'isLastResort': isLastResort,
        'expiresAt': expiresAtUs,
      };
}

class UploadKeyPackagesRequest extends RpcRequest {
  final List<KeyPackageDto> packages;

  const UploadKeyPackagesRequest({required this.packages});

  @override
  String get method => 'uploadKeyPackages';

  @override
  Map<String, dynamic> toMap() =>
      {'packages': packages.map((item) => item.toMap()).toList()};
}

class UploadKeyPackagesResponse {
  final int recordedCount;

  const UploadKeyPackagesResponse({required this.recordedCount});

  static UploadKeyPackagesResponse fromMap(Map<String, dynamic> m) =>
      UploadKeyPackagesResponse(
        recordedCount: (m['recordedCount'] as num?)?.toInt() ?? 0,
      );
}

class FetchKeyPackagesRequest extends RpcRequest {
  final List<Uint8List> userPublicKeys;

  const FetchKeyPackagesRequest({required this.userPublicKeys});

  @override
  String get method => 'fetchKeyPackages';

  @override
  Map<String, dynamic> toMap() => {'userPublicKeys': userPublicKeys};
}

class KeyPackageFetchItem {
  final Uint8List userPublicKey;
  final String deviceId;
  final Uint8List keyPackageBytes;

  const KeyPackageFetchItem({
    required this.userPublicKey,
    required this.deviceId,
    required this.keyPackageBytes,
  });

  static KeyPackageFetchItem fromMap(Map<String, dynamic> m) =>
      KeyPackageFetchItem(
        userPublicKey: _decodeBytes(m['userPublicKey']),
        deviceId: (m['deviceId'] as String?) ?? '',
        keyPackageBytes: _decodeBytes(m['keyPackageBytes']),
      );
}

class FetchKeyPackagesResponse {
  final List<KeyPackageFetchItem> items;

  const FetchKeyPackagesResponse({required this.items});

  static FetchKeyPackagesResponse fromMap(Map<String, dynamic> m) {
    final raw = (m['items'] as List?) ?? const [];
    return FetchKeyPackagesResponse(
      items: raw
          .whereType<Map>()
          .map((item) => KeyPackageFetchItem.fromMap(
              item.map((key, value) => MapEntry('$key', value))))
          .toList(),
    );
  }
}

class SendCommitRequest extends RpcRequest {
  final String roomId;
  final Uint8List commitBytes;

  const SendCommitRequest({
    required this.roomId,
    required this.commitBytes,
  });

  @override
  String get method => 'sendCommit';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'commitBytes': commitBytes,
      };
}

class SendCommitResponse {
  final int acceptedAtUs;

  const SendCommitResponse({required this.acceptedAtUs});

  static SendCommitResponse fromMap(Map<String, dynamic> m) =>
      SendCommitResponse(
        acceptedAtUs: parseTimestampUs(m['acceptedAt']),
      );
}

class SendWelcomeRequest extends RpcRequest {
  final Uint8List targetUserPublicKey;
  final Uint8List welcomeBytes;

  const SendWelcomeRequest({
    required this.targetUserPublicKey,
    required this.welcomeBytes,
  });

  @override
  String get method => 'sendWelcome';

  @override
  Map<String, dynamic> toMap() => {
        'targetUserPublicKey': targetUserPublicKey,
        'welcomeBytes': welcomeBytes,
      };
}

class SendWelcomeResponse {
  final int acceptedAtUs;

  const SendWelcomeResponse({required this.acceptedAtUs});

  static SendWelcomeResponse fromMap(Map<String, dynamic> m) =>
      SendWelcomeResponse(
        acceptedAtUs: parseTimestampUs(m['acceptedAt']),
      );
}

class MlsCommitReceivedEvent {
  final String roomId;
  final Uint8List commitBytes;

  const MlsCommitReceivedEvent({
    required this.roomId,
    required this.commitBytes,
  });

  static MlsCommitReceivedEvent fromParameters(Map<String, dynamic> m) =>
      MlsCommitReceivedEvent(
        roomId: (m['roomId'] as String?) ?? '',
        commitBytes: _decodeBytes(m['commitBytes']),
      );
}

class MlsWelcomeReceivedEvent {
  final Uint8List targetUserPublicKey;
  final Uint8List welcomeBytes;

  const MlsWelcomeReceivedEvent({
    required this.targetUserPublicKey,
    required this.welcomeBytes,
  });

  static MlsWelcomeReceivedEvent fromParameters(Map<String, dynamic> m) =>
      MlsWelcomeReceivedEvent(
        targetUserPublicKey: _decodeBytes(m['targetUserPublicKey']),
        welcomeBytes: _decodeBytes(m['welcomeBytes']),
      );
}

Uint8List _decodeBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  if (value is String) {
    try {
      return Uint8List.fromList(base64.decode(value));
    } catch (_) {
      return Uint8List(0);
    }
  }
  return Uint8List(0);
}
