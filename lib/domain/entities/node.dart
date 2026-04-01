import '../../core/sgtp_transport.dart';

class NodeConfig {
  final String id;
  final String name;
  final String host; // domain or IP, without scheme
  final int chatPort;
  final int voicePort;
  final SgtpTransportFamily transport;
  final bool useTls;

  const NodeConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.chatPort,
    required this.voicePort,
    this.transport = SgtpTransportFamily.tcp,
    this.useTls = false,
  });

  String get chatAddress => '$host:$chatPort';

  NodeConfig copyWith({
    String? id,
    String? name,
    String? host,
    int? chatPort,
    int? voicePort,
    SgtpTransportFamily? transport,
    bool? useTls,
  }) {
    return NodeConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      chatPort: chatPort ?? this.chatPort,
      voicePort: voicePort ?? this.voicePort,
      transport: transport ?? this.transport,
      useTls: useTls ?? this.useTls,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'chatPort': chatPort,
        'voicePort': voicePort,
        'transport': transport.id,
        'tls': useTls,
      };

  static NodeConfig fromJson(Map<String, dynamic> json) {
    return NodeConfig(
      id: json['id'] as String,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Node',
      host: (json['host'] as String? ?? '').trim(),
      chatPort: (json['chatPort'] as num?)?.toInt() ?? 7777,
      voicePort: (json['voicePort'] as num?)?.toInt() ??
          ((json['chatPort'] as num?)?.toInt() ?? 7777),
      transport: SgtpTransportFamilyCodec.fromId(json['transport'] as String?),
      useTls: (json['tls'] as bool?) ?? false,
      // 'usersPort' key is ignored for backward compatibility
    );
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
