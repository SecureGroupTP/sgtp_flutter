import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/core/interaction_prefs.dart';
import 'package:sgtp_flutter/core/notification_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/settings/application/models/settings_models.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/settings_view_state.dart';

typedef ConfigChangedCallback = void Function(
    String accountId,
    SgtpConfig config,
    Map<String, String> nicknames,
    String serverAddress,
    List<WhitelistEntry> whitelistEntries);
typedef UserAvatarChangedCallback = void Function(Uint8List? avatar);

class SettingsCubit extends Cubit<SettingsViewState> {
  SettingsCubit({
    required SettingsManagementService settings,
    required SgtpConfig? initialConfig,
    required Map<String, String>? initialNicknames,
    required Uint8List? currentUserAvatar,
    required ConfigChangedCallback? onConfigChanged,
    required UserAvatarChangedCallback? onUserAvatarChanged,
    required void Function(String nickname)? onNicknameChanged,
    required Future<String?> Function(String username)? onUsernameChanged,
    required void Function()? onAllDataDeleted,
  })  : _settings = settings,
        _onConfigChanged = onConfigChanged,
        _onUserAvatarChanged = onUserAvatarChanged,
        _onNicknameChanged = onNicknameChanged,
        _onUsernameChanged = onUsernameChanged,
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
  final ConfigChangedCallback? _onConfigChanged;
  final UserAvatarChangedCallback? _onUserAvatarChanged;
  final void Function(String nickname)? _onNicknameChanged;
  final Future<String?> Function(String username)? _onUsernameChanged;
  final void Function()? _onAllDataDeleted;

  String? _privateKeyPath;
  Uint8List? _privateKeyBytes;
  Uint8List? _myPublicKey;
  List<WhitelistEntry> _wlEntries = [];
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

  int _accountLoadSeq = 0;
  int _usernameSaveSeq = 0;

  // ── Public getters ──────────────────────────────────────────────────────
  SettingsManagementService get settings => _settings;

  // ── Intent: Load ────────────────────────────────────────────────────────

  Future<void> _loadFromDisk() async {
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
    _avatarsByNodeId[accountId] = snapshot.avatar;
    _nicknamesByNodeId[accountId] = snapshot.nickname;
    _privateKeyBytes = snapshot.privateKeyBytes;
    _privateKeyPath = snapshot.privateKeyName;
    _myPublicKey = snapshot.publicKey;
    _wlEntries = snapshot.whitelistEntries;
    _buildState();

    _onUserAvatarChanged?.call(snapshot.avatar);
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
      AppLogger.w('Discovery failed for ${node.name}: $e', tag: 'DISC');
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
        privateKeyBytes: _privateKeyBytes!,
        nodes: _nodes,
        preferredNodeId: _preferredNodeId,
        standaloneServerAddress: _standaloneServerAddress,
        whitelistEntries: _wlEntries,
        pingIntervalSeconds: _pingIntervalSeconds,
        mediaChunkSizeBytes: _mediaChunkSizeBytes,
      );
      _onConfigChanged?.call(
        applied.accountId,
        applied.config,
        applied.nicknames,
        applied.serverAddress,
        applied.whitelistEntries,
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

  Future<void> selectAccountId(String accountId) async {
    if (_preferredAccountId == accountId) return;
    _preferredAccountId = accountId;
    await _settings.setLastAccountId(accountId);
    final loadSeq = ++_accountLoadSeq;
    _buildState();
    await _loadAccountData(accountId, expectedLoadSeq: loadSeq);
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
    await reloadNodes();
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

  Future<void> reloadNodes() async {
    final reload = await _settings.reloadRegistryState();
    _nodes = reload.nodes;
    _accountIdsList = reload.accountIds;
    _preferredNodeId = reload.preferredNodeId;
    _preferredAccountId = reload.preferredAccountId;
    _buildState();
    unawaited(_refreshProfilesCache(_accountIdsList));
    tryApplyConfig();
  }

  // ── Intent: Save nickname ───────────────────────────────────────────────

  Future<void> saveNickname(String next) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    _nickname = next;
    await _settings.saveUserNicknameForNode(accountId, next);
    _nicknamesByNodeId[accountId] = next;
    _buildState();
    _onNicknameChanged?.call(next);
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
      final registrationError = await _onUsernameChanged?.call(sanitized);
      if (saveSeq != _usernameSaveSeq) return;
      _usernameError = registrationError;
    } catch (e) {
      if (saveSeq != _usernameSaveSeq) return;
      _usernameError = 'Failed to update username';
      AppLogger.w('Failed to save username: $e', tag: 'SETTINGS');
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
    _onUserAvatarChanged?.call(bytes);
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
    await NotificationService.cancelAll();
    await _settings.clearAllLocalData();
    _onAllDataDeleted?.call();
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
      wlEntries: List.unmodifiable(_wlEntries),
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
    ));
  }

  // ── Sync callbacks ──────────────────────────────────────────────────────

  void syncCallbacks({
    ConfigChangedCallback? onConfigChanged,
    UserAvatarChangedCallback? onUserAvatarChanged,
    void Function(String nickname)? onNicknameChanged,
    Future<String?> Function(String username)? onUsernameChanged,
    void Function()? onAllDataDeleted,
  }) {
    // Callbacks are set once via constructor; this method is for future use
    // if we need to update them from didUpdateWidget.
  }
}
