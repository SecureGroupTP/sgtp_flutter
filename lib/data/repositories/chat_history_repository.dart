import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class PersistedHistoryRecord {
  final Uint8List senderUUID;
  final Uint8List messageUUID;
  final int timestamp;
  final int nonce;
  final Uint8List plaintext;

  const PersistedHistoryRecord({
    required this.senderUUID,
    required this.messageUUID,
    required this.timestamp,
    required this.nonce,
    required this.plaintext,
  });

  String get messageIdHex =>
      messageUUID.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Map<String, dynamic> toJson() => {
        'senderUUID': base64.encode(senderUUID),
        'messageUUID': base64.encode(messageUUID),
        'timestamp': timestamp,
        'nonce': nonce,
        'plaintext': base64.encode(plaintext),
      };

  static PersistedHistoryRecord fromJson(Map<String, dynamic> json) {
    return PersistedHistoryRecord(
      senderUUID: base64.decode(json['senderUUID'] as String? ?? ''),
      messageUUID: base64.decode(json['messageUUID'] as String? ?? ''),
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      nonce: (json['nonce'] as num?)?.toInt() ?? 0,
      plaintext: base64.decode(json['plaintext'] as String? ?? ''),
    );
  }
}

/// Persistent message history storage keyed by account + server + chat UUID.
///
/// Layout:
/// `<docs>/sgtp_accounts/<account>/sgtp_history/<server-key>/<chat-uuid>/`
///   - `order.ndjson`: append-only list of message IDs in chronological order.
///   - `count.txt`: integer number of records in order.ndjson.
///   - `records/<message-id>.json`: payload for each unique message.
class ChatHistoryRepository {
  static const String _accountsDir = 'sgtp_accounts';
  static const String _historyDir = 'sgtp_history';
  static const String _recordsDir = 'records';
  static const String _orderFileName = 'order.ndjson';
  static const String _countFileName = 'count.txt';

  final String accountId;
  final String serverAddress;
  final String chatUUID;

  const ChatHistoryRepository({
    required this.accountId,
    required this.serverAddress,
    required this.chatUUID,
  });

  Future<Directory> _chatDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final acc = accountId.trim().isEmpty ? 'default' : accountId.trim();
    final srvRaw = serverAddress.trim().toLowerCase();
    final srv = srvRaw.isEmpty
        ? 'default'
        : base64Url.encode(utf8.encode(srvRaw)).replaceAll('=', '');
    final dir = Directory(
      '${docs.path}/$_accountsDir/$acc/$_historyDir/$srv/$chatUUID',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _orderFile() async =>
      File('${(await _chatDir()).path}/$_orderFileName');
  Future<File> _countFile() async =>
      File('${(await _chatDir()).path}/$_countFileName');
  Future<Directory> _recordsDirectory() async {
    final dir = Directory('${(await _chatDir()).path}/$_recordsDir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _recordFile(String messageIdHex) async {
    return File('${(await _recordsDirectory()).path}/$messageIdHex.json');
  }

  Future<int> count() async {
    final countFile = await _countFile();
    if (await countFile.exists()) {
      final raw = await countFile.readAsString();
      final v = int.tryParse(raw.trim());
      if (v != null && v >= 0) return v;
    }
    final recalculated = await _recountFromOrder();
    await _writeCount(recalculated);
    return recalculated;
  }

  Future<int> appendIfAbsent(PersistedHistoryRecord record) async {
    final messageId = record.messageIdHex;
    if (messageId.isEmpty) return 0;

    final payloadFile = await _recordFile(messageId);
    if (await payloadFile.exists()) {
      return 0;
    }

    await payloadFile.writeAsString(
      json.encode(record.toJson()),
      flush: true,
    );

    final orderFile = await _orderFile();
    final sink = orderFile.openWrite(mode: FileMode.append);
    sink.writeln(messageId);
    await sink.flush();
    await sink.close();

    final next = (await count()) + 1;
    await _writeCount(next);
    return 1;
  }

  /// Read records from [offset] (0-based, oldest-first), at most [limit].
  Future<List<PersistedHistoryRecord>> readRange({
    required int offset,
    required int limit,
  }) async {
    if (limit <= 0 || offset < 0) return const [];
    final ids = await _readOrderIdsRange(offset: offset, limit: limit);
    final out = <PersistedHistoryRecord>[];
    for (final id in ids) {
      final file = await _recordFile(id);
      if (!await file.exists()) continue;
      try {
        final parsed =
            json.decode(await file.readAsString()) as Map<String, dynamic>;
        out.add(PersistedHistoryRecord.fromJson(parsed));
      } catch (_) {}
    }
    return out;
  }

  /// Read a page from the tail of history.
  ///
  /// `offsetFromEnd = 0` gives the latest batch, `100` gives the previous one.
  Future<List<PersistedHistoryRecord>> readBatchFromEnd({
    required int offsetFromEnd,
    int limit = 100,
  }) async {
    final total = await count();
    if (total <= 0 || limit <= 0 || offsetFromEnd < 0) return const [];

    final endExclusive = total - offsetFromEnd;
    if (endExclusive <= 0) return const [];

    final start = (endExclusive - limit).clamp(0, endExclusive);
    return readRange(offset: start, limit: endExclusive - start);
  }

  Future<void> clear() async {
    final dir = await _chatDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> _writeCount(int value) async {
    final file = await _countFile();
    await file.writeAsString('$value', flush: true);
  }

  Future<int> _recountFromOrder() async {
    final file = await _orderFile();
    if (!await file.exists()) return 0;
    var total = 0;
    final stream =
        file.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in stream) {
      if (line.trim().isNotEmpty) total++;
    }
    return total;
  }

  Future<List<String>> _readOrderIdsRange({
    required int offset,
    required int limit,
  }) async {
    final file = await _orderFile();
    if (!await file.exists()) return const [];

    final start = offset;
    final endExclusive = offset + limit;
    var index = 0;
    final out = <String>[];
    final stream =
        file.openRead().transform(utf8.decoder).transform(const LineSplitter());

    await for (final line in stream) {
      if (index >= endExclusive) break;
      if (index >= start) {
        final id = line.trim();
        if (id.isNotEmpty) out.add(id);
      }
      index++;
    }
    return out;
  }
}
