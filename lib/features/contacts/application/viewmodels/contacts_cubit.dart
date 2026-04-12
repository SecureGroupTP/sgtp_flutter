import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app/app_session_controller.dart';
import 'package:sgtp_flutter/core/qr_data.dart';
import 'package:sgtp_flutter/features/contacts/application/models/contacts_models.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/contacts/application/viewmodels/contacts_view_state.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class ContactsCubit extends Cubit<ContactsViewState> {
  ContactsCubit({
    required ContactsDirectoryService directoryService,
    required IUserDirClient? Function() activeClientProvider,
    required AppSessionController appSessionController,
    required String accountId,
    required String? serverNodeId,
    required String? myPubkeyHex,
    required List<WhitelistEntry> initialEntries,
    required Map<String, ContactProfile> contactProfiles,
    required Map<String, FriendStateRecord> friendStates,
  })  : _directoryService = directoryService,
        _activeClientProvider = activeClientProvider,
        _appSessionController = appSessionController,
        _accountId = accountId,
        _serverNodeId = serverNodeId,
        _myPubkeyHex = myPubkeyHex,
        _entries = const <WhitelistEntry>[],
        _contactProfiles = const <String, ContactProfile>{},
        _friendStates = const <String, FriendStateRecord>{},
        super(const ContactsViewState()) {
    syncExternalData(
      accountId: accountId,
      serverNodeId: serverNodeId,
      myPubkeyHex: myPubkeyHex,
      initialEntries: initialEntries,
      contactProfiles: contactProfiles,
      friendStates: friendStates,
    );
  }

  final ContactsDirectoryService _directoryService;
  final IUserDirClient? Function() _activeClientProvider;
  final AppSessionController _appSessionController;

  String _accountId;
  String? _serverNodeId;
  String? _myPubkeyHex;
  List<WhitelistEntry> _entries;
  Map<String, ContactProfile> _contactProfiles;
  Map<String, FriendStateRecord> _friendStates;
  String _searchQuery = '';
  bool _isSearchingServer = false;
  ContactsServerSearchHit? _serverSearchHit;
  String? _recentlyAddedUsername;
  Timer? _searchDebounce;
  int _searchRequestId = 0;

  void syncExternalData({
    required String accountId,
    required String? serverNodeId,
    required String? myPubkeyHex,
    required List<WhitelistEntry> initialEntries,
    required Map<String, ContactProfile> contactProfiles,
    required Map<String, FriendStateRecord> friendStates,
  }) {
    final accountChanged = _accountId != accountId;
    final serverChanged = _serverNodeId != serverNodeId;

    _accountId = accountId;
    _serverNodeId = serverNodeId;
    _myPubkeyHex = myPubkeyHex;
    _entries = _sanitizeEntries(initialEntries);
    _contactProfiles = _normalizeProfileKeys(contactProfiles);
    _friendStates = _normalizeFriendStateKeys(friendStates);

    if (accountChanged || serverChanged) {
      _resetSearch(clearBanner: true);
    } else if (_serverSearchHit != null &&
        _containsEntryWithHex(_serverSearchHit!.pubkeyHex)) {
      _serverSearchHit = null;
    }

    emit(_buildState());
  }

  void onSearchChanged(String value) {
    _searchQuery = value;
    _searchDebounce?.cancel();
    final requestId = ++_searchRequestId;

    final normalized = _normalizeSearchUsername(value);
    if (normalized == null) {
      _isSearchingServer = false;
      _serverSearchHit = null;
      emit(_buildState());
      return;
    }

    _isSearchingServer = false;
    _serverSearchHit = null;
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_searchOnServer(normalized, requestId));
    });
    emit(_buildState());
  }

  void clearSearch() {
    _resetSearch(clearBanner: false);
    emit(_buildState());
  }

  void dismissRecentlyAddedUsername() {
    if (_recentlyAddedUsername == null) return;
    _recentlyAddedUsername = null;
    emit(_buildState());
  }

  String? validateImportedQrData(QrShareData data) {
    final publicKeyHex = data.publicKeyHex;
    if (publicKeyHex == null) {
      return 'QR code has no public key';
    }
    return validateNewContactHex(publicKeyHex);
  }

  String? validateNewContactHex(
    String rawHex, {
    String? excludeHex,
  }) {
    final hex = _normalizeHex(rawHex);
    if (hex.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(hex)) {
      return 'Must be exactly 64 hex characters';
    }
    if (_isSelfHex(hex)) {
      return excludeHex == null
          ? 'You cannot add your own key'
          : 'You cannot use your own key';
    }

    final lowerExclude = excludeHex == null ? null : _normalizeHex(excludeHex);
    final duplicate = _entries.any((entry) {
      final existingHex = entry.hexKey.toLowerCase();
      if (lowerExclude != null && existingHex == lowerExclude) {
        return false;
      }
      return existingHex == hex;
    });
    if (!duplicate) return null;

    return excludeHex == null
        ? 'Key already in contacts'
        : 'This key already exists in contacts';
  }

  Future<String?> addContact({
    required String name,
    required String rawHex,
    String? recentlyAddedUsername,
  }) async {
    final hex = _normalizeHex(rawHex);
    final error = validateNewContactHex(hex);
    if (error != null) return error;

    final nextEntries = List<WhitelistEntry>.from(_entries)
      ..add(
        WhitelistEntry(
          bytes: _bytesFromHex(hex),
          name:
              name.trim().isEmpty ? 'peer_${_entries.length + 1}' : name.trim(),
        ),
      );

    return _persistEntries(
      nextEntries,
      recentlyAddedUsername: recentlyAddedUsername,
      clearSearchOnSuccess: recentlyAddedUsername != null,
    );
  }

  Future<String?> editContact({
    required String originalHex,
    required String name,
    required String rawHex,
  }) async {
    final nextHex = _normalizeHex(rawHex);
    final error = validateNewContactHex(nextHex, excludeHex: originalHex);
    if (error != null) return error;

    final index = _entries.indexWhere(
      (entry) => entry.hexKey.toLowerCase() == originalHex.toLowerCase(),
    );
    if (index == -1) return 'Contact not found';

    final currentEntry = _entries[index];
    final finalName = name.trim().isEmpty ? currentEntry.name : name.trim();
    final nextEntries = List<WhitelistEntry>.from(_entries);

    if (currentEntry.hexKey.toLowerCase() == nextHex) {
      nextEntries[index] = currentEntry.copyWithName(finalName);
    } else {
      nextEntries[index] = WhitelistEntry(
        bytes: _bytesFromHex(nextHex),
        name: finalName,
      );
    }

    return _persistEntries(nextEntries);
  }

  Future<String?> deleteContact(String hexKey) async {
    final nextEntries = _entries
        .where((entry) => entry.hexKey.toLowerCase() != hexKey.toLowerCase())
        .toList(growable: false);
    return _persistEntries(nextEntries);
  }

  Future<bool> respondToFriend(String peerPubkeyHex, bool accept) {
    return _appSessionController.respondToFriend(peerPubkeyHex, accept);
  }

  void openDirectMessage(String roomUUIDHex) {
    _appSessionController.openDirectMessage(roomUUIDHex);
  }

  @override
  Future<void> close() {
    _searchDebounce?.cancel();
    return super.close();
  }

  ContactsViewState _buildState() {
    final visibleContacts = _buildVisibleContacts();
    final incomingRequests = _buildIncomingRequests();
    final trustedSet =
        _entries.map((entry) => entry.hexKey.toLowerCase()).toSet();

    final serverSearchHit = _serverSearchHit == null ||
            trustedSet.contains(_serverSearchHit!.pubkeyHex.toLowerCase())
        ? null
        : ContactsServerSearchHitUiModel(
            username: _serverSearchHit!.username,
            pubkeyHex: _serverSearchHit!.pubkeyHex,
            fullname: _serverSearchHit!.fullname,
            suggestedName: _serverSearchHit!.fullname.trim().isNotEmpty
                ? _serverSearchHit!.fullname.trim()
                : _serverSearchHit!.username.replaceFirst('@', ''),
          );

    return ContactsViewState(
      searchQuery: _searchQuery,
      isSearchingServer: _isSearchingServer,
      serverSearchHit: serverSearchHit,
      recentlyAddedUsername: _recentlyAddedUsername,
      contacts: visibleContacts,
      incomingRequests: incomingRequests,
      totalContacts: _entries.length,
    );
  }

  List<ContactsContactUiModel> _buildVisibleContacts() {
    final filteredEntries = _filterEntries(_entries, _searchQuery);
    return filteredEntries.map((entry) {
      final lowerHex = entry.hexKey.toLowerCase();
      final profile = _contactProfiles[lowerHex];
      final friendState = _friendStates[lowerHex];
      final username = profile?.username?.trim();
      final resolvedName = _resolveContactDisplayName(entry.name, profile);
      return ContactsContactUiModel(
        hexKey: entry.hexKey,
        shortKey: _shortKey(entry.hexKey),
        displayName: resolvedName,
        username: username?.isEmpty ?? true ? null : username,
        avatarBytes: profile?.avatarBytes,
        friendStatus: _mapFriendStatus(
          friendState?.statusEnum ?? FriendStatus.none,
        ),
        roomUUIDHex: friendState?.roomUUIDHex,
      );
    }).toList(growable: false);
  }

  List<ContactsIncomingRequestUiModel> _buildIncomingRequests() {
    final existing =
        _entries.map((entry) => entry.hexKey.toLowerCase()).toSet();
    final selfHex = (_myPubkeyHex ?? '').trim().toLowerCase();
    final requests = <ContactsIncomingRequestUiModel>[];

    for (final record in _friendStates.values) {
      if (record.statusEnum != FriendStatus.pendingIncoming) continue;
      final peerHex = record.peerPubkeyHex.toLowerCase();
      if (selfHex.isNotEmpty && peerHex == selfHex) continue;
      if (existing.contains(peerHex)) continue;

      final profile = _contactProfiles[peerHex];
      final username = profile?.username?.trim();
      final fullname = profile?.fullname?.trim();
      final displayUsername = username?.replaceFirst(RegExp(r'^@+'), '');
      requests.add(
        ContactsIncomingRequestUiModel(
          peerHex: peerHex,
          shortKey: _shortKey(peerHex),
          displayName: fullname?.isNotEmpty == true
              ? fullname!
              : displayUsername?.isNotEmpty == true
                  ? displayUsername!
                  : 'Unknown sender',
          username: username?.isEmpty ?? true ? null : username,
          avatarBytes: profile?.avatarBytes,
        ),
      );
    }

    requests.sort((a, b) {
      final left = _friendStates[a.peerHex]?.updatedAt ?? 0;
      final right = _friendStates[b.peerHex]?.updatedAt ?? 0;
      return right.compareTo(left);
    });
    return requests;
  }

  List<WhitelistEntry> _filterEntries(
      List<WhitelistEntry> entries, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return List<WhitelistEntry>.from(entries);

    final scored = <({WhitelistEntry entry, int score})>[];
    for (final entry in entries) {
      final name = entry.name.toLowerCase();
      final key = entry.hexKey.toLowerCase();
      var score = -1;

      if (name.startsWith(normalizedQuery) || key.startsWith(normalizedQuery)) {
        score = 0;
      } else if (name.contains(normalizedQuery) ||
          key.contains(normalizedQuery)) {
        score = 1;
      }

      if (score >= 0) {
        scored.add((entry: entry, score: score));
      }
    }

    scored.sort((a, b) => a.score.compareTo(b.score));
    return scored.map((item) => item.entry).toList(growable: false);
  }

  Future<void> _searchOnServer(String normalizedUsername, int requestId) async {
    _isSearchingServer = true;
    _serverSearchHit = null;
    emit(_buildState());

    try {
      final hit = await _directoryService.searchExactUser(
        client: _activeClientProvider(),
        normalizedUsername: normalizedUsername,
        existingEntries: _entries,
      );
      if (isClosed || requestId != _searchRequestId) return;
      _serverSearchHit = hit;
    } catch (_) {
      if (isClosed || requestId != _searchRequestId) return;
      _serverSearchHit = null;
    }

    if (isClosed || requestId != _searchRequestId) return;
    _isSearchingServer = false;
    emit(_buildState());
  }

  ContactsFriendStatus _mapFriendStatus(FriendStatus status) {
    return switch (status) {
      FriendStatus.pendingOutgoing => ContactsFriendStatus.pendingOutgoing,
      FriendStatus.pendingIncoming => ContactsFriendStatus.pendingIncoming,
      FriendStatus.friend => ContactsFriendStatus.friend,
      FriendStatus.rejected => ContactsFriendStatus.rejected,
      FriendStatus.none => ContactsFriendStatus.none,
    };
  }

  Future<String?> _persistEntries(
    List<WhitelistEntry> nextEntries, {
    String? recentlyAddedUsername,
    bool clearSearchOnSuccess = false,
  }) async {
    final sanitized = _sanitizeEntries(nextEntries);
    try {
      await _directoryService.saveWhitelistEntries(
        accountId: _accountId,
        entries: sanitized,
      );
      _entries = sanitized;
      if (clearSearchOnSuccess) {
        _resetSearch(clearBanner: false);
      }
      _recentlyAddedUsername = recentlyAddedUsername;
      _appSessionController.setWhitelistEntries(
        List<WhitelistEntry>.from(sanitized),
      );
      emit(_buildState());
      return null;
    } catch (_) {
      return 'Failed to save contacts';
    }
  }

  List<WhitelistEntry> _sanitizeEntries(List<WhitelistEntry> entries) {
    final selfHex = (_myPubkeyHex ?? '').trim().toLowerCase();
    final seen = <String>{};
    final sanitized = <WhitelistEntry>[];

    for (final entry in entries) {
      final hex = entry.hexKey.toLowerCase();
      if (selfHex.isNotEmpty && hex == selfHex) continue;
      if (!seen.add(hex)) continue;
      sanitized.add(entry);
    }

    return sanitized;
  }

  Map<String, ContactProfile> _normalizeProfileKeys(
    Map<String, ContactProfile> profiles,
  ) {
    return {
      for (final entry in profiles.entries)
        entry.key.toLowerCase(): entry.value,
    };
  }

  Map<String, FriendStateRecord> _normalizeFriendStateKeys(
    Map<String, FriendStateRecord> friendStates,
  ) {
    return {
      for (final entry in friendStates.entries)
        entry.key.toLowerCase(): entry.value,
    };
  }

  bool _containsEntryWithHex(String hex) {
    final normalized = hex.toLowerCase();
    return _entries.any((entry) => entry.hexKey.toLowerCase() == normalized);
  }

  bool _isSelfHex(String hex) {
    final selfHex = (_myPubkeyHex ?? '').trim().toLowerCase();
    if (selfHex.isEmpty) return false;
    return _normalizeHex(hex) == selfHex;
  }

  String _normalizeHex(String hex) {
    return hex.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase();
  }

  Uint8List _bytesFromHex(String hex) {
    final normalized = _normalizeHex(hex);
    return Uint8List.fromList(List<int>.generate(
      32,
      (index) => int.parse(
        normalized.substring(index * 2, index * 2 + 2),
        radix: 16,
      ),
    ));
  }

  String _shortKey(String hex) {
    return '${hex.substring(0, 8)}…${hex.substring(hex.length - 8)}';
  }

  String _resolveContactDisplayName(
      String storedName, ContactProfile? profile) {
    final name = storedName.trim();
    if (profile == null) return name;

    final full = (profile.fullname ?? '').trim();
    final user =
        (profile.username ?? '').trim().replaceFirst(RegExp(r'^@+'), '');

    final hasBetterProfileName =
        full.isNotEmpty && full.toLowerCase() != 'account';
    final hasUsername = user.isNotEmpty;
    final isGenericStored = name.isEmpty ||
        name.toLowerCase() == 'account' ||
        name.toLowerCase() == 'friend' ||
        name.startsWith('peer_');

    if (isGenericStored) {
      if (hasBetterProfileName) return full;
      if (hasUsername) return user;
    }
    return name;
  }

  String? _normalizeSearchUsername(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final base = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
    if (!RegExp(r'^[A-Za-z0-9_]{1,32}$').hasMatch(base)) return null;
    return '@$base';
  }

  void _resetSearch({required bool clearBanner}) {
    _searchDebounce?.cancel();
    _searchRequestId++;
    _searchQuery = '';
    _isSearchingServer = false;
    _serverSearchHit = null;
    if (clearBanner) {
      _recentlyAddedUsername = null;
    }
  }
}
