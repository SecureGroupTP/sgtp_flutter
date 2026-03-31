import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../core/qr_data.dart';
import '../../data/repositories/settings_repository.dart';
import '../widgets/pretty_qr_share_panel.dart';
import '../widgets/qr_scanner_dialog.dart';

/// Contacts screen — shows the trusted-peer whitelist.
/// Users can add peers by public key hex/share-hex, rename them, delete them.
class ContactsScreen extends StatefulWidget {
  final String accountId;
  final List<WhitelistEntry> initialEntries;
  final Map<String, ContactProfile> contactProfiles;

  /// Called whenever the whitelist changes so HomeScreen can propagate
  /// updated nicknames to RoomsBloc.
  final void Function(List<WhitelistEntry> entries) onEntriesChanged;

  const ContactsScreen({
    super.key,
    required this.accountId,
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
  String _search = '';

  @override
  void initState() {
    super.initState();
    _entries = List.from(widget.initialEntries);
  }

  @override
  void didUpdateWidget(covariant ContactsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) {
      setState(() {
        _entries = List.from(widget.initialEntries);
        _search = '';
        _searchCtrl.clear();
      });
    }
  }

  @override
  void dispose() {
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
    );
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

  void _showAddSheetWithKey(String prefilledKey, {String? suggestedName}) {
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
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Edit Contact ──────────────────────────────────────────────────────────

  void _editContact(WhitelistEntry entry) {
    final nameCtrl = TextEditingController(text: entry.name);
    final keyCtrl = TextEditingController(text: entry.hexKey);
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
    );
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
                            onChanged: (v) => setState(() => _search = v),
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
                              _searchCtrl.clear();
                              setState(() => _search = '');
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
                          avatar: widget.contactProfiles[e.hexKey]?.avatarBytes,
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

// ─── Contact Tile ─────────────────────────────────────────────────────────────

class _ContactTile extends StatelessWidget {
  final WhitelistEntry entry;
  final Uint8List? avatar;
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
    this.avatar,
  });

  // Returns 1 or 2 initials: two-word names → "JD", single-word → "J"
  static String _initials(String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) return '?';
    final words = cleaned.split(RegExp(r'\s+'));
    if (words.length >= 2) {
      return (words[0][0] + words[1][0]).toUpperCase();
    }
    return cleaned[0].toUpperCase();
  }

  // Gradient palette matching pfps.html
  static const List<List<Color>> _gradients = [
    [Color(0xFFFF7676), Color(0xFFE53935)], // Red
    [Color(0xFFFFAE34), Color(0xFFF57C00)], // Orange
    [Color(0xFF66CC6C), Color(0xFF2E7D32)], // Green
    [Color(0xFF4DD0E1), Color(0xFF0097A7)], // Teal
    [Color(0xFF42A5F5), Color(0xFF1E88E5)], // Blue
    [Color(0xFF7E57C2), Color(0xFF4527A0)], // Violet
    [Color(0xFFAB47BC), Color(0xFF7B1FA2)], // Purple
    [Color(0xFFEC407A), Color(0xFFC2185B)], // Pink
  ];

  List<Color> _avatarGradient(String name) {
    int h = 0;
    for (int i = 0; i < name.length; i++) {
      h = name.codeUnitAt(i) + ((h << 5) - h);
    }
    return _gradients[h.abs() % _gradients.length];
  }

  @override
  Widget build(BuildContext context) {
    final initial = _initials(entry.name);
    final gradient = _avatarGradient(entry.name);

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
            // Avatar
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: avatar == null
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradient,
                      )
                    : null,
                image: avatar != null
                    ? DecorationImage(
                        image: MemoryImage(avatar!),
                        fit: BoxFit.cover,
                      )
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(13),
                    blurRadius: 0,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: avatar == null
                  ? Center(
                      child: Text(initial,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                              height: 1.0)),
                    )
                  : null,
            ),
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
