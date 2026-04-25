import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';

import 'package:sgtp_flutter/core/app/app_session_controller.dart';
import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/core/interaction_prefs.dart';
import 'package:sgtp_flutter/core/storage/local_encryption_service.dart';
import 'package:sgtp_flutter/core/network/rpc_models/overview_rpc_models.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/application/services/message_notification_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/settings/application/models/app_storage_models.dart';
import 'package:sgtp_flutter/features/settings/application/models/settings_models.dart';
import 'package:sgtp_flutter/features/settings/application/models/usage_stats_models.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/settings_view_state.dart';

final _log = AppLog('SettingsCubit');

class SettingsCubit extends Cubit<SettingsViewState> {
  SettingsCubit({
    required SettingsManagementService settings,
    required AppSessionController appSessionController,
    required SgtpConnectionService sgtpConnectionService,
    required MessageNotificationService messageNotificationService,
    required SgtpConfig? initialConfig,
    required Uint8List? currentUserAvatar,
    required void Function()? onAllDataDeleted,
  })  : _settings = settings,
        _appSessionController = appSessionController,
        _sgtpConnection = sgtpConnectionService,
        _messageNotifications = messageNotificationService,
        _onAllDataDeleted = onAllDataDeleted,
        super(const SettingsViewState()) {
    _userAvatar = currentUserAvatar;
    if (initialConfig != null) {
      _standaloneServerAddress = initialConfig.serverAddr.trim();
      _myPublicKey = initialConfig.myPublicKey;
    }
    unawaited(_loadFromDisk());
  }

  final SettingsManagementService _settings;
  final AppSessionController _appSessionController;
  final SgtpConnectionService _sgtpConnection;
  final MessageNotificationService _messageNotifications;
  final void Function()? _onAllDataDeleted;

  String? _privateKeyPath;
  Uint8List? _privateKeyBytes;
  Uint8List? _myPublicKey;
  String _deviceId = '';
  List<ContactEntry> _contactEntries = [];
  Uint8List? _userAvatar;
  String _nickname = '';
  String _username = '';
  final Map<String, Uint8List?> _avatarsByNodeId = {};
  final Map<String, String> _nicknamesByNodeId = {};

  bool _isLoading = false;
  bool _isGenerating = false;
  bool _isCreatingBackup = false;
  bool _isRestoringBackup = false;
  String? _usernameError;

  int _pingIntervalSeconds = 30;
  bool _compressFiles = false;
  bool _compressPhotos = false;
  bool _compressVideos = false;
  int _mediaChunkSizeBytes = SgtpConstants.defaultMediaChunkSize;

  String _doubleTapDesktop = 'react';
  bool _swipeToReply = true;
  bool _longPressMenu = true;

  List<NodeConfig> _nodes = const [];
  List<String> _accountIdsList = const [];
  bool _nodesLoading = true;
  String? _preferredNodeId;
  String? _preferredAccountId;
  String _standaloneServerAddress = '';
  LocalEncryptionState _localEncryptionState =
      const LocalEncryptionState.disabled();

  int _accountLoadSeq = 0;
  int _usernameSaveSeq = 0;

  // ── Public getters ──────────────────────────────────────────────────────
  SettingsManagementService get settings => _settings;

  Future<UsageStatsSummary> loadMyUsageStats() async {
    final rpc = await _sgtpConnection.ensureConnected();
    final raw = await rpc.callRpc(const GetMyUsageStatsRequest());
    final parsed = GetMyUsageStatsResponse.fromMap(raw);
    UsageStat toApp(UsageStatData s) =>
        UsageStat(requests: s.requests, bytesIn: s.bytesIn, bytesOut: s.bytesOut);
    return UsageStatsSummary(
      minute: toApp(parsed.minute),
      hour: toApp(parsed.hour),
      day: toApp(parsed.day),
      week: toApp(parsed.week),
      month: toApp(parsed.month),
      allTime: toApp(parsed.allTime),
    );
  }

  Future<AppStorageBreakdown> loadAppStorageBreakdown() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final tmp = await getTemporaryDirectory();

    Future<int> sumEntity(FileSystemEntity entity) async {
      try {
        if (entity is File) return await entity.length();
        return 0;
      } catch (_) {
        return 0;
      }
    }

    Future<int> sumDir(Directory dir) async {
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        total += await sumEntity(entity);
      }
      return total;
    }

    bool hasSegment(String path, String segment) {
      final normalized = path.replaceAll('\\', '/');
      return normalized.contains('/$segment/');
    }

    String extension(String path) {
      final normalized = path.replaceAll('\\', '/');
      final slash = normalized.lastIndexOf('/');
      final name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
      final dot = name.lastIndexOf('.');
      if (dot <= 0 || dot == name.length - 1) return '';
      return name.substring(dot + 1).toLowerCase();
    }

    const imageExt = <String>{
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'heic',
      'heif',
      'bmp',
      'tiff',
      'svg',
    };
    const videoExt = <String>{'mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v'};

    // ── Docs-root SGTP folders ───────────────────────────────────────────
    final mediaDir = Directory('${docs.path}/sgtp_media_cache');
    var mediaImages = 0;
    var mediaVideos = 0;
    var mediaOther = 0;
    if (await mediaDir.exists()) {
      await for (final entity
          in mediaDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final size = await sumEntity(entity);
        final ext = extension(entity.path);
        if (imageExt.contains(ext)) {
          mediaImages += size;
        } else if (videoExt.contains(ext)) {
          mediaVideos += size;
        } else {
          mediaOther += size;
        }
      }
    }

    // ── Per-account docs ────────────────────────────────────────────────
    final accountsDir = Directory('${docs.path}/sgtp_accounts');
    var chatHistory = 0;
    var chatMetadata = 0;
    var mlsState = 0;
    var accountsOther = 0;
    if (await accountsDir.exists()) {
      await for (final entity
          in accountsDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final size = await sumEntity(entity);
        final p = entity.path;
        if (hasSegment(p, 'sgtp_history')) {
          chatHistory += size;
          continue;
        }
        if (hasSegment(p, 'sgtp_chats')) {
          chatMetadata += size;
          continue;
        }
        if (hasSegment(p, 'sgtp_mls')) {
          mlsState += size;
          continue;
        }
        accountsOther += size;
      }
    }

    // Legacy chats root (rare on fresh installs).
    final legacyChatsDir = Directory('${docs.path}/sgtp_chats');
    chatMetadata += await sumDir(legacyChatsDir);

    final sharedSgtpDir = Directory('${docs.path}/sgtp');
    final sharedSgtpBytes = await sumDir(sharedSgtpDir);

    // Docs root miscellaneous (e.g. window state files).
    var docsOther = 0;
    await for (final entity in docs.list(recursive: false, followLinks: false)) {
      if (entity is Directory) {
        final name = entity.path.replaceAll('\\', '/').split('/').last;
        if (name == 'sgtp' ||
            name == 'sgtp_accounts' ||
            name == 'sgtp_chats' ||
            name == 'sgtp_media_cache') {
          continue;
        }
        docsOther += await sumDir(entity);
      } else {
        docsOther += await sumEntity(entity);
      }
    }

    // ── Application support (SharedPreferences, etc.) ────────────────────
    final appSupportBytes = await sumDir(support);

    // ── Temp artifacts (only known app patterns) ─────────────────────────
    const tempPrefixes = <String>[
      'sgtp_av_',
      'voice_play_',
      'voice_',
      'vnote_',
      'videonote_',
      'videonote_thumb_',
      'mic_loop_',
    ];
    Future<int> sumTempDir(Directory d) async {
      if (!await d.exists()) return 0;
      var total = 0;
      await for (final entity in d.list(recursive: false, followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.replaceAll('\\', '/').split('/').last;
        final lower = name.toLowerCase();
        if (!tempPrefixes.any((p) => lower.startsWith(p))) continue;
        total += await sumEntity(entity);
      }
      final cache = Directory('${d.path}/sgtp_media_cache');
      total += await sumDir(cache);
      return total;
    }

    final tempArtifacts =
        await sumTempDir(tmp) + await sumTempDir(Directory.systemTemp);

    final docsTotal = mediaImages +
        mediaVideos +
        mediaOther +
        chatHistory +
        chatMetadata +
        mlsState +
        accountsOther +
        sharedSgtpBytes +
        docsOther;

    final persistent = docsTotal + appSupportBytes;
    final total = persistent + tempArtifacts;

    return AppStorageBreakdown(
      totalBytes: total,
      persistentBytes: persistent,
      tempBytes: tempArtifacts,
      mediaImagesBytes: mediaImages,
      mediaVideosBytes: mediaVideos,
      mediaOtherBytes: mediaOther,
      chatHistoryBytes: chatHistory,
      chatMetadataBytes: chatMetadata,
      mlsStateBytes: mlsState,
      accountsOtherBytes: accountsOther,
      sharedSgtpBytes: sharedSgtpBytes,
      docsOtherBytes: docsOther,
      appSupportBytes: appSupportBytes,
      tempArtifactsBytes: tempArtifacts,
    );
  }

  // ── Intent: Load ────────────────────────────────────────────────────────

  Future<void> _loadFromDisk() async {
    _localEncryptionState = await _settings.loadLocalEncryptionState();
    final bootstrap = await _settings.loadBootstrapData();
    final nodes = bootstrap.nodes;
    final accountIds = bootstrap.accountIds;
    unawaited(_logCachedDiscovery(nodes));
    for (final node in nodes) {
      unawaited(_runDiscoveryForNode(node));
    }

    _nodes = nodes;
    _accountIdsList = accountIds;
    _nodesLoading = false;
    _preferredNodeId = bootstrap.preferredNodeId;
    _preferredAccountId = bootstrap.preferredAccountId;
    _buildState();

    if (bootstrap.preferredAccountId != null &&
        bootstrap.preferredAccountId!.trim().isNotEmpty) {
      final loadSeq = ++_accountLoadSeq;
      await _loadAccountData(
        bootstrap.preferredAccountId!,
        applyConfig: false,
        expectedLoadSeq: loadSeq,
      );
    } else {
      final lastAddr = bootstrap.lastAddress;
      if (lastAddr != null && _standaloneServerAddress.isEmpty) {
        _standaloneServerAddress = lastAddr.trim();
      }
    }

    final mediaSettings = bootstrap.mediaSettings;
    final uiSettings = bootstrap.uiSettings;
    _pingIntervalSeconds = uiSettings.pingIntervalSeconds;
    _compressFiles = mediaSettings.compressFiles;
    _compressPhotos = mediaSettings.compressPhotos;
    _compressVideos = mediaSettings.compressVideos;
    _mediaChunkSizeBytes = mediaSettings.mediaChunkSizeBytes;
    _doubleTapDesktop = uiSettings.doubleTapDesktop;
    _swipeToReply = uiSettings.swipeToReply;
    _longPressMenu = uiSettings.longPressMenu;
    InteractionPrefs.doubleTapDesktop = _doubleTapDesktop;
    InteractionPrefs.swipeToReply = _swipeToReply;
    InteractionPrefs.longPressShowsMenu = _longPressMenu;
    _buildState();

    unawaited(_refreshProfilesCache(accountIds));
  }

  Future<void> _loadAccountData(String accountId,
      {bool applyConfig = true, int? expectedLoadSeq}) async {
    bool isStale() =>
        expectedLoadSeq != null && expectedLoadSeq != _accountLoadSeq;
    final snapshot = await _settings.loadAccountSnapshot(accountId);
    if (isStale()) return;

    _nickname = snapshot.nickname;
    _username = snapshot.username;
    _usernameError = null;
    _userAvatar = snapshot.avatar;
    _deviceId = snapshot.deviceId;
    _avatarsByNodeId[accountId] = snapshot.avatar;
    _nicknamesByNodeId[accountId] = snapshot.nickname;
    _privateKeyBytes = snapshot.privateKeyBytes;
    _privateKeyPath = snapshot.privateKeyName;
    _myPublicKey = snapshot.publicKey;
    _contactEntries = snapshot.contactEntries;
    _buildState();

    if (applyConfig) tryApplyConfig();
  }

  Future<void> _refreshProfilesCache(List<String> accountIds) async {
    final cache = await _settings.loadProfilesCache(accountIds);
    _avatarsByNodeId
      ..clear()
      ..addAll(cache.avatarsByAccountId);
    _nicknamesByNodeId
      ..clear()
      ..addAll(cache.nicknamesByAccountId);
    _buildState();
  }

  Future<void> _logCachedDiscovery(List<NodeConfig> nodes) async {
    await _settings.logCachedDiscovery(nodes);
  }

  Future<void> _runDiscoveryForNode(NodeConfig node) async {
    try {
      await _settings.discoverNodeAndCache(node);
    } catch (e) {
      _log.warning('Discovery failed for {node}: {error}', parameters: {'node': node.name, 'error': e});
    }
  }

  // ── Intent: Apply config ────────────────────────────────────────────────

  void tryApplyConfig() {
    if (_privateKeyBytes == null || _myPublicKey == null) return;
    try {
      final accountId = _activeAccountId();
      if (accountId == null || accountId.trim().isEmpty) return;
      final applied = _settings.buildAppliedConfig(
        accountId: accountId,
        deviceId: _deviceId,
        privateKeyBytes: _privateKeyBytes!,
        username: _username,
        userAvatarBytes: _userAvatar,
        nodes: _nodes,
        preferredNodeId: _preferredNodeId,
        standaloneServerAddress: _standaloneServerAddress,
        contactEntries: _contactEntries,
        pingIntervalSeconds: _pingIntervalSeconds,
        mediaChunkSizeBytes: _mediaChunkSizeBytes,
      );
      _appSessionController.applyAccountConfig(
        accountId: applied.accountId,
        config: applied.config,
        nicknames: applied.nicknames,
        serverAddress: applied.serverAddress,
        contactEntries: applied.contactEntries,
      );
    } catch (_) {}
  }

  String? _activeAccountId() {
    final id = (_preferredAccountId ?? '').trim();
    return id.isEmpty ? null : id;
  }

  // ── Intent: Select server ───────────────────────────────────────────────

  Future<void> selectServer(String nodeId) async {
    _preferredNodeId = nodeId;
    await _settings.setLastNodeId(nodeId);
    _buildState();
    tryApplyConfig();
  }

  // ── Intent: Select account ──────────────────────────────────────────────

  Future<void> selectAccountId(
    String accountId, {
    bool forceReload = false,
  }) async {
    final normalized = accountId.trim();
    if (normalized.isEmpty) return;
    final sameAccount = _preferredAccountId == normalized;

    if (!sameAccount) {
      _preferredAccountId = normalized;
      await _settings.setLastAccountId(normalized);
      _buildState();
    } else if (!forceReload) {
      return;
    }

    final loadSeq = ++_accountLoadSeq;
    await _loadAccountData(normalized, expectedLoadSeq: loadSeq);
  }

  // ── Intent: Delete account ──────────────────────────────────────────────

  Future<void> deleteAccount(String accountId) async {
    await _settings.deleteAccount(accountId);
    await reloadNodes();
  }

  // ── Intent: Add server-only node ────────────────────────────────────────

  Future<void> addServerOnly(NodeConfig newNode) async {
    await _settings.saveDetachedNode(newNode);
    unawaited(_runDiscoveryForNode(newNode));
    await reloadNodes();
  }

  // ── Intent: Add empty account ───────────────────────────────────────────

  Future<void> addEmptyAccount(String accountId) async {
    await _settings.addEmptyAccount(accountId);
    await reloadNodes(applyConfig: false);
    await selectAccountId(accountId, forceReload: true);
  }

  // ── Intent: Edit node ───────────────────────────────────────────────────

  Future<void> editNode(NodeConfig updated) async {
    await _settings.saveDetachedNode(updated);
    unawaited(_runDiscoveryForNode(updated));
    await reloadNodes();
  }

  // ── Intent: Delete node ─────────────────────────────────────────────────

  Future<void> deleteNode(String nodeId) async {
    await _settings.deleteNode(nodeId);
    await reloadNodes();
  }

  // ── Intent: Reload nodes ────────────────────────────────────────────────

  Future<void> reloadNodes({bool applyConfig = true}) async {
    final reload = await _settings.reloadRegistryState();
    _nodes = reload.nodes;
    _accountIdsList = reload.accountIds;
    _preferredNodeId = reload.preferredNodeId;
    _preferredAccountId = reload.preferredAccountId;
    _buildState();
    unawaited(_refreshProfilesCache(_accountIdsList));

    final activeAccountId = _activeAccountId();
    if (activeAccountId != null && activeAccountId.trim().isNotEmpty) {
      final loadSeq = ++_accountLoadSeq;
      await _loadAccountData(
        activeAccountId,
        applyConfig: applyConfig,
        expectedLoadSeq: loadSeq,
      );
      return;
    }

    if (applyConfig) {
      tryApplyConfig();
    }
  }

  // ── Intent: Save nickname ───────────────────────────────────────────────

  Future<void> saveNickname(String next) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    _nickname = next;
    await _settings.saveUserNicknameForNode(accountId, next);
    _nicknamesByNodeId[accountId] = next;
    _buildState();
    _appSessionController.setCurrentNickname(next);
  }

  // ── Intent: Save username ───────────────────────────────────────────────

  Future<void> saveUsername(String sanitized) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    final saveSeq = ++_usernameSaveSeq;
    _username = sanitized;
    _usernameError = null;
    _buildState();
    try {
      await _settings.saveUserUsernameForNode(accountId, sanitized);
      final registrationError =
          await _appSessionController.setCurrentUsername(sanitized);
      if (saveSeq != _usernameSaveSeq) return;
      _usernameError = registrationError;
    } catch (e) {
      if (saveSeq != _usernameSaveSeq) return;
      _usernameError = 'Failed to update username';
      _log.warning('Failed to save username: {error}', parameters: {'error': e});
    }
    _buildState();
  }

  // ── Intent: Pick user avatar ────────────────────────────────────────────

  Future<void> setUserAvatar(Uint8List? bytes) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    if (bytes != null && bytes.isNotEmpty) {
      await _settings.saveUserAvatarForNode(accountId, bytes);
    } else {
      await _settings.clearUserAvatarForNode(accountId);
    }
    _userAvatar = bytes;
    _avatarsByNodeId[accountId] = bytes;
    _buildState();
    _appSessionController.setCurrentUserAvatar(bytes);
  }

  // ── Intent: Key management ──────────────────────────────────────────────

  Future<void> importPrivateKey(String accountId, Uint8List bytes,
      {String name = 'identity'}) async {
    _isLoading = true;
    _buildState();
    try {
      await _settings.importPrivateKey(
        accountId: accountId,
        bytes: bytes,
        name: name,
      );
      final loadSeq = ++_accountLoadSeq;
      await _loadAccountData(accountId, expectedLoadSeq: loadSeq);
    } finally {
      _isLoading = false;
      _buildState();
    }
  }

  Future<void> importPrivateKeyFromText(String accountId, String text,
      {String name = 'pasted_identity'}) async {
    _isLoading = true;
    _buildState();
    try {
      await _settings.importPrivateKeyFromText(
        accountId: accountId,
        text: text,
        name: name,
      );
      final loadSeq = ++_accountLoadSeq;
      await _loadAccountData(accountId, expectedLoadSeq: loadSeq);
    } finally {
      _isLoading = false;
      _buildState();
    }
  }

  Future<void> generatePrivateKey() async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    _isGenerating = true;
    _buildState();
    try {
      await _settings.generatePrivateKey(accountId: accountId);
      final loadSeq = ++_accountLoadSeq;
      await _loadAccountData(accountId, expectedLoadSeq: loadSeq);
    } finally {
      _isGenerating = false;
      _buildState();
    }
  }

  Future<bool> hasPrivateKey(String accountId) {
    return _settings.hasPrivateKey(accountId);
  }

  // ── Intent: Media settings ──────────────────────────────────────────────

  Future<void> saveMediaSettings({
    bool? compressFiles,
    bool? compressPhotos,
    bool? compressVideos,
    int? mediaChunkSizeBytes,
  }) async {
    if (compressFiles != null) _compressFiles = compressFiles;
    if (compressPhotos != null) _compressPhotos = compressPhotos;
    if (compressVideos != null) _compressVideos = compressVideos;
    if (mediaChunkSizeBytes != null) _mediaChunkSizeBytes = mediaChunkSizeBytes;
    _buildState();
    await _settings.saveMediaTransferSettings(MediaTransferSettings(
      compressFiles: _compressFiles,
      compressPhotos: _compressPhotos,
      compressVideos: _compressVideos,
      mediaChunkSizeBytes: _mediaChunkSizeBytes,
    ));
    tryApplyConfig();
  }

  // ── Intent: Interaction preferences ─────────────────────────────────────

  Future<void> savePingInterval(int seconds) async {
    _pingIntervalSeconds = seconds;
    _buildState();
    await _settings.savePingIntervalSeconds(seconds);
    tryApplyConfig();
  }

  void setDoubleTapDesktop(String value) {
    _doubleTapDesktop = value;
    InteractionPrefs.doubleTapDesktop = value;
    _buildState();
  }

  void setSwipeToReply(bool value) {
    _swipeToReply = value;
    InteractionPrefs.swipeToReply = value;
    _buildState();
  }

  void setLongPressMenu(bool value) {
    _longPressMenu = value;
    InteractionPrefs.longPressShowsMenu = value;
    _buildState();
  }

  // ── Intent: Backup/restore ──────────────────────────────────────────────

  Future<BackupExportData> createBackup() async {
    _isCreatingBackup = true;
    _buildState();
    try {
      return await _settings.createBackup();
    } finally {
      _isCreatingBackup = false;
      _buildState();
    }
  }

  Future<void> restoreFromBackup(Uint8List bytes) async {
    _isRestoringBackup = true;
    _buildState();
    try {
      await _settings.restoreFromBytes(bytes, merge: true);
      await reloadNodes();
    } finally {
      _isRestoringBackup = false;
      _buildState();
    }
  }

  // ── Intent: Delete all data ─────────────────────────────────────────────

  Future<void> deleteAllData() async {
    await _messageNotifications.cancelAll();
    await _settings.clearAllLocalData();
    _onAllDataDeleted?.call();
  }

  Future<void> enableLocalEncryption({
    required String rawSecret,
    required LocalEncryptionSecretMode mode,
  }) async {
    _isLoading = true;
    _buildState();
    try {
      await _settings.enableLocalEncryption(
        currentAccountId: _activeAccountId(),
        secret: rawSecret,
        mode: mode,
      );
      _localEncryptionState = await _settings.loadLocalEncryptionState();
    } finally {
      _isLoading = false;
      _buildState();
    }
  }

  Future<void> disableLocalEncryption() async {
    _isLoading = true;
    _buildState();
    try {
      await _settings.disableLocalEncryption();
      _localEncryptionState = await _settings.loadLocalEncryptionState();
    } finally {
      _isLoading = false;
      _buildState();
    }
  }

  // ── Intent: Capture device settings ─────────────────────────────────────

  Future<void> savePreferredMicrophone(String id) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.savePreferredMicrophoneForNode(accountId, id);
  }

  Future<void> savePreferredCamera(String name) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.savePreferredCameraForNode(accountId, name);
  }

  // ── Private ─────────────────────────────────────────────────────────────

  void _buildState() {
    if (isClosed) return;
    emit(SettingsViewState(
      privateKeyPath: _privateKeyPath,
      privateKeyBytes: _privateKeyBytes,
      myPublicKey: _myPublicKey,
      contactEntries: List.unmodifiable(_contactEntries),
      userAvatar: _userAvatar,
      nickname: _nickname,
      username: _username,
      avatarsByNodeId: Map.unmodifiable(_avatarsByNodeId),
      nicknamesByNodeId: Map.unmodifiable(_nicknamesByNodeId),
      isLoading: _isLoading,
      isGenerating: _isGenerating,
      isCreatingBackup: _isCreatingBackup,
      isRestoringBackup: _isRestoringBackup,
      usernameError: _usernameError,
      pingIntervalSeconds: _pingIntervalSeconds,
      compressFiles: _compressFiles,
      compressPhotos: _compressPhotos,
      compressVideos: _compressVideos,
      mediaChunkSizeBytes: _mediaChunkSizeBytes,
      doubleTapDesktop: _doubleTapDesktop,
      swipeToReply: _swipeToReply,
      longPressMenu: _longPressMenu,
      nodes: List.unmodifiable(_nodes),
      accountIdsList: List.unmodifiable(_accountIdsList),
      nodesLoading: _nodesLoading,
      preferredNodeId: _preferredNodeId,
      preferredAccountId: _preferredAccountId,
      standaloneServerAddress: _standaloneServerAddress,
      localEncryptionState: _localEncryptionState,
    ));
  }

  // ── Sync callbacks ──────────────────────────────────────────────────────
}
