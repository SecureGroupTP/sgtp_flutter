import 'package:sgtp_flutter/core/sgtp_transport.dart';

class NodeConfig {
  final String id;
  final String accountId; // scoped profile/identity id
  final String name;
  final String host; // domain or IP, without scheme
  final int? discoveryPort;
  final int chatPort;
  final int voicePort;
  final SgtpTransportFamily transport;
  final bool useTls;
  final String fakeSni;

  const NodeConfig({
    required this.id,
    this.accountId = '',
    required this.name,
    required this.host,
    this.discoveryPort,
    required this.chatPort,
    required this.voicePort,
    this.transport = SgtpTransportFamily.tcp,
    this.useTls = false,
    this.fakeSni = '',
  });

  String get effectiveAccountId {
    final v = accountId.trim();
    return v.isEmpty ? id : v;
  }

  String get normalizedHost => _splitHostPort(host).$1;
  int? get embeddedPort => _splitHostPort(host).$2;
  int? get effectiveDiscoveryPort => discoveryPort ?? embeddedPort;

  String get chatAddress => '$normalizedHost:$chatPort';
  String get discoveryAddress =>
      effectiveDiscoveryPort != null && effectiveDiscoveryPort! > 0
          ? '$normalizedHost:$effectiveDiscoveryPort'
          : normalizedHost;

  NodeConfig copyWith({
    String? id,
    String? accountId,
    String? name,
    String? host,
    int? discoveryPort,
    int? chatPort,
    int? voicePort,
    SgtpTransportFamily? transport,
    bool? useTls,
    String? fakeSni,
  }) {
    return NodeConfig(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      host: host ?? this.host,
      discoveryPort: discoveryPort ?? this.discoveryPort,
      chatPort: chatPort ?? this.chatPort,
      voicePort: voicePort ?? this.voicePort,
      transport: transport ?? this.transport,
      useTls: useTls ?? this.useTls,
      fakeSni: fakeSni ?? this.fakeSni,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (accountId.trim().isNotEmpty) 'accountId': accountId.trim(),
        'name': name,
        'host': normalizedHost,
        if (effectiveDiscoveryPort != null) 'discoveryPort': effectiveDiscoveryPort,
        'chatPort': chatPort,
        'voicePort': voicePort,
        'transport': transport.id,
        'tls': useTls,
        if (fakeSni.trim().isNotEmpty) 'fakeSni': fakeSni.trim(),
      };

  static NodeConfig fromJson(Map<String, dynamic> json) {
    final rawHost = (json['host'] as String? ?? '').trim();
    final parsedHost = _splitHostPort(rawHost);
    return NodeConfig(
      id: json['id'] as String,
      accountId: (json['accountId'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Node',
      host: parsedHost.$1,
      discoveryPort: (json['discoveryPort'] as num?)?.toInt() ?? parsedHost.$2,
      chatPort: (json['chatPort'] as num?)?.toInt() ?? 443,
      voicePort: (json['voicePort'] as num?)?.toInt() ??
          ((json['chatPort'] as num?)?.toInt() ?? 443),
      transport: SgtpTransportFamilyCodec.fromId(json['transport'] as String?),
      useTls: (json['tls'] as bool?) ?? false,
      fakeSni: (json['fakeSni'] as String? ?? '').trim(),
      // 'usersPort' key is ignored for backward compatibility
    );
  }

  static (String, int?) _splitHostPort(String raw) {
    final value = raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    if (value.isEmpty) {
      return ('', null);
    }
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end <= 1) {
        return (value, null);
      }
      final host = value.substring(1, end).trim();
      final rest = value.substring(end + 1).trim();
      if (rest.startsWith(':')) {
        return (host, int.tryParse(rest.substring(1).trim()));
      }
      return (host, null);
    }
    final colon = value.lastIndexOf(':');
    if (colon <= 0 || colon == value.length - 1) {
      return (value, null);
    }
    final port = int.tryParse(value.substring(colon + 1).trim());
    if (port == null) {
      return (value, null);
    }
    return (value.substring(0, colon).trim(), port);
  }
}

class SavedChatRef {
  final String uuid; // 32-char hex
  final String? serverAddress; // host:port (chat)

  const SavedChatRef({required this.uuid, this.serverAddress});

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        if (serverAddress != null) 'server': serverAddress,
      };

  static SavedChatRef fromJson(Map<String, dynamic> json) {
    return SavedChatRef(
      uuid: (json['uuid'] as String).trim(),
      serverAddress: (json['server'] as String?)?.trim(),
    );
  }
}
