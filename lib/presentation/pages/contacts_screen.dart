import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../core/qr_data.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/userdir_client.dart';
import '../widgets/pretty_qr_share_panel.dart';
import '../widgets/qr_scanner_dialog.dart';
import '../widgets/user_avatar.dart';

/// Contacts screen — shows the trusted-peer whitelist.
/// Users can add peers by public key hex/share-hex, rename them, delete them.
class ContactsScreen extends StatefulWidget {
  final String accountId;
  final String? serverNodeId;
  final List<WhitelistEntry> initialEntries;
  final Map<String, ContactProfile> contactProfiles;

  /// Called whenever the whitelist changes so HomeScreen can propagate
  /// updated nicknames to RoomsBloc.
  final void Function(List<WhitelistEntry> entries) onEntriesChanged;

  const ContactsScreen({
    super.key,
    required this.accountId,
    this.serverNodeId,
    required this.initialEntries,
    required this.onEntriesChanged,
    this.contactProfiles = const {},
  });

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _repo = SettingsRepository();
  late List<WhitelistEntry> _entries;
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  String _search = '';
  _ServerSearchHit? _serverSearchHit;
  String? _recentlyAddedUsername;
  Timer? _recentlyAddedTimer;
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();
    _entries = List.from(widget.initialEntries);
  }

  @override
  void didUpdateWidget(covariant ContactsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId ||
        oldWidget.serverNodeId != widget.serverNodeId) {
      _searchDebounce?.cancel();
      _searchRequestId++;
      setState(() {
        _entries = List.from(widget.initialEntries);
        _search = '';
        _searchCtrl.clear();
        _serverSearchHit = null;
        _recentlyAddedUsername = null;
      });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _recentlyAddedTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Smart search with ranking ────────────────────────────────────────────

  List<WhitelistEntry> get _filtered {
    final q = _search.toLowerCase().trim();
    if (q.isEmpty) return _entries;

    final scored = <({WhitelistEntry entry, int score})>[];
    for (final e in _entries) {
      final name = e.name.toLowerCase();
      final key = e.hexKey.toLowerCase();
      int score = -1;

      if (name.startsWith(q) || key.startsWith(q)) {
        score = 0; // prefix match — highest rank
      } else if (name.contains(q) || key.contains(q)) {
        score = 1; // substring match
      }

      if (score >= 0) scored.add((entry: e, score: score));
    }
    scored.sort((a, b) => a.score.compareTo(b.score));
    return scored.map((s) => s.entry).toList();
  }

  String? _normalizeSearchUsername(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final base = t.startsWith('@') ? t.substring(1) : t;
    if (!RegExp(r'^[A-Za-z0-9_]{1,32}$').hasMatch(base)) return null;
    return '@$base';
  }

  void _onSearchChanged(String value) {
    setState(() => _search = value);
    _searchDebounce?.cancel();
    final normalized = _normalizeSearchUsername(value);
    if (normalized == null) {
      _searchRequestId++;
      setState(() {
        _serverSearchHit = null;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_searchOnServer(normalized));
    });
  }

  void _showAddedUsernameBanner(String username) {
    _recentlyAddedTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _recentlyAddedUsername = username;
    });
    _recentlyAddedTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _recentlyAddedUsername = null);
    });
  }

  Future<UserDirClient?> _buildUserDirClient() async {
    final nodes = await _repo.loadNodes();
    final selectedServerId = (widget.serverNodeId ?? '').trim();
    final node = selectedServerId.isNotEmpty
        ? nodes.where((n) => n.id == selectedServerId).firstOrNull
        : await _repo.loadPreferredNode();
    if (node == null) return null;
    final opts = await _repo.loadNodeServerOptions(node.id);
    if (opts == null) return null;
    return UserDirClient.forNode(node, opts);
  }

  Future<void> _searchOnServer(String normalizedUsername) async {
    final reqId = ++_searchRequestId;
    if (mounted) setState(() => _serverSearchHit = null);

    try {
      final client = await _buildUserDirClient();
      if (client == null) {
        if (!mounted || reqId != _searchRequestId) return;
        setState(() {
          _serverSearchHit = null;
        });
        return;
      }
      try {
        await client.connect();
        final items = await client.search(normalizedUsername, limit: 20);
        final lower = normalizedUsername.toLowerCase();
        final exact = items.where((m) => m.username.toLowerCase() == lower).firstOrNull;
        if (!mounted || reqId != _searchRequestId) return;
        if (exact == null) {
          setState(() {
            _serverSearchHit = null;
          });
          return;
        }
        final alreadyTrusted = _entries
            .any((e) => e.hexKey.toLowerCase() == exact.pubkeyHex.toLowerCase());
        setState(() {
          _serverSearchHit = alreadyTrusted
              ? null
              : _ServerSearchHit(
                  username: exact.username,
                  pubkeyHex: exact.pubkeyHex,
                  fullname: exact.fullname,
                );
        });
      } finally {
        client.close();
      }
    } catch (_) {
      if (!mounted || reqId != _searchRequestId) return;
      setState(() {
        _serverSearchHit = null;
      });
    }
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _save() async {
    await _repo.saveWhitelistEntriesForNode(widget.accountId, _entries);
    widget.onEntriesChanged(_entries);
  }

  // ── Import (QR or hex paste) ──────────────────────────────────────────────

  void _openImport() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Import Contact',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  IconButton(
                    icon:
                        const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Choose how you want to add a trusted contact.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 20),
              _SheetButton(
                icon: Icons.qr_code_scanner_outlined,
                label: 'Scan QR Code',
                onTap: () {
                  Navigator.pop(ctx);
                  _openQrScanner();
                },
              ),
              const SizedBox(height: 12),
              _SheetButton(
                icon: Icons.paste_outlined,
                label: 'Paste Hex',
                secondary: true,
                onTap: () {
                  Navigator.pop(ctx);
                  _showBase64ImportSheet();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openQrScanner() async {
    final data = await Navigator.of(context).push<QrShareData>(
      MaterialPageRoute(builder: (_) => const QrScannerDialog()),
    );
    if (data != null) {
      _handleImportData(data);
    }
  }

  void _showBase64ImportSheet() {
    final inputCtrl = TextEditingController();
    String? errorMsg;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Import Contact',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  IconButton(
                    icon:
                        const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Paste a contact share hex string or a raw 64-char public key.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              _StyledInput(
                controller: inputCtrl,
                icon: Icons.key_outlined,
                hint: 'Contact hex or public key…',
                maxLines: 3,
                monospace: true,
                error: errorMsg,
                onChanged: (_) => setS(() => errorMsg = null),
              ),
              const SizedBox(height: 16),
              _SheetButton(
                icon: Icons.download_outlined,
                label: 'Import',
                onTap: () {
                  final raw = inputCtrl.text.trim();
                  // Try as structured share payload first.
                  final qrData = QrShareData.parse(raw);
                  if (qrData != null) {
                    Navigator.pop(ctx);
                    _handleImportData(qrData);
                    return;
                  }
                  // Try as raw hex
                  final hex = raw.replaceAll(RegExp(r'\s+'), '');
                  if (hex.length == 64 &&
                      RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
                    Navigator.pop(ctx);
                    _showAddSheetWithKey(hex);
                    return;
                  }
                  setS(() => errorMsg =
                      'Invalid format: expected contact hex or 64-char public key');
                },
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(inputCtrl.dispose);
  }

  void _handleImportData(QrShareData data) {
    if (data.publicKeyHex == null) {
      _showSnack('QR code has no public key');
      return;
    }
    final hex = data.publicKeyHex!;
    if (_entries.any((e) => e.hexKey.toLowerCase() == hex.toLowerCase())) {
      _showSnack('This contact is already in your list');
      return;
    }
    _showAddSheetWithKey(hex, suggestedName: data.nickname);
  }

  // ── Add Contact ───────────────────────────────────────────────────────────

  void _addContact() => _showAddSheetWithKey('');

  void _showAddSheetWithKey(
    String prefilledKey, {
    String? suggestedName,
    VoidCallback? onAdded,
  }) {
    final nameCtrl = TextEditingController(text: suggestedName ?? '');
    final keyCtrl = TextEditingController(text: prefilledKey);
    String? keyError;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Add Contact',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  IconButton(
                    icon:
                        const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _StyledInput(
                controller: nameCtrl,
                icon: Icons.person_outline,
                hint: 'Display Name (Optional)',
              ),
              const SizedBox(height: 12),
              _StyledInput(
                controller: keyCtrl,
                icon: Icons.key_outlined,
                hint: 'Public Key (64 hex chars)',
                maxLines: 2,
                monospace: true,
                error: keyError,
                onChanged: (_) => setS(() => keyError = null),
              ),
              const SizedBox(height: 20),
              _SheetButton(
                icon: Icons.person_add_outlined,
                label: 'Add to Whitelist',
                onTap: () {
                  final name = nameCtrl.text.trim();
                  final hex =
                      keyCtrl.text.trim().replaceAll(RegExp(r'\s+'), '');

                  if (hex.length != 64 ||
                      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
                    setS(() => keyError = 'Must be exactly 64 hex characters');
                    return;
                  }
                  if (_entries.any(
                      (e) => e.hexKey.toLowerCase() == hex.toLowerCase())) {
                    setS(() => keyError = 'Key already in contacts');
                    return;
                  }

                  final bytes = Uint8List.fromList(List.generate(
                    32,
                    (i) =>
                        int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
                  ));
                  setState(() {
                    _entries.add(WhitelistEntry(
                      bytes: bytes,
                      name: name.isEmpty ? 'peer_${_entries.length + 1}' : name,
                    ));
                  });
                  _save();
                  onAdded?.call();
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      nameCtrl.dispose();
      keyCtrl.dispose();
    });
  }

  // ── Edit Contact ──────────────────────────────────────────────────────────

  void _editContact(WhitelistEntry entry) {
    final nameCtrl = TextEditingController(text: entry.name);
    final keyCtrl = TextEditingController(text: entry.hexKey);
    final profile = widget.contactProfiles[entry.hexKey];
    final username = profile?.username?.trim() ?? '';
    final hasUsername = username.isNotEmpty;
    String? keyError;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Edit Contact',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  IconButton(
                    icon:
                        const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _StyledInput(
                controller: nameCtrl,
                icon: Icons.person_outline,
                hint: 'Display Name',
              ),
              if (hasUsername) ...[
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.bgSurfaceActive,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.alternate_email,
                        size: 22,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          username,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _StyledInput(
                controller: keyCtrl,
                icon: Icons.key_outlined,
                hint: 'Public Key (64 hex chars)',
                maxLines: 2,
                monospace: true,
                error: keyError,
                onChanged: (_) => setS(() => keyError = null),
              ),
              const SizedBox(height: 4),
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'You can update the key if your contact regenerated their identity.',
                  style:
                      TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: 20),
              _SheetButton(
                icon: Icons.check,
                label: 'Save Changes',
                onTap: () {
                  final name = nameCtrl.text.trim();
                  final newHex =
                      keyCtrl.text.trim().replaceAll(RegExp(r'\s+'), '');

                  // Validate new key
                  if (newHex.length != 64 ||
                      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(newHex)) {
                    setS(() => keyError = 'Must be exactly 64 hex characters');
                    return;
                  }

                  // If key changed, check for duplicates against OTHER entries
                  final keyChanged =
                      newHex.toLowerCase() != entry.hexKey.toLowerCase();
                  if (keyChanged &&
                      _entries.any((e) =>
                          e.hexKey.toLowerCase() == newHex.toLowerCase())) {
                    setS(
                        () => keyError = 'This key already exists in contacts');
                    return;
                  }

                  final idx =
                      _entries.indexWhere((e) => e.hexKey == entry.hexKey);
                  if (idx != -1) {
                    final finalName = name.isEmpty ? entry.name : name;
                    if (keyChanged) {
                      // Rebuild entry with new key bytes
                      final bytes = Uint8List.fromList(List.generate(
                        32,
                        (i) => int.parse(newHex.substring(i * 2, i * 2 + 2),
                            radix: 16),
                      ));
                      setState(() {
                        _entries[idx] =
                            WhitelistEntry(bytes: bytes, name: finalName);
                      });
                    } else {
                      setState(() {
                        _entries[idx] = entry.copyWithName(finalName);
                      });
                    }
                    _save();
                  }
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      nameCtrl.dispose();
      keyCtrl.dispose();
    });
  }

  // ── Delete Contact ────────────────────────────────────────────────────────

  void _deleteContact(WhitelistEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Remove Peer?',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 12),
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.textSecondary,
                      height: 1.5),
                  children: [
                    const TextSpan(text: 'Remove '),
                    TextSpan(
                        text: entry.name,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600)),
                    const TextSpan(
                        text:
                            ' from trusted contacts? They will no longer be able to connect to your rooms.'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _SheetButton(
                      label: 'Cancel',
                      secondary: true,
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SheetButton(
                      label: 'Remove',
                      danger: true,
                      onTap: () {
                        setState(() => _entries
                            .removeWhere((e) => e.hexKey == entry.hexKey));
                        _save();
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Share / Copy Contact ──────────────────────────────────────────────────

  void _shareContact(WhitelistEntry entry) {
    final shareData = QrShareData(
      type: 'profile',
      publicKeyHex: entry.hexKey,
      nickname: entry.name,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: PrettyQrSharePanel(
          data: shareData,
          title: entry.name,
          subtitle: _shortKey(entry.hexKey),
          copyMessage: 'Contact hex copied',
          exportName:
              'contact-${entry.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _shortKey(String hex) =>
      '${hex.substring(0, 8)}…${hex.substring(hex.length - 8)}';

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
    ));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;

    return Scaffold(
      backgroundColor: AppColors.bgMain,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────────────
            Container(
              decoration: const BoxDecoration(
                color: AppColors.bgMain,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Contacts',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  // Import button
                  IconButton(
                    onPressed: _openImport,
                    tooltip: 'Import Contact',
                    icon: const Icon(
                      Icons.person_add_alt_1_outlined,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),

            // ── Top Panel: Search + Add Button ───────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  // Search box
                  Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.bgSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        const Icon(Icons.search,
                            size: 18, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: _onSearchChanged,
                            style: const TextStyle(
                                color: AppColors.textPrimary, fontSize: 14),
                            decoration: const InputDecoration(
                              hintText: 'Search contacts…',
                              hintStyle: TextStyle(
                                  color: AppColors.textSecondary, fontSize: 14),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                        if (_search.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _searchDebounce?.cancel();
                              _searchRequestId++;
                              _searchCtrl.clear();
                              setState(() {
                                _search = '';
                                _serverSearchHit = null;
                              });
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: Icon(Icons.cancel,
                                  size: 16, color: AppColors.textSecondary),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Add Contact primary button
                  _PrimaryButton(
                    icon: Icons.add_circle_outline,
                    label: 'Add Contact',
                    onTap: _addContact,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _SheetButton(
                          icon: Icons.qr_code_scanner_outlined,
                          label: 'Scan QR',
                          secondary: true,
                          onTap: _openQrScanner,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SheetButton(
                          icon: Icons.paste_outlined,
                          label: 'Paste Hex',
                          secondary: true,
                          onTap: _showBase64ImportSheet,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (_recentlyAddedUsername != null)
              _AddedUsernameBanner(
                username: _recentlyAddedUsername!,
                onClose: () => setState(() => _recentlyAddedUsername = null),
              ),

            if (_serverSearchHit != null) ...[
              const _SectionTitle(label: 'Search Results'),
              _ServerAddTile(
                username: _serverSearchHit!.username,
                onTap: () {
                  final hit = _serverSearchHit!;
                  final suggested = hit.fullname.trim().isNotEmpty
                      ? hit.fullname.trim()
                      : hit.username.replaceFirst('@', '');
                  _showAddSheetWithKey(
                    hit.pubkeyHex,
                    suggestedName: suggested,
                    onAdded: () {
                      _searchDebounce?.cancel();
                      _searchRequestId++;
                      _searchCtrl.clear();
                      setState(() {
                        _search = '';
                        _serverSearchHit = null;
                      });
                      _showAddedUsernameBanner(hit.username);
                    },
                  );
                },
              ),
            ],

            // ── Section Divider ──────────────────────────────────────────
            _SectionDivider(label: 'Trusted Peers', count: _entries.length),

            // ── List ─────────────────────────────────────────────────────
            Expanded(
              child: filtered.isEmpty
                  ? _EmptyState(hasAny: _entries.isNotEmpty)
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 120),
                      itemCount: filtered.length,
                      itemBuilder: (ctx, i) {
                        final e = filtered[i];
                        return _ContactTile(
                          entry: e,
                          profile: widget.contactProfiles[e.hexKey],
                          shortKey: _shortKey(e.hexKey),
                          onTap: () => _editContact(e),
                          onShare: () => _shareContact(e),
                          onDelete: () => _deleteContact(e),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddedUsernameBanner extends StatelessWidget {
  final String username;
  final VoidCallback onClose;

  const _AddedUsernameBanner({
    required this.username,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF183127),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2E6C4D)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF72D69C), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$username added to contacts',
                style: const TextStyle(
                  color: Color(0xFFD9F7E6),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            GestureDetector(
              onTap: onClose,
              child: const Icon(
                Icons.close,
                size: 16,
                color: Color(0xFF72D69C),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerSearchHit {
  final String username;
  final String pubkeyHex;
  final String fullname;

  const _ServerSearchHit({
    required this.username,
    required this.pubkeyHex,
    required this.fullname,
  });
}

class _SectionTitle extends StatelessWidget {
  final String label;
  const _SectionTitle({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }
}

class _ServerAddTile extends StatelessWidget {
  final String username;
  final VoidCallback onTap;

  const _ServerAddTile({
    required this.username,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.bgSurfaceActive,
      highlightColor: AppColors.bgSurfaceActive.withAlpha(80),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(8),
          border: const Border(
            top: BorderSide(color: AppColors.border),
            bottom: BorderSide(color: AppColors.border),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: const Icon(Icons.person_add, size: 22, color: Colors.black),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add "$username"',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Click to create and add to trusted peers',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              size: 22,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Contact Tile ─────────────────────────────────────────────────────────────

class _ContactTile extends StatelessWidget {
  final WhitelistEntry entry;
  final ContactProfile? profile;
  final String shortKey;
  final VoidCallback onTap;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  const _ContactTile({
    required this.entry,
    required this.shortKey,
    required this.onTap,
    required this.onShare,
    required this.onDelete,
    this.profile,
  });


  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.bgSurfaceActive,
      highlightColor: AppColors.bgSurfaceActive.withAlpha(80),
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            UserAvatar(name: entry.name, bytes: profile?.avatarBytes, size: 46),
            const SizedBox(width: 14),

            // Name + key
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary),
                      overflow: TextOverflow.ellipsis),
                  if ((profile?.username?.trim().isNotEmpty ?? false)) ...[
                    const SizedBox(height: 1),
                    Text(
                      profile!.username!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(shortKey,
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: AppColors.textSecondary)),
                ],
              ),
            ),

            // Actions: copy/share + delete
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionBtn(
                  icon: Icons.ios_share_outlined,
                  tooltip: 'Share / Copy',
                  onTap: onShare,
                ),
                _ActionBtn(
                  icon: Icons.delete_outline,
                  tooltip: 'Remove',
                  danger: true,
                  onTap: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Reusable UI pieces ────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  const _ActionBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
        ),
        child: Icon(icon,
            size: 20,
            color: danger ? AppColors.statusRed : AppColors.textSecondary),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;

  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: Colors.black),
              const SizedBox(width: 8),
            ],
            Text(label,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.black)),
          ],
        ),
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool secondary;
  final bool danger;

  const _SheetButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.secondary = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    if (danger) {
      bg = AppColors.statusRed;
      fg = Colors.white;
    } else if (secondary) {
      bg = AppColors.bgSurfaceActive;
      fg = AppColors.textPrimary;
    } else {
      bg = AppColors.accent;
      fg = Colors.black;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 48,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: secondary ? Border.all(color: AppColors.border) : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
            ],
            Text(label,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
          ],
        ),
      ),
    );
  }
}

class _StyledInput extends StatelessWidget {
  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final int maxLines;
  final bool monospace;
  final String? error;
  final ValueChanged<String>? onChanged;

  const _StyledInput({
    required this.controller,
    required this.icon,
    required this.hint,
    this.maxLines = 1,
    this.monospace = false,
    this.error,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.bgSurfaceActive,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: error != null ? AppColors.statusRed : AppColors.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: maxLines > 1
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              Padding(
                padding: EdgeInsets.only(top: maxLines > 1 ? 14 : 0),
                child: Icon(icon, size: 22, color: AppColors.textSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLines: maxLines,
                  onChanged: onChanged,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontFamily: monospace ? 'monospace' : null,
                  ),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 15),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(error!,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.statusRed)),
          ),
        ],
      ],
    );
  }
}

class _SectionDivider extends StatelessWidget {
  final String label;
  final int count;
  const _SectionDivider({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Text(
            '$label ($count)'.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasAny;
  const _EmptyState({required this.hasAny});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.contacts_outlined,
                size: 72, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              hasAny ? 'No contacts found' : 'No contacts yet',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasAny
                  ? 'Try a different search'
                  : 'Add trusted peers by their\npublic key to allow connections.',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
