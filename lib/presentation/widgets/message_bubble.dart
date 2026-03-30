import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/interaction_prefs.dart';
import '../../domain/entities/message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final Map<String, String> peerNicknames;
  final String myUUID;
  final Map<String, Uint8List> peerAvatars;
  final Uint8List? userAvatarBytes;
  final Map<String, Set<String>> readReceipts;
  final int peerCount;

  /// Called when user wants to reply to this message.
  final VoidCallback? onReply;

  /// Called when user picks an emoji reaction.
  final void Function(String emoji)? onReact;

  /// Emoji list shown in long-press reaction popup.
  final List<String> quickEmojis;

  const MessageBubble({
    super.key,
    required this.message,
    this.peerNicknames = const {},
    this.myUUID = '',
    this.peerAvatars = const {},
    this.userAvatarBytes,
    this.readReceipts = const {},
    this.peerCount = 0,
    this.onReply,
    this.onReact,
    this.quickEmojis = const ['👍','❤️','😂','😮','😢','🔥','👏','🎉','🤔','💯'],
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final cs      = theme.colorScheme;
    final isMe    = message.isFromMe;
    final timeStr = _formatTime(message.receivedAt);
    final senderLabel = _buildSenderLabel();

    // System messages have no bubble frame
    if (message.type == MessageType.system) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: _buildSystemContent(context, theme),
      );
    }

    // messageRead is invisible in the list – handled by readReceipts tracking
    if (message.type == MessageType.messageRead) {
      return const SizedBox.shrink();
    }

    // Voice messages: no bubble frame but need reactions row — fall through to
    // the main Column below. Only skip if it's truly invisible.
    if (message.type == MessageType.voice) {
      const ownBubbleBg   = Color(0xFF0A84FF);
      const otherBubbleBg = Color(0xFF1F1F24);
      final bgColor = isMe ? ownBubbleBg : otherBubbleBg;

      final voiceWidget = _withAvatar(
        context: context,
        isMe: isMe,
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78),
            child: Container(
              margin: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.only(
                  topLeft:     const Radius.circular(16),
                  topRight:    const Radius.circular(16),
                  bottomLeft:  Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                border: isMe ? null : Border.all(color: const Color(0xFF2C2C30)),
              ),
              child: _buildVoiceContent(
                  context, theme, cs.onSurfaceVariant, senderLabel, timeStr, isMe),
            ),
          ),
        ),
      );
      final reactionsRow = _buildReactionsRow(theme, cs);
      return Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(left: 42, bottom: 2),
              child: _senderLabel(theme, senderLabel),
            ),
          voiceWidget,
          if (reactionsRow != null)
            Padding(
              padding: EdgeInsets.only(
                left: isMe ? 0 : 44,
                right: isMe ? 8 : 0,
              ),
              child: Transform.translate(
                offset: const Offset(0, -8),
                child: reactionsRow,
              ),
            ),
          _buildMetaRow(theme, cs, timeStr, isMe),
        ],
      );
    }

    // Video notes: circular — no bubble bg for own messages (only blue ring)
    if (message.type == MessageType.videoNote) {
      final noteWidget = _withAvatar(
        context: context,
        isMe: isMe,
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(
              left: 8, right: 8,
              top: 4, bottom: 4,
            ),
            child: _buildVideoNoteContent(
                context, theme, Colors.white, senderLabel, timeStr, isMe),
          ),
        ),
      );
      final reactionsRow = _buildReactionsRow(theme, cs);
      return Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(left: 42, bottom: 2),
              child: _senderLabel(theme, senderLabel),
            ),
          noteWidget,
          if (reactionsRow != null)
            Padding(
              padding: EdgeInsets.only(
                left: isMe ? 0 : 44,
                right: isMe ? 8 : 0,
              ),
              child: Transform.translate(
                offset: const Offset(0, -8),
                child: reactionsRow,
              ),
            ),
          _buildMetaRow(theme, cs, timeStr, isMe),
        ],
      );
    }

    // Own bubbles: #0A84FF fill, white text
    // Other bubbles: #1F1F24 fill, #8E8E93 text, #2C2C30 border
    const ownBubbleBg    = Color(0xFF0A84FF);
    const otherBubbleBg  = Color(0xFF1F1F24);
    const ownTextColor   = Colors.white;
    const otherTextColor = Color(0xFFF5F5F5);
    final bgColor   = isMe ? ownBubbleBg   : otherBubbleBg;
    final textColor = isMe ? ownTextColor  : otherTextColor;

    // Reply strip rendered INSIDE the bubble (matches design: quote block
    // sits on top of the coloured bubble background).
    Widget? replyStrip;
    if (message.replyToId != null) {
      replyStrip = Container(
        margin: const EdgeInsets.only(left: 8, right: 8, top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isMe
              ? Colors.white.withAlpha(38)
              : Colors.black.withAlpha(51),
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(
              color: isMe ? Colors.white : const Color(0xFF0A84FF),
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.replyToSender != null)
              Text(message.replyToSender!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isMe ? Colors.white : const Color(0xFF0A84FF),
                  )),
            Text(message.replyToContent ?? '…',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: isMe
                      ? Colors.white.withAlpha(180)
                      : const Color(0xFF8E8E93),
                )),
          ],
        ),
      );
    }

    final innerBubble = Container(
      margin: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.only(
          topLeft:     const Radius.circular(16),
          topRight:    const Radius.circular(16),
          bottomLeft:  Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
        border: isMe
            ? null
            : Border.all(color: const Color(0xFF2C2C30)),
      ),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (replyStrip != null) replyStrip,
            _buildContent(context, theme, textColor, senderLabel, timeStr, isMe),
          ],
        ),
      ),
    );

    Widget bubbleWithReply;
    {
      bubbleWithReply = ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: innerBubble,
      );
    }

    final alignedBubble = Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onDoubleTap: _doubleTapAction(context),
        onLongPress: onReact == null ? null : () => _showContextMenu(context, Theme.of(context)),
        onSecondaryTap: onReact == null ? null : () => _showContextMenu(context, Theme.of(context)),
        behavior: HitTestBehavior.translucent,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            bubbleWithReply,
            // Sending progress overlay on innerBubble only
            if (message.isSending)
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      LinearProgressIndicator(
                        value: message.sendProgress > 0 ? message.sendProgress : null,
                        minHeight: 3,
                        backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(40),
                        valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // Reactions — positioned to slightly overlap the bottom of the bubble
    final reactionsRow = _buildReactionsRow(theme, cs);

    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isMe)
          Padding(
            padding: const EdgeInsets.only(left: 42, bottom: 2),
            child: _senderLabel(Theme.of(context), senderLabel),
          ),
        _withAvatar(context: context, isMe: isMe, child: alignedBubble),
        if (reactionsRow != null)
          Padding(
            padding: EdgeInsets.only(
              left: isMe ? 0 : 44,
              right: isMe ? 8 : 0,
              // Negative top margin so reactions sit on the bubble border
              bottom: 4,
            ),
            child: Transform.translate(
              offset: const Offset(0, -8),
              child: reactionsRow,
            ),
          ),
        _buildMetaRow(theme, cs, timeStr, isMe),
      ],
    );
  }

  /// Returns the double-tap callback based on platform and user prefs.
  VoidCallback? _doubleTapAction(BuildContext context) {
    final isDesktop = !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    if (isDesktop) {
      if (InteractionPrefs.doubleTapDesktop == 'reply') return onReply;
      return onReact == null
          ? null
          : () => _showReactionPicker(context, Theme.of(context));
    }
    // Mobile: double-tap opens react picker (swipe handles reply)
    return onReact == null
        ? null
        : () => _showReactionPicker(context, Theme.of(context));
  }

  /// Shows a context menu with both React and Reply options.
  void _showContextMenu(BuildContext context, ThemeData theme) {
    final isDesktop = !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    // On mobile, longPress directly opens react picker unless longPressShowsMenu is on.
    if (!isDesktop && !InteractionPrefs.longPressShowsMenu) {
      _showReactionPicker(context, theme);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F1F24),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Emoji row
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
              child: Wrap(
                spacing: 8,
                children: quickEmojis.map((e) => GestureDetector(
                  onTap: () { Navigator.pop(context); onReact?.call(e); },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 24)),
                  ),
                )).toList(),
              ),
            ),
            const Divider(color: Color(0xFF2C2C30)),
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply_rounded, color: Color(0xFF8E8E93)),
                title: const Text('Reply',
                    style: TextStyle(color: Color(0xFFF5F5F5))),
                onTap: () { Navigator.pop(context); onReply?.call(); },
              ),
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined,
                  color: Color(0xFF8E8E93)),
              title: const Text('React',
                  style: TextStyle(color: Color(0xFFF5F5F5))),
              onTap: () {
                Navigator.pop(context);
                _showReactionPicker(context, theme);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showReactionPicker(BuildContext context, ThemeData theme) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            children: quickEmojis.map((e) => GestureDetector(
              onTap: () { Navigator.pop(context); onReact?.call(e); },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(e, style: const TextStyle(fontSize: 24)),
              ),
            )).toList(),
          ),
        ),
      ),
    );
  }

  Widget? _buildReactionsRow(ThemeData theme, ColorScheme cs) {
    if (message.reactions.isEmpty) return null;
    return Wrap(
      spacing: 4,
      children: message.reactions.entries.map((e) {
        final count = e.value.length;
        final mine  = e.value.contains(myUUID);
        return GestureDetector(
          onTap: () => onReact?.call(e.key),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF2C2C30),
                width: 1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              '${e.key} $count',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFF5F5F5),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Wraps child with a small avatar on the left for peer messages.
  /// Own messages have no avatar (aligned right with their own margins).
  Widget _withAvatar({
    required BuildContext context,
    required bool isMe,
    required Widget child,
  }) {
    if (isMe) return child;

    final avatarBytes = _senderAvatarBytes();
    final initial     = _senderInitial();

    final avatar = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1F1F24),
        border: Border.all(color: const Color(0xFF2C2C30)),
      ),
      child: ClipOval(
        child: avatarBytes != null
            ? Image.memory(avatarBytes, fit: BoxFit.cover)
            : Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFF5F5F5)),
                ),
              ),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [avatar, const SizedBox(width: 10), Expanded(child: child)],
    );
  }

  Uint8List? _senderAvatarBytes() {
    // Prefer avatar embedded in the message itself
    if (message.senderAvatarBytes != null) return message.senderAvatarBytes;
    // Fall back to peer avatar map
    return peerAvatars[message.senderUUID];
  }

  String _senderInitial() {
    final label = _buildSenderLabel();
    return label.isNotEmpty ? label[0].toUpperCase() : '?';
  }

  /// Read receipts indicator widget (content only, no layout wrapper).
  Widget _readReceiptsContent(ThemeData theme, ColorScheme cs) {
    final readers = readReceipts[message.id] ?? message.readBy;
    final isMedia = message.type == MessageType.video ||
        message.type == MessageType.voice;

    if (message.isSending) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 12, height: 12,
          child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: const Color(0xFF8E8E93).withAlpha(120)),
        ),
        const SizedBox(width: 4),
        const Text('Sending…',
            style: TextStyle(fontSize: 10, color: Color(0xFF8E8E93))),
      ]);
    }

    if (readers.isEmpty) {
      return const Icon(Icons.done, size: 14, color: Color(0xFF636366));
    }

    final readByAll = peerCount > 0 && readers.length >= peerCount;
    final avatarCount = readers.length.clamp(0, 5);
    final avatarCircles = SizedBox(
      width:  avatarCount * 10.0 + 4,
      height: 14,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < avatarCount; i++)
            Positioned(
              left: i * 10.0,
              child: Container(
                width: 14, height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1F1F24),
                  border: Border.all(color: const Color(0xFF0A0A0C), width: 1),
                ),
                child: Center(
                  child: Text(
                    _peerInitialForUUID(readers.elementAt(i)),
                    style: const TextStyle(
                        fontSize: 7,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF5F5F5)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(
        readByAll
            ? (isMedia ? Icons.visibility : Icons.done_all)
            : Icons.done,
        size: 14,
        color: readByAll
            ? const Color(0xFF0A84FF)
            : const Color(0xFF8E8E93).withAlpha(180),
      ),
      const SizedBox(width: 4),
      avatarCircles,
    ]);
  }

  /// Meta row shown below every bubble: timestamp + read receipts (own) or
  /// timestamp (other). Mirrors the `.msg-meta` element in the HTML design.
  Widget _buildMetaRow(ThemeData theme, ColorScheme cs, String timeStr, bool isMe) {
    final timeText = Text(
      '${message.isFromHistory ? '~ ' : ''}$timeStr',
      style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
    );

    if (!isMe) {
      // Left-aligned, indented to sit after the 32px avatar + 4px gap + 6px
      return Padding(
        padding: const EdgeInsets.only(left: 42, top: 1, bottom: 2),
        child: timeText,
      );
    }

    // Own message: time + receipt icon, right-aligned
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 1, bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          timeText,
          const SizedBox(width: 6),
          _readReceiptsContent(theme, cs),
        ],
      ),
    );
  }

  String _peerInitialForUUID(String uuid) {
    final nick = peerNicknames[uuid];
    if (nick != null && nick.isNotEmpty) return nick[0].toUpperCase();
    return uuid.isNotEmpty ? uuid[0].toUpperCase() : '?';
  }

  String _buildSenderLabel() {
    if (message.isFromMe) return 'Me';
    // Try nickname by session UUID
    final nick = peerNicknames[message.senderUUID];
    if (nick != null) return nick;
    // Try nickname by public key hex (works even after peer leaves)
    if (message.senderPublicKeyHex != null) {
      final nickByPub = peerNicknames.entries
          .where((e) => e.key == message.senderPublicKeyHex)
          .map((e) => e.value)
          .firstOrNull;
      if (nickByPub != null) return nickByPub;
    }
    // Fall back to short session UUID
    final short = message.senderUUID.length >= 8
        ? message.senderUUID.substring(0, 8)
        : message.senderUUID;
    // If we have a public key, use a shorter fingerprint
    if (message.senderPublicKeyHex != null && message.senderPublicKeyHex!.length >= 8) {
      return '~${message.senderPublicKeyHex!.substring(0, 8)}';
    }
    return short;
  }

  Widget _buildContent(BuildContext context, ThemeData theme, Color textColor,
      String senderLabel, String timeStr, bool isMe) {
    switch (message.type) {
      case MessageType.system:
        return _buildSystemContent(context, theme);
      case MessageType.image:
        return _buildImageContent(context, theme, textColor, senderLabel,
            timeStr, isMe,
            animated: false);
      case MessageType.gif:
        return _buildImageContent(context, theme, textColor, senderLabel,
            timeStr, isMe,
            animated: true);
      case MessageType.video:
        return _buildVideoContent(
            context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.videoNote:
        return _buildVideoNoteContent(context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.voice:
        return _buildVoiceContent(
            context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.text:
        return _buildTextContent(
            theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.messageRead:
      case MessageType.reaction:
      case MessageType.viewed:
        return const SizedBox.shrink();
    }
  }

  // ── System ────────────────────────────────────────────────────────────────

  Widget _buildSystemContent(BuildContext context, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF141417),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2C2C30)),
          ),
          child: Text(
            message.content,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8E8E93),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  // ── Text ──────────────────────────────────────────────────────────────────

  Widget _buildTextContent(ThemeData theme, Color textColor, String senderLabel,
      String timeStr, bool isMe) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // SelectableText allows cursor-select + copy.
          // contextMenuBuilder keeps the dark theme consistent.
          SelectableText(
            message.content,
            style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
            contextMenuBuilder: (ctx, editableTextState) {
              return AdaptiveTextSelectionToolbar.editableText(
                editableTextState: editableTextState,
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Image / GIF ───────────────────────────────────────────────────────────

  Widget _buildImageContent(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe, {
    required bool animated,
  }) {
    return GestureDetector(
      onDoubleTap: _doubleTapAction(context),
      onLongPress: onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTap: onReact == null ? null : () => _showContextMenu(context, theme),
      behavior: HitTestBehavior.translucent,
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tap = fullscreen, double-tap = reply (handled by outer detector)
            GestureDetector(
              onTap: () => _showFullImage(context),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: Image.memory(
                  message.imageBytes!,
                  fit: BoxFit.contain,
                  gaplessPlayback: animated,
                  errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.broken_image_outlined, size: 48),
                  ),
                ),
              ),
            ),
            if (animated)
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(Icons.gif_box_outlined,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showFullImage(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.memory(message.imageBytes!, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Video Note (круглое видео) ─────────────────────────────────────────────

  Widget _buildVideoNoteContent(BuildContext context, ThemeData theme,
      Color textColor, String senderLabel, String timeStr, bool isMe) {
    return GestureDetector(
      onDoubleTap: _doubleTapAction(context),
      onLongPress: onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTap: onReact == null ? null : () => _showContextMenu(context, theme),
      behavior: HitTestBehavior.translucent,
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              border: Border.fromBorderSide(
                BorderSide(color: Color(0xFF0A84FF), width: 3),
              ),
            ),
            child: ClipOval(
              child: _VideoNotePlayer(videoBytes: message.videoBytes!),
            ),
          ),
        ],
      ),
    );
  }

  // ── Video ─────────────────────────────────────────────────────────────────

  Widget _buildVideoContent(BuildContext context, ThemeData theme,
      Color textColor, String senderLabel, String timeStr, bool isMe) {
    return GestureDetector(
      onDoubleTap: _doubleTapAction(context),
      onLongPress: onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTap: onReact == null ? null : () => _showContextMenu(context, theme),
      // translucent so video play-button tap still works
      behavior: HitTestBehavior.translucent,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _VideoThumbnail(
              videoBytes: message.videoBytes!,
              mediaName: message.mediaName ?? 'video',
            ),
          ],
        ),
      ),
    );
  }

  // ── Voice ─────────────────────────────────────────────────────────────────

  Widget _buildVoiceContent(BuildContext context, ThemeData theme,
      Color textColor, String senderLabel, String timeStr, bool isMe) {
    return GestureDetector(
      onDoubleTap: _doubleTapAction(context),
      onLongPress: onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTap: onReact == null ? null : () => _showContextMenu(context, theme),
      behavior: HitTestBehavior.translucent,
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _VoicePlayer(
            audioBytes: message.audioBytes!,
            mediaMime: message.mediaMime ?? 'audio/m4a',
            isMe: isMe,
          ),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _senderLabel(ThemeData theme, String label) => Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Color(0xFF8E8E93),
        ),
      );

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ─── Circular video note player ───────────────────────────────────────────────

class _VideoNotePlayer extends StatefulWidget {
  final Uint8List videoBytes;
  const _VideoNotePlayer({required this.videoBytes});

  @override
  State<_VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<_VideoNotePlayer> {
  Player?          _player;
  VideoController? _controller;
  bool _loading     = false;
  bool _initialized = false;
  bool _playing     = false;
  String? _tmpPath;

  @override
  void dispose() {
    _player?.dispose();
    if (_tmpPath != null) File(_tmpPath!).delete().catchError((_) {});
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_loading) return;
    if (_initialized) {
      await _player?.playOrPause();
      return;
    }
    setState(() => _loading = true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/vnote_${widget.videoBytes.hashCode}.mp4');
      if (!file.existsSync()) await file.writeAsBytes(widget.videoBytes);
      _tmpPath = file.path;

      final player     = Player();
      final controller = VideoController(player);
      await player.open(Media('file://${file.path}'), play: true);

      // listen to playback state
      player.stream.playing.listen((p) {
        if (mounted) setState(() => _playing = p);
      });

      if (mounted) {
        setState(() {
          _player      = player;
          _controller  = controller;
          _initialized = true;
          _loading     = false;
          _playing     = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Video error: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Placeholder — always show gradient so circle isn't transparent
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1F1F24), Color(0xFF2C2C30)],
              ),
            ),
          ),

          // Video (when loaded) — cover-fill the circle
          if (_initialized && _controller != null)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: 200,
                height: 200,
                child: Video(
                  controller: _controller!,
                  controls: NoVideoControls,
                ),
              ),
            ),

          // Play / loading overlay
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              color: Colors.transparent,
              alignment: Alignment.center,
              child: AnimatedOpacity(
                opacity: (_playing && _initialized) ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(140),
                    shape: BoxShape.circle,
                  ),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 30),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Video thumbnail + inline player (media_kit) ──────────────────────────────

class _VideoThumbnail extends StatefulWidget {
  final Uint8List videoBytes;
  final String mediaName;

  const _VideoThumbnail({required this.videoBytes, required this.mediaName});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  Player? _player;
  VideoController? _controller;
  bool _loading     = false;
  bool _initialized = false;
  String? _tmpPath;

  @override
  void dispose() {
    _player?.dispose();
    if (_tmpPath != null) File(_tmpPath!).delete().catchError((_) {});
    super.dispose();
  }

  Future<void> _init() async {
    if (_initialized || _loading) return;
    setState(() => _loading = true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final ext    = widget.mediaName.split('.').last;
      final file   = File('${tmpDir.path}/${widget.mediaName.hashCode}.$ext');
      if (!file.existsSync()) {
        await file.writeAsBytes(widget.videoBytes);
      }
      _tmpPath = file.path;

      final player     = Player();
      final controller = VideoController(player);
      await player.open(Media('file://${file.path}'), play: false);

      if (mounted) {
        setState(() {
          _player      = player;
          _controller  = controller;
          _initialized = true;
          _loading     = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Video load error: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        ));
      }
    }
  }

  Future<void> _togglePlay() async {
    if (!_initialized) {
      await _init();
      await _player?.play();
      return;
    }
    await _player?.playOrPause();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_initialized && _controller != null)
                    Video(controller: _controller!)
                  else
                    Container(color: const Color(0xFF1F1F24)),
                  GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      color: Colors.transparent,
                      child: _loading
                          ? Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withAlpha(140),
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(12),
                              child: const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              ),
                            )
                          : (!_initialized
                              ? Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withAlpha(140),
                                    shape: BoxShape.circle,
                                  ),
                                  padding: const EdgeInsets.all(12),
                                  child: const Icon(Icons.play_arrow_rounded,
                                      size: 28, color: Colors.white),
                                )
                              : const SizedBox.shrink()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_initialized && _player != null) ...[
            const SizedBox(height: 4),
            StreamBuilder<Duration>(
              stream: _player!.stream.position,
              builder: (context, posSnap) {
                final pos = posSnap.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: _player!.stream.duration,
                  builder: (context, durSnap) {
                    final dur = durSnap.data ?? Duration.zero;
                    final progress = dur.inMilliseconds == 0
                        ? 0.0
                        : (pos.inMilliseconds / dur.inMilliseconds)
                            .clamp(0.0, 1.0);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape:
                                const RoundSliderThumbShape(enabledThumbRadius: 5),
                            overlayShape:
                                const RoundSliderOverlayShape(overlayRadius: 10),
                          ),
                          child: Slider(
                            value: progress,
                            onChanged: dur.inMilliseconds > 0
                                ? (v) {
                                    final seek = Duration(
                                        milliseconds:
                                            (v * dur.inMilliseconds).round());
                                    _player!.seek(seek);
                                  }
                                : null,
                            activeColor: cs.primary,
                            inactiveColor: cs.outline.withAlpha(80),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_fmt(pos),
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: cs.onSurfaceVariant)),
                              Text(_fmt(dur),
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                widget.mediaName,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ─── Voice player ─────────────────────────────────────────────────────────────

class _VoicePlayer extends StatefulWidget {
  final Uint8List audioBytes;
  final String mediaMime;
  final bool isMe;

  const _VoicePlayer({
    required this.audioBytes,
    required this.mediaMime,
    this.isMe = false,
  });

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final _player   = AudioPlayer();
  bool _playing   = false;
  bool _loading   = false;
  bool _metaReady = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _tmpPath;
  late final List<double> _waveform;

  static const _barCount   = 10;
  static const _waveWidth  = 120.0;
  static const _waveHeight = 20.0;

  @override
  void initState() {
    super.initState();
    _waveform = _generateWaveform(widget.audioBytes, _barCount);
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s.name == 'playing');
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() { _duration = d; _metaReady = true; });
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    });
    _prefetchDuration();
  }

  @override
  void dispose() {
    _player.dispose();
    if (_tmpPath != null) File(_tmpPath!).delete().catchError((_) {});
    super.dispose();
  }

  List<double> _generateWaveform(Uint8List bytes, int count) {
    if (bytes.isEmpty) return List.filled(count, 0.3);
    final step = bytes.length / count;
    // Compute raw average deviation per bar
    final raw = List.generate(count, (i) {
      final start = (i * step).round();
      final end   = ((i + 1) * step).round().clamp(0, bytes.length);
      if (start >= bytes.length) return 0.0;
      double sum = 0;
      for (int j = start; j < end; j++) {
        sum += (bytes[j] ^ 0x80).toDouble();
      }
      return sum / (end - start);
    });
    // Normalize to [0.08, 1.0] using actual min/max for full dynamic range
    final minVal = raw.reduce((a, b) => a < b ? a : b);
    final maxVal = raw.reduce((a, b) => a > b ? a : b);
    final range  = maxVal - minVal;
    if (range < 1.0) return List.filled(count, 0.4);
    return raw.map((v) => (v - minVal) / range * 0.92 + 0.08).toList();
  }

  Future<void> _prefetchDuration() async {
    try {
      await _prepareTmp();
      await _player.setSourceDeviceFile(_tmpPath!);
    } catch (_) {}
  }

  Future<void> _prepareTmp() async {
    if (_tmpPath != null) return;
    final tmpDir = await getTemporaryDirectory();
    final ext    = _mimeToExt(widget.mediaMime);
    final file   = File('${tmpDir.path}/voice_play_${widget.audioBytes.hashCode}.$ext');
    if (!file.existsSync()) await file.writeAsBytes(widget.audioBytes);
    _tmpPath = file.path;
  }

  String _mimeToExt(String mime) => switch (mime) {
    'audio/m4a'  => 'm4a',
    'audio/aac'  => 'aac',
    'audio/opus' => 'opus',
    'audio/mpeg' => 'mp3',
    _            => 'audio',
  };

  Future<void> _togglePlay() async {
    if (_loading) return;
    if (_playing) { await _player.pause(); return; }
    setState(() => _loading = true);
    try {
      await _prepareTmp();
      await _player.play(DeviceFileSource(_tmpPath!));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Playback error: $e'),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _seekFromTap(double tapX) {
    if (_duration.inMilliseconds == 0) return;
    final ratio = (tapX / _waveWidth).clamp(0.0, 1.0);
    _player.seek(Duration(milliseconds: (ratio * _duration.inMilliseconds).round()));
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final cs       = theme.colorScheme;
    final progress = _duration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    final posLabel = _fmt(_position);
    final durLabel = _metaReady ? _fmt(_duration) : '--:--';

    // HTML: own bubble → white play button + blue icon; other → dark blue button + white icon
    final btnBg    = widget.isMe ? Colors.white : const Color(0xFF0056B3);
    final btnFg    = widget.isMe ? const Color(0xFF0A84FF) : Colors.white;
    final activeWave   = widget.isMe ? Colors.white : const Color(0xFF0A84FF);
    final inactiveWave = widget.isMe
        ? Colors.white.withAlpha(100)
        : const Color(0xFF8E8E93);
    final timeColor = widget.isMe
        ? Colors.white.withAlpha(180)
        : const Color(0xFF8E8E93);

    // Design: [▶] [waveform] [time] — all on one row
    final displayTime = _playing ? posLabel : durLabel;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: _togglePlay,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: btnBg, shape: BoxShape.circle),
            child: _loading
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: btnFg),
                  )
                : Icon(_playing ? Icons.pause : Icons.play_arrow,
                    color: btnFg, size: 20),
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTapDown: (d) => _seekFromTap(d.localPosition.dx),
          child: SizedBox(
            width: _waveWidth,
            height: _waveHeight,
            child: CustomPaint(
              painter: _WaveformPainter(
                bars: _waveform,
                progress: progress,
                activeColor: activeWave,
                inactiveColor: inactiveWave,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          displayTime,
          style: TextStyle(fontSize: 12, color: timeColor),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ─── Waveform painter ─────────────────────────────────────────────────────────

class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  const _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const gap      = 2.0;
    final barW     = (size.width - gap * (bars.length - 1)) / bars.length;
    final progressX = size.width * progress;

    for (int i = 0; i < bars.length; i++) {
      final x    = i * (barW + gap);
      final barH = (bars[i] * size.height).clamp(2.0, size.height);
      final top  = (size.height - barH) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barW, barH),
        const Radius.circular(2),
      );
      final isActive = (x + barW / 2) < progressX;
      canvas.drawRRect(rect, Paint()..color = isActive ? activeColor : inactiveColor);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.bars != bars || old.activeColor != activeColor;
}