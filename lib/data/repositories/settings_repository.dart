import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Repository for persisting user settings between sessions.
class SettingsRepository {
  static const _savedAddressesKey = 'sgtp_saved_addresses';
  static const _lastAddressKey = 'sgtp_last_address';
  static const _privKeyB64Key = 'sgtp_private_key_b64';
  static const _privKeyNameKey = 'sgtp_private_key_name';
  static const _whitelistJsonKey = 'sgtp_whitelist_json'; // [{b64, name, nick}]
  static const _userAvatarB64Key = 'sgtp_user_avatar_b64';
  static const _compressFilesKey = 'sgtp_compress_files_enabled';
  static const _compressPhotosKey = 'sgtp_compress_photos_enabled';
  static const _compressVideosKey = 'sgtp_compress_videos_enabled';
  static const _mediaChunkSizeKey = 'sgtp_media_chunk_size_bytes';
  static const _qrPresetIndexKey = 'sgtp_qr_preset_index';
  static const _qrPrimaryColorKey = 'sgtp_qr_primary_color';
  static const _qrSecondaryColorKey = 'sgtp_qr_secondary_color';
  static const _qrShapeStyleKey = 'sgtp_qr_shape_style';
  static const _qrShowLogoKey = 'sgtp_qr_show_logo';
  static const int _maxSaved = 10;

  // ── Shared sgtp directory ──────────────────────────────────────────────────

  /// Returns (and creates if needed) the fixed SGTP data directory.
  /// On desktop: ~/Documents/sgtp
  /// On mobile:  app documents dir / sgtp
  Future<Directory> getSgtpDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/sgtp');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // ── Server addresses ──────────────────────────────────────────────────────

  Future<List<String>> getSavedAddresses() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_savedAddressesKey) ?? [];
  }

  Future<void> saveAddress(String address) async {
    final p = await SharedPreferences.getInstance();
    var list = p.getStringList(_savedAddressesKey) ?? [];
    list.removeWhere((a) => a.toLowerCase() == address.toLowerCase());
    list.insert(0, address);
    if (list.length > _maxSaved) list = list.sublist(0, _maxSaved);
    await p.setStringList(_savedAddressesKey, list);
    await p.setString(_lastAddressKey, address);
  }

  Future<String?> getLastAddress() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_lastAddressKey);
  }

  // ── Private key ───────────────────────────────────────────────────────────

  Future<void> savePrivateKey(Uint8List bytes, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_privKeyB64Key, base64.encode(bytes));
    await p.setString(_privKeyNameKey, name);
    // Also write to sgtp dir
    try {
      final dir = await getSgtpDirectory();
      final file = File('${dir.path}/identity');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  /// Returns null if no private key has been saved yet.
  Future<({Uint8List bytes, String name})?> loadPrivateKey() async {
    final p = await SharedPreferences.getInstance();
    final b64 = p.getString(_privKeyB64Key);
    final name = p.getString(_privKeyNameKey) ?? 'identity';
    if (b64 == null) return null;
    try {
      return (bytes: base64.decode(b64), name: name);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPrivateKey() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_privKeyB64Key);
    await p.remove(_privKeyNameKey);
  }

  // ── Whitelist ─────────────────────────────────────────────────────────────

  /// Whitelist entry: public key bytes + display name (editable)
  /// Stored as JSON list: [{b64, name}]
  Future<void> saveWhitelistEntries(List<WhitelistEntry> entries) async {
    final p = await SharedPreferences.getInstance();
    final jsonList = entries
        .map(
            (e) => json.encode({'b64': base64.encode(e.bytes), 'name': e.name}))
        .toList();
    await p.setStringList(_whitelistJsonKey, jsonList);
  }

  Future<List<WhitelistEntry>> loadWhitelistEntries() async {
    final p = await SharedPreferences.getInstance();
    final jsonList = p.getStringList(_whitelistJsonKey);
    if (jsonList == null) return [];
    final result = <WhitelistEntry>[];
    for (final s in jsonList) {
      try {
        final m = json.decode(s) as Map<String, dynamic>;
        result.add(WhitelistEntry(
          bytes: base64.decode(m['b64'] as String),
          name: m['name'] as String? ?? 'unknown',
        ));
      } catch (_) {}
    }
    return result;
  }

  /// Backwards-compat helpers using old schema
  Future<void> saveWhitelist(
      List<Uint8List> bytesList, List<String> paths) async {
    final entries = List.generate(bytesList.length,
        (i) => WhitelistEntry(bytes: bytesList[i], name: paths[i]));
    await saveWhitelistEntries(entries);
  }

  Future<({List<Uint8List> bytesList, List<String> paths})?>
      loadWhitelist() async {
    final entries = await loadWhitelistEntries();
    if (entries.isEmpty) return null;
    return (
      bytesList: entries.map((e) => e.bytes).toList(),
      paths: entries.map((e) => e.name).toList(),
    );
  }

  Future<void> clearWhitelist() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_whitelistJsonKey);
  }

  // ── User avatar ───────────────────────────────────────────────────────────

  Future<void> saveUserAvatar(Uint8List bytes) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_userAvatarB64Key, base64.encode(bytes));
  }

  Future<Uint8List?> loadUserAvatar() async {
    final p = await SharedPreferences.getInstance();
    final b64 = p.getString(_userAvatarB64Key);
    if (b64 == null) return null;
    try {
      return base64.decode(b64);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearUserAvatar() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_userAvatarB64Key);
  }

  // ── Saved chats (UUIDs) ───────────────────────────────────────────────────

  static const _savedChatsKey = 'sgtp_saved_chat_uuids';

  Future<List<String>> loadSavedChatUUIDs() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_savedChatsKey) ?? [];
  }

  Future<void> addSavedChat(String uuid) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_savedChatsKey) ?? [];
    if (!list.contains(uuid)) {
      list.add(uuid);
      await p.setStringList(_savedChatsKey, list);
    }
  }

  Future<void> removeSavedChat(String uuid) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_savedChatsKey) ?? [];
    list.remove(uuid);
    await p.setStringList(_savedChatsKey, list);
  }

  // ── Media transfer ───────────────────────────────────────────────────────

  Future<MediaTransferSettings> loadMediaTransferSettings() async {
    final p = await SharedPreferences.getInstance();
    return MediaTransferSettings(
      compressFiles: p.getBool(_compressFilesKey) ?? false,
      compressPhotos: p.getBool(_compressPhotosKey) ?? false,
      compressVideos: p.getBool(_compressVideosKey) ?? false,
      mediaChunkSizeBytes: p.getInt(_mediaChunkSizeKey) ?? (100 * 1024),
    );
  }

  Future<void> saveMediaTransferSettings(MediaTransferSettings settings) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_compressFilesKey, settings.compressFiles);
    await p.setBool(_compressPhotosKey, settings.compressPhotos);
    await p.setBool(_compressVideosKey, settings.compressVideos);
    await p.setInt(_mediaChunkSizeKey, settings.mediaChunkSizeBytes);
  }

  // ── QR style ─────────────────────────────────────────────────────────────

  Future<QrStyleSettings> loadQrStyleSettings() async {
    final p = await SharedPreferences.getInstance();
    return QrStyleSettings(
      presetIndex: p.getInt(_qrPresetIndexKey) ?? 0,
      primaryColorValue: p.getInt(_qrPrimaryColorKey),
      secondaryColorValue: p.getInt(_qrSecondaryColorKey),
      shapeStyle: p.getString(_qrShapeStyleKey) ?? 'smooth',
      showLogo: p.getBool(_qrShowLogoKey) ?? true,
    );
  }

  Future<void> saveQrStyleSettings(QrStyleSettings settings) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_qrPresetIndexKey, settings.presetIndex);
    if (settings.primaryColorValue != null) {
      await p.setInt(_qrPrimaryColorKey, settings.primaryColorValue!);
    } else {
      await p.remove(_qrPrimaryColorKey);
    }
    if (settings.secondaryColorValue != null) {
      await p.setInt(_qrSecondaryColorKey, settings.secondaryColorValue!);
    } else {
      await p.remove(_qrSecondaryColorKey);
    }
    await p.setString(_qrShapeStyleKey, settings.shapeStyle);
    await p.setBool(_qrShowLogoKey, settings.showLogo);
  }
}

class MediaTransferSettings {
  final bool compressFiles;
  final bool compressPhotos;
  final bool compressVideos;
  final int mediaChunkSizeBytes;

  const MediaTransferSettings({
    required this.compressFiles,
    required this.compressPhotos,
    required this.compressVideos,
    required this.mediaChunkSizeBytes,
  });

  bool get shouldCompressPhotos => compressFiles && compressPhotos;
  bool get shouldCompressVideos => compressFiles && compressVideos;

  MediaTransferSettings copyWith({
    bool? compressFiles,
    bool? compressPhotos,
    bool? compressVideos,
    int? mediaChunkSizeBytes,
  }) {
    return MediaTransferSettings(
      compressFiles: compressFiles ?? this.compressFiles,
      compressPhotos: compressPhotos ?? this.compressPhotos,
      compressVideos: compressVideos ?? this.compressVideos,
      mediaChunkSizeBytes: mediaChunkSizeBytes ?? this.mediaChunkSizeBytes,
    );
  }
}

class QrStyleSettings {
  final int presetIndex;
  final int? primaryColorValue;
  final int? secondaryColorValue;
  final String shapeStyle;
  final bool showLogo;

  const QrStyleSettings({
    required this.presetIndex,
    required this.primaryColorValue,
    required this.secondaryColorValue,
    required this.shapeStyle,
    required this.showLogo,
  });

  static const _keepInt = Object();

  QrStyleSettings copyWith({
    int? presetIndex,
    Object? primaryColorValue = _keepInt,
    Object? secondaryColorValue = _keepInt,
    String? shapeStyle,
    bool? showLogo,
  }) {
    return QrStyleSettings(
      presetIndex: presetIndex ?? this.presetIndex,
      primaryColorValue: identical(primaryColorValue, _keepInt)
          ? this.primaryColorValue
          : primaryColorValue as int?,
      secondaryColorValue: identical(secondaryColorValue, _keepInt)
          ? this.secondaryColorValue
          : secondaryColorValue as int?,
      shapeStyle: shapeStyle ?? this.shapeStyle,
      showLogo: showLogo ?? this.showLogo,
    );
  }
}

/// A whitelist entry: a trusted peer's public key + editable display name.
class WhitelistEntry {
  final Uint8List bytes;
  final String name;

  WhitelistEntry({required this.bytes, required this.name});

  String get hexKey =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  WhitelistEntry copyWithName(String newName) =>
      WhitelistEntry(bytes: bytes, name: newName);
}
