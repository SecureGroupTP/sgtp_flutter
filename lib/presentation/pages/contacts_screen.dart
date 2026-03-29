import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../data/repositories/settings_repository.dart';

/// Contacts screen — shows the trusted-peer whitelist.
/// Users can add peers by public key hex, rename them, delete them.
class ContactsScreen extends StatefulWidget {
  final List<WhitelistEntry> initialEntries;

  /// Called whenever the whitelist changes so HomeScreen can propagate
  /// updated nicknames to RoomsBloc.
  final void Function(List<WhitelistEntry> entries) onEntriesChanged;

  const ContactsScreen({
    super.key,
    required this.initialEntries,
    required this.onEntriesChanged,
  });

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _repo = SettingsRepository();
  late List<WhitelistEntry> _entries;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _entries = List.from(widget.initialEntries);
  }

  List<WhitelistEntry> get _filtered {
    if (_search.isEmpty) return _entries;
    final q = _search.toLowerCase();
    return _entries.where((e) =>
        e.name.toLowerCase().contains(q) ||
        e.hexKey.toLowerCase().contains(q)).toList();
  }

  Future<void> _save() async {
    await _repo.saveWhitelistEntries(_entries);
    widget.onEntriesChanged(_entries);
  }

  void _addContact() {
    _showContactDialog(null);
  }

  void _editContact(WhitelistEntry entry) {
    _showContactDialog(entry);
  }

  void _showContactDialog(WhitelistEntry? existing) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final keyCtrl  = TextEditingController(text: existing?.hexKey ?? '');
    String? keyError;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: AppColors.bgSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            existing == null ? 'Add contact' : 'Edit contact',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DarkField(
                controller: nameCtrl,
                label: 'Name',
                hint: 'e.g. Alice',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 14),
              _DarkField(
                controller: keyCtrl,
                label: 'Public key (hex)',
                hint: '64 hex characters',
                icon: Icons.vpn_key_outlined,
                enabled: existing == null, // key is immutable after add
                maxLines: 2,
                errorText: keyError,
                onChanged: (_) => setS(() => keyError = null),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                final name = nameCtrl.text.trim();
                final hex  = keyCtrl.text.trim().replaceAll(RegExp(r'\s+'), '');

                if (existing == null) {
                  // Validate key
                  if (hex.length != 64 ||
                      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
                    setS(() => keyError = 'Must be exactly 64 hex characters');
                    return;
                  }
                  if (_entries.any((e) => e.hexKey.toLowerCase() ==
                      hex.toLowerCase())) {
                    setS(() => keyError = 'Key already in contacts');
                    return;
                  }
                  final bytes = Uint8List.fromList(List.generate(
                    32,
                    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
                  ));
                  setState(() {
                    _entries.add(WhitelistEntry(
                      bytes: bytes,
                      name:  name.isEmpty ? 'peer_${_entries.length + 1}' : name,
                    ));
                  });
                } else {
                  // Just rename
                  final idx = _entries.indexWhere(
                      (e) => e.hexKey == existing.hexKey);
                  if (idx != -1) {
                    setState(() {
                      _entries[idx] = existing.copyWithName(
                          name.isEmpty ? existing.name : name);
                    });
                  }
                }
                _save();
                Navigator.pop(ctx);
              },
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteContact(WhitelistEntry entry) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove contact',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
        content: Text(
          'Remove "${entry.name}" from trusted contacts?\n\nThey will no longer be able to connect to your rooms.',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              setState(() => _entries.removeWhere(
                  (e) => e.hexKey == entry.hexKey));
              _save();
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(
                foregroundColor: AppColors.statusRed),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

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
                border: Border(
                    bottom: BorderSide(color: AppColors.border)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Contacts',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  _CountBadge(count: _entries.length),
                ],
              ),
            ),

            // ── Search ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.bgSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    const Icon(Icons.search, size: 18,
                        color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
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
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── List ─────────────────────────────────────────────────────
            Expanded(
              child: filtered.isEmpty
                  ? _EmptyState(hasAny: _entries.isNotEmpty)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 120),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(
                        color: AppColors.border,
                        height: 1,
                        indent: 76,
                      ),
                      itemBuilder: (ctx, i) => _ContactTile(
                        entry: filtered[i],
                        onEdit:   () => _editContact(filtered[i]),
                        onDelete: () => _deleteContact(filtered[i]),
                        onCopy:   () {
                          Clipboard.setData(
                              ClipboardData(text: filtered[i].hexKey));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Public key copied'),
                              behavior: SnackBarBehavior.floating,
                              margin: EdgeInsets.fromLTRB(16, 0, 16, 80),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),

      // ── FAB ─────────────────────────────────────────────────────────────
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom),
        child: FloatingActionButton(
          onPressed: _addContact,
          tooltip: 'Add contact',
          backgroundColor: AppColors.accentBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18)),
          child: const Icon(Icons.person_add_outlined, size: 26),
        ),
      ),
    );
  }
}

// ─── Tiles ────────────────────────────────────────────────────────────────────

class _ContactTile extends StatelessWidget {
  final WhitelistEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCopy;

  const _ContactTile({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
    required this.onCopy,
  });

  Color _avatarColor(String name) {
    final colors = [
      const Color(0xFF0A84FF),
      const Color(0xFF34C759),
      const Color(0xFFFF9F0A),
      const Color(0xFFFF3B30),
      const Color(0xFFAF52DE),
      const Color(0xFF5AC8FA),
      const Color(0xFFFF2D55),
    ];
    int hash = 0;
    for (final c in name.runes) hash = (hash * 31 + c) & 0xFFFFFFFF;
    return colors[hash % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final initial = entry.name.isNotEmpty
        ? entry.name[0].toUpperCase()
        : '?';
    final shortKey = '${entry.hexKey.substring(0, 8)}…'
        '${entry.hexKey.substring(entry.hexKey.length - 8)}';

    return InkWell(
      onTap: onEdit,
      splashColor: AppColors.bgSurfaceActive,
      highlightColor: AppColors.bgSurfaceActive.withAlpha(80),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Avatar circle
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _avatarColor(entry.name),
              ),
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),

            // Name + key
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    shortKey,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),

            // Actions
            PopupMenuButton<_Action>(
              icon: const Icon(Icons.more_vert,
                  size: 20, color: AppColors.textSecondary),
              color: AppColors.bgSurface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              onSelected: (a) {
                switch (a) {
                  case _Action.edit:   onEdit();   break;
                  case _Action.copy:   onCopy();   break;
                  case _Action.delete: onDelete(); break;
                }
              },
              itemBuilder: (_) => [
                _menuItem(Icons.edit_outlined,   'Rename',   _Action.edit),
                _menuItem(Icons.copy_outlined,   'Copy key', _Action.copy),
                const PopupMenuDivider(),
                _menuItem(Icons.delete_outline,  'Remove',   _Action.delete,
                    color: AppColors.statusRed),
              ],
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<_Action> _menuItem(
      IconData icon, String label, _Action action,
      {Color color = AppColors.textPrimary}) {
    return PopupMenuItem(
      value: action,
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color, fontSize: 14)),
      ]),
    );
  }
}

enum _Action { edit, copy, delete }

// ─── Helpers ──────────────────────────────────────────────────────────────────

class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
        ),
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
              style: const TextStyle(
                  fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _DarkField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool enabled;
  final int maxLines;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  const _DarkField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.enabled  = true,
    this.maxLines = 1,
    this.errorText,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines:   maxLines,
      enabled:    enabled,
      onChanged:  onChanged,
      style: const TextStyle(
          color: AppColors.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText:  label,
        labelStyle: const TextStyle(
            color: AppColors.textSecondary, fontSize: 13),
        hintText:   hint,
        hintStyle:  const TextStyle(
            color: AppColors.textSecondary, fontSize: 13),
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 18),
        errorText:  errorText,
        errorStyle: const TextStyle(
            color: AppColors.statusRed, fontSize: 12),
        filled:     true,
        fillColor:  AppColors.bgMain,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.accentBlue),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.statusRed),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.statusRed),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}