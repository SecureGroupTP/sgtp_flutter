import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/widgets/app_bottom_sheet.dart';
import 'package:sgtp_flutter/core/qr_data.dart';
import 'package:sgtp_flutter/features/contacts/application/models/contacts_models.dart';
import 'package:sgtp_flutter/features/contacts/application/viewmodels/contacts_cubit.dart';
import 'package:sgtp_flutter/features/settings/presentation/widgets/pretty_qr_share_panel.dart';
import 'package:sgtp_flutter/features/messaging/presentation/widgets/qr_scanner_dialog.dart';
import 'package:sgtp_flutter/features/contacts/presentation/widgets/user_avatar.dart';

/// Contacts screen — shows the contacts.
/// Users can add peers by public key hex/share-hex, rename them, delete them.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _searchCtrl = TextEditingController();
  ContactsCubit get _cubit => context.read<ContactsCubit>();

  void _respondToFriend(String peerPubkeyHex, bool accept) {
    _cubit.respondToFriend(peerPubkeyHex, accept);
  }

  void _openDirectMessage(String peerPubkeyHex) {
    _cubit.openDirectMessage(peerPubkeyHex);
  }

  void _disposeControllerNextFrame(TextEditingController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _syncSearchController(String value) {
    if (_searchCtrl.text == value) return;
    _searchCtrl.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  // ── Import (QR or hex paste) ──────────────────────────────────────────────

  void _openImport() {
    showAppBottomSheet<void>(
      context,
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
                'Choose how you want to add a contact.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 20),
              AppSheetButton(
                icon: Icons.qr_code_scanner_outlined,
                label: 'Scan QR Code',
                onTap: () {
                  Navigator.pop(ctx);
                  _openQrScanner();
                },
              ),
              const SizedBox(height: 12),
              AppSheetButton(
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

  Future<void> _openQrScanner() async {
    final data = await Navigator.of(context).push<QrShareData>(
      MaterialPageRoute(builder: (_) => const QrScannerDialog()),
    );
    if (data != null) {
      _handleImportData(data);
    }
  }

  void _showBase64ImportSheet() {
    final cubit = _cubit;
    final inputCtrl = TextEditingController();
    String? errorMsg;

    showAppBottomSheet<void>(
      context,
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
              AppSheetButton(
                icon: Icons.download_outlined,
                label: 'Import',
                onTap: () {
                  final raw = inputCtrl.text.trim();
                  final qrData = QrShareData.parse(raw);
                  if (qrData != null) {
                    Navigator.pop(ctx);
                    _handleImportData(qrData);
                    return;
                  }

                  final hex = raw.replaceAll(RegExp(r'\s+'), '');
                  final validationError = cubit.validateNewContactHex(hex);
                  if (validationError == null) {
                    Navigator.pop(ctx);
                    _showAddSheetWithKey(hex);
                    return;
                  }
                  setS(() => errorMsg = validationError);
                },
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() => _disposeControllerNextFrame(inputCtrl));
  }

  void _handleImportData(QrShareData data) {
    final error = _cubit.validateImportedQrData(data);
    if (error != null) {
      _showSnack(error);
      return;
    }
    _showAddSheetWithKey(
      data.publicKeyHex!,
      suggestedName: data.nickname,
    );
  }

  // ── Add Contact ───────────────────────────────────────────────────────────

  void _addContact() => _showAddSheetWithKey('');

  void _showAddSheetWithKey(
    String prefilledKey, {
    String? suggestedName,
    String? recentlyAddedUsername,
  }) {
    final cubit = _cubit;
    final nameCtrl = TextEditingController(text: suggestedName ?? '');
    final keyCtrl = TextEditingController(text: prefilledKey);
    String? keyError;

    showAppBottomSheet<void>(
      context,
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
              AppSheetButton(
                icon: Icons.person_add_outlined,
                label: 'Add Contact',
                onTap: () async {
                  final error = await cubit.addContact(
                    name: nameCtrl.text,
                    rawHex: keyCtrl.text,
                    recentlyAddedUsername: recentlyAddedUsername,
                  );
                  if (error != null) {
                    setS(() => keyError = error);
                    return;
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      _disposeControllerNextFrame(nameCtrl);
      _disposeControllerNextFrame(keyCtrl);
    });
  }

  // ── Edit Contact ──────────────────────────────────────────────────────────

  void _editContact(ContactsContactUiModel contact) {
    final cubit = _cubit;
    final nameCtrl = TextEditingController(text: contact.displayName);
    final keyCtrl = TextEditingController(text: contact.hexKey);
    final username = contact.username?.trim() ?? '';
    final hasUsername = username.isNotEmpty;
    String? keyError;

    showAppBottomSheet<void>(
      context,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
              AppSheetButton(
                icon: Icons.check,
                label: 'Save Changes',
                onTap: () async {
                  final error = await cubit.editContact(
                    originalHex: contact.hexKey,
                    name: nameCtrl.text,
                    rawHex: keyCtrl.text,
                  );
                  if (error != null) {
                    setS(() => keyError = error);
                    return;
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      _disposeControllerNextFrame(nameCtrl);
      _disposeControllerNextFrame(keyCtrl);
    });
  }

  // ── Delete Contact ────────────────────────────────────────────────────────

  void _deleteContact(ContactsContactUiModel contact) {
    final cubit = _cubit;
    showAppBottomSheet<void>(
      context,
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
                        text: contact.displayName,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600)),
                    const TextSpan(
                        text:
                            ' from contacts?'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: AppSheetButton(
                      label: 'Cancel',
                      secondary: true,
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppSheetButton(
                      label: 'Remove',
                      danger: true,
                      onTap: () async {
                        final error = await cubit.deleteContact(contact.hexKey);
                        if (error != null) {
                          _showSnack(error);
                          return;
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
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

  void _shareContact(ContactsContactUiModel contact) {
    final shareData = QrShareData(
      type: 'profile',
      publicKeyHex: contact.hexKey,
      nickname: contact.displayName,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    showAppBottomSheet<void>(
      context,
      builder: (ctx) => SafeArea(
        child: PrettyQrSharePanel(
          data: shareData,
          title: contact.displayName,
          subtitle: contact.shortKey,
          copyMessage: 'Contact hex copied',
          exportName:
              'contact-${contact.displayName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ContactsCubit>().state;
    _syncSearchController(state.searchQuery);

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
                            onChanged: _cubit.onSearchChanged,
                            style: const TextStyle(
                                color: AppColors.textPrimary, fontSize: 14),
                            decoration: const InputDecoration(
                              hintText: 'Search contacts...',
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
                        if (state.isSearchingServer)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        if (state.searchQuery.isNotEmpty)
                          GestureDetector(
                            onTap: _cubit.clearSearch,
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
                        child: AppSheetButton(
                          icon: Icons.qr_code_scanner_outlined,
                          label: 'Scan QR',
                          secondary: true,
                          onTap: _openQrScanner,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AppSheetButton(
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

            if (state.recentlyAddedUsername != null)
              _AddedUsernameBanner(
                username: state.recentlyAddedUsername!,
                onClose: _cubit.dismissRecentlyAddedUsername,
              ),

            if (state.serverSearchHit != null) ...[
              const _SectionTitle(label: 'Search Results'),
              _ServerAddTile(
                username: state.serverSearchHit!.username,
                onTap: () {
                  final hit = state.serverSearchHit!;
                  _showAddSheetWithKey(
                    hit.pubkeyHex,
                    suggestedName: hit.suggestedName,
                    recentlyAddedUsername: hit.username,
                  );
                },
              ),
            ],

            if (state.incomingRequests.isNotEmpty) ...[
              _SectionDivider(
                label: 'Friend Requests',
                count: state.incomingRequests.length,
              ),
              ...state.incomingRequests.map((request) => _IncomingFriendTile(
                    request: request,
                    onReject: () => _respondToFriend(request.peerHex, false),
                    onAccept: () => _respondToFriend(request.peerHex, true),
                  )),
            ],

            // ── Section Divider ──────────────────────────────────────────
            _SectionDivider(label: 'Trusted Peers', count: state.totalContacts),

            // ── List ─────────────────────────────────────────────────────
            Expanded(
              child: state.contacts.isEmpty
                  ? _EmptyState(hasAny: state.hasAnyContacts)
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 120),
                      itemCount: state.contacts.length,
                      itemBuilder: (ctx, i) {
                        final contact = state.contacts[i];
                        return _ContactTile(
                          contact: contact,
                          onTap: () => _editContact(contact),
                          onShare: () => _shareContact(contact),
                          onDelete: () => _deleteContact(contact),
                          onReject: () =>
                              _respondToFriend(contact.hexKey, false),
                          onAccept: () =>
                              _respondToFriend(contact.hexKey, true),
                          onMessage:
                              contact.friendStatus != ContactsFriendStatus.friend
                                  ? null
                                  : () => _openDirectMessage(contact.hexKey),
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
              child:
                  const Icon(Icons.person_add, size: 22, color: Colors.black),
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
                    'Click to create and add to contacts',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.textSecondary),
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
  final ContactsContactUiModel contact;
  final VoidCallback onTap;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback? onReject;
  final VoidCallback? onAccept;
  final VoidCallback? onMessage;

  const _ContactTile({
    required this.contact,
    required this.onTap,
    required this.onShare,
    required this.onDelete,
    this.onReject,
    this.onAccept,
    this.onMessage,
  });

  @override
  Widget build(BuildContext context) {
    final status = contact.friendStatus;
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
            UserAvatar(
              name: contact.displayName,
              bytes: contact.avatarBytes,
              size: 46,
            ),
            const SizedBox(width: 14),

            // Name + key
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.displayName,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary),
                      overflow: TextOverflow.ellipsis),
                  if ((contact.username?.trim().isNotEmpty ?? false)) ...[
                    const SizedBox(height: 1),
                    Text(
                      contact.username!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(contact.shortKey,
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  _FriendBadge(status: status),
                ],
              ),
            ),

            // Actions: copy/share + delete
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (status == ContactsFriendStatus.pendingIncoming &&
                    onReject != null)
                  _MiniTextBtn(
                    label: 'NO',
                    color: AppColors.statusRed,
                    onTap: onReject!,
                  ),
                if (status == ContactsFriendStatus.pendingIncoming &&
                    onReject != null)
                  const SizedBox(width: 4),
                if (status == ContactsFriendStatus.pendingIncoming &&
                    onAccept != null)
                  _MiniTextBtn(
                    label: 'YES',
                    color: const Color(0xFF2E7D32),
                    onTap: onAccept!,
                  ),
                if (status == ContactsFriendStatus.friend && onMessage != null)
                  _MiniTextBtn(
                    label: 'Message',
                    color: AppColors.accent,
                    textColor: Colors.black,
                    onTap: onMessage!,
                  ),
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

class _IncomingFriendTile extends StatelessWidget {
  final ContactsIncomingRequestUiModel request;
  final VoidCallback? onReject;
  final VoidCallback? onAccept;

  const _IncomingFriendTile({
    required this.request,
    this.onReject,
    this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          UserAvatar(
            name: request.displayName,
            bytes: request.avatarBytes,
            size: 46,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if ((request.username?.trim().isNotEmpty ?? false)) ...[
                  const SizedBox(height: 1),
                  Text(
                    request.username!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  request.shortKey,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                const _FriendBadge(
                    status: ContactsFriendStatus.pendingIncoming),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniTextBtn(
                label: 'NO',
                color: AppColors.statusRed,
                onTap: onReject ?? () {},
              ),
              const SizedBox(width: 4),
              _MiniTextBtn(
                label: 'YES',
                color: const Color(0xFF2E7D32),
                onTap: onAccept ?? () {},
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FriendBadge extends StatelessWidget {
  final ContactsFriendStatus status;
  const _FriendBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == ContactsFriendStatus.none) return const SizedBox.shrink();
    Color bg;
    Color border;
    String text;
    switch (status) {
      case ContactsFriendStatus.pendingOutgoing:
      case ContactsFriendStatus.pendingIncoming:
        bg = const Color(0x33FFB300);
        border = const Color(0xFFE6A100);
        text = 'Pending';
        break;
      case ContactsFriendStatus.friend:
        bg = const Color(0x332E7D32);
        border = const Color(0xFF2E7D32);
        text = 'Friend';
        break;
      case ContactsFriendStatus.rejected:
        bg = const Color(0x33C62828);
        border = const Color(0xFFC62828);
        text = 'Rejected';
        break;
      case ContactsFriendStatus.none:
        return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _MiniTextBtn extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;

  const _MiniTextBtn({
    required this.label,
    required this.color,
    required this.onTap,
    this.textColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
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
                  : 'Add people by their\npublic key to start chatting.',
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

