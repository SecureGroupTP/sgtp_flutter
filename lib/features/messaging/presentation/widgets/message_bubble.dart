import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/interaction_prefs.dart';
import 'package:sgtp_flutter/features/contacts/presentation/widgets/user_avatar.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';

enum _MessageContextAction { copyMessage, react, reply }

Size _fitSizeForAspectRatio({
  required double aspectRatio,
  required double maxWidth,
  required double maxHeight,
}) {
  final safeAspectRatio =
      aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
  final fitted = applyBoxFit(
    BoxFit.contain,
    Size(safeAspectRatio, 1),
    Size(maxWidth, maxHeight),
  ).destination;
  return Size(
    math.max(1, fitted.width),
    math.max(1, fitted.height),
  );
}

Future<void> _waitForVideoMetadata(Player player) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < const Duration(seconds: 3)) {
    final hasSize =
        (player.state.videoParams.dw ?? player.state.width ?? 0) > 0 &&
            (player.state.videoParams.dh ?? player.state.height ?? 0) > 0;
    final hasDuration = player.state.duration > Duration.zero;
    if (hasSize || hasDuration) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final Map<String, String> peerNicknames;
  final String myUUID;
  final Map<String, Uint8List> peerAvatars;
  final Uint8List? userAvatarBytes;
  final Map<String, Set<String>> readReceipts;

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
    this.onReply,
    this.onReact,
    this.quickEmojis = const [
      '👍',
      '❤️',
      '😂',
      '😮',
      '😢',
      '🔥',
      '👏',
      '🎉',
      '🤔',
      '💯'
    ],
  });

  bool _isMediaMessage(ChatMessage message) {
    return message.type == MessageType.image ||
        message.type == MessageType.gif ||
        message.type == MessageType.video ||
        message.type == MessageType.videoNote ||
        message.type == MessageType.voice;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isMe = message.isFromMe;
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
      const ownBubbleBg = Color(0xFF0A84FF);
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
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                border:
                    isMe ? null : Border.all(color: const Color(0xFF2C2C30)),
              ),
              child: _buildVoiceContent(context, theme, cs.onSurfaceVariant,
                  senderLabel, timeStr, isMe),
            ),
          ),
        ),
      );
      final reactionsRow = _buildReactionsRow(theme, cs);
      return Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
              left: 8,
              right: 8,
              top: 4,
              bottom: 4,
            ),
            child: _buildVideoNoteContent(
                context, theme, Colors.white, senderLabel, timeStr, isMe),
          ),
        ),
      );
      final reactionsRow = _buildReactionsRow(theme, cs);
      return Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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

    if (message.type == MessageType.video) {
      final videoWidget = _withAvatar(
        context: context,
        isMe: isMe,
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(
              left: 8,
              right: 8,
              top: 4,
              bottom: 4,
            ),
            child: _buildVideoContent(
              context,
              theme,
              Colors.white,
              senderLabel,
              timeStr,
              isMe,
            ),
          ),
        ),
      );
      final reactionsRow = _buildReactionsRow(theme, cs);
      return Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(left: 42, bottom: 2),
              child: _senderLabel(theme, senderLabel),
            ),
          videoWidget,
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
    const ownBubbleBg = Color(0xFF0A84FF);
    const otherBubbleBg = Color(0xFF1F1F24);
    const ownTextColor = Colors.white;
    const otherTextColor = Color(0xFFF5F5F5);
    final bgColor = isMe ? ownBubbleBg : otherBubbleBg;
    final textColor = isMe ? ownTextColor : otherTextColor;

    // Reply strip rendered INSIDE the bubble (matches design: quote block
    // sits on top of the coloured bubble background).
    Widget? replyStrip;
    if (message.replyToId != null) {
      replyStrip = Container(
        margin: const EdgeInsets.only(left: 8, right: 8, top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isMe ? Colors.white.withAlpha(38) : Colors.black.withAlpha(51),
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
        border: isMe ? null : Border.all(color: const Color(0xFF2C2C30)),
      ),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (replyStrip != null) replyStrip,
            _buildContent(
                context, theme, textColor, senderLabel, timeStr, isMe),
          ],
        ),
      ),
    );

    Widget bubbleWithReply;
    {
      bubbleWithReply = ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: innerBubble,
      );
    }

    final alignedBubble = Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onDoubleTap: _doubleTapAction(context),
        onLongPress: onReact == null
            ? null
            : () => _showContextMenu(context, Theme.of(context)),
        onSecondaryTapDown: onReact == null
            ? null
            : (details) => _showContextMenu(
                  context,
                  Theme.of(context),
                  globalPosition: details.globalPosition,
                ),
        behavior: HitTestBehavior.translucent,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            bubbleWithReply,
            // Sending progress overlay on innerBubble only
            if (message.isSending && _isMediaMessage(message))
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
                        value: message.sendProgress > 0
                            ? message.sendProgress
                            : null,
                        minHeight: 3,
                        backgroundColor:
                            Theme.of(context).colorScheme.primary.withAlpha(40),
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
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
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

  /// Shows message actions.
  void _showContextMenu(
    BuildContext context,
    ThemeData theme, {
    Offset? globalPosition,
  }) {
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    if (isDesktop) {
      unawaited(
        _showDesktopContextMenu(
          context,
          theme,
          globalPosition: globalPosition,
        ),
      );
      return;
    }
    // On mobile, longPress directly opens react picker unless longPressShowsMenu is on.
    if (!InteractionPrefs.longPressShowsMenu) {
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
                children: quickEmojis
                    .map((e) => GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            onReact?.call(e);
                          },
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child:
                                Text(e, style: const TextStyle(fontSize: 24)),
                          ),
                        ))
                    .toList(),
              ),
            ),
            const Divider(color: Color(0xFF2C2C30)),
            if (onReply != null)
              ListTile(
                leading:
                    const Icon(Icons.reply_rounded, color: Color(0xFF8E8E93)),
                title: const Text('Reply',
                    style: TextStyle(color: Color(0xFFF5F5F5))),
                onTap: () {
                  Navigator.pop(context);
                  onReply?.call();
                },
              ),
            if (message.type == MessageType.text &&
                message.content.trim().isNotEmpty)
              ListTile(
                leading:
                    const Icon(Icons.copy_rounded, color: Color(0xFF8E8E93)),
                title: const Text('Copy Message',
                    style: TextStyle(color: Color(0xFFF5F5F5))),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: message.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Message copied')),
                  );
                },
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

  Future<void> _showDesktopContextMenu(
    BuildContext context,
    ThemeData theme, {
    Offset? globalPosition,
  }) async {
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final overlaySize = overlayBox?.size ?? MediaQuery.of(context).size;
    final clickPos =
        globalPosition ?? Offset(overlaySize.width / 2, overlaySize.height / 2);
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(clickPos.dx, clickPos.dy, 0, 0),
      Offset.zero & overlaySize,
    );
    final canCopyMessage =
        message.type == MessageType.text && message.content.trim().isNotEmpty;

    final action = await showMenu<_MessageContextAction>(
      context: context,
      position: position,
      color: const Color(0xFF1F1F24),
      items: [
        if (canCopyMessage)
          const PopupMenuItem<_MessageContextAction>(
            value: _MessageContextAction.copyMessage,
            child: _DesktopMenuItem(
              icon: Icons.copy_rounded,
              label: 'Copy Message',
            ),
          ),
        const PopupMenuItem<_MessageContextAction>(
          value: _MessageContextAction.react,
          child: _DesktopMenuItem(
            icon: Icons.emoji_emotions_outlined,
            label: 'React',
          ),
        ),
        if (onReply != null)
          const PopupMenuItem<_MessageContextAction>(
            value: _MessageContextAction.reply,
            child: _DesktopMenuItem(
              icon: Icons.reply_rounded,
              label: 'Reply',
            ),
          ),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _MessageContextAction.copyMessage:
        await Clipboard.setData(ClipboardData(text: message.content));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message copied')),
        );
        return;
      case _MessageContextAction.react:
        _showReactionPicker(context, theme);
        return;
      case _MessageContextAction.reply:
        onReply?.call();
        return;
    }
  }

  void _showReactionPicker(BuildContext context, ThemeData theme) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            children: quickEmojis
                .map((e) => GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        onReact?.call(e);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 24)),
                      ),
                    ))
                .toList(),
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

    final avatar = UserAvatar(
      name: _buildSenderLabel(),
      bytes: avatarBytes,
      size: 32,
      border: Border.all(color: const Color(0xFF2C2C30)),
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

  /// Read receipts indicator widget (content only, no layout wrapper).
  Widget _readReceiptsContent(ThemeData theme, ColorScheme cs) {
    final readers = readReceipts[message.id] ?? message.readBy;
    final isMedia = message.type == MessageType.image ||
        message.type == MessageType.gif ||
        message.type == MessageType.video ||
        message.type == MessageType.videoNote ||
        message.type == MessageType.voice;

    if (message.sendError.trim().isNotEmpty) {
      return Tooltip(
        message: message.sendError.trim(),
        child: const Icon(
          Icons.error_outline_rounded,
          size: 14,
          color: Color(0xFFFF3B30),
        ),
      );
    }

    if (message.isSending) {
      final percent =
          (message.sendProgress.clamp(0.0, 1.0) * 100).round().clamp(0, 100);
      return Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: const Color(0xFF8E8E93).withAlpha(120)),
        ),
        if (isMedia) ...[
          const SizedBox(width: 4),
          Text(
            '$percent%',
            style: const TextStyle(fontSize: 10, color: Color(0xFF8E8E93)),
          ),
        ],
      ]);
    }

    if (readers.isEmpty) {
      return const Icon(Icons.done, size: 14, color: Color(0xFF636366));
    }

    final avatarCount = readers.length.clamp(0, 5);
    final avatarCircles = SizedBox(
      width: avatarCount * 10.0 + 4,
      height: 14,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < avatarCount; i++)
            Positioned(
              left: i * 10.0,
              child: Container(
                width: 14,
                height: 14,
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
        Icons.double_arrow_rounded,
        size: 14,
        color: const Color(0xFF0A84FF),
      ),
      const SizedBox(width: 4),
      avatarCircles,
    ]);
  }

  /// Meta row shown below every bubble: timestamp + read receipts (own) or
  /// timestamp (other). Mirrors the `.msg-meta` element in the HTML design.
  Widget _buildMetaRow(
      ThemeData theme, ColorScheme cs, String timeStr, bool isMe) {
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
    if (message.senderPublicKeyHex != null &&
        message.senderPublicKeyHex!.length >= 8) {
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
        return _buildImageContent(
            context, theme, textColor, senderLabel, timeStr, isMe,
            animated: false);
      case MessageType.gif:
        return _buildImageContent(
            context, theme, textColor, senderLabel, timeStr, isMe,
            animated: true);
      case MessageType.video:
        return _buildVideoContent(
            context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.videoNote:
        return _buildVideoNoteContent(
            context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.voice:
        return _buildVoiceContent(
            context, theme, textColor, senderLabel, timeStr, isMe);
      case MessageType.text:
        return _buildTextContent(theme, textColor, senderLabel, timeStr, isMe);
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
      onLongPress:
          onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTapDown: onReact == null
          ? null
          : (details) => _showContextMenu(
                context,
                theme,
                globalPosition: details.globalPosition,
              ),
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
      onLongPress:
          onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTapDown: onReact == null
          ? null
          : (details) => _showContextMenu(
                context,
                theme,
                globalPosition: details.globalPosition,
              ),
      behavior: HitTestBehavior.translucent,
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
              child: _VideoNotePlayer(
                videoBytes: message.videoBytes,
                localPath: message.localMediaPath,
                mediaMime: message.mediaMime,
                metadata: message.videoNoteMetadata,
              ),
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
      onLongPress:
          onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTapDown: onReact == null
          ? null
          : (details) => _showContextMenu(
                context,
                theme,
                globalPosition: details.globalPosition,
              ),
      // translucent so video play-button tap still works
      behavior: HitTestBehavior.translucent,
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _VideoThumbnail(
            videoBytes: message.videoBytes,
            localPath: message.localMediaPath,
            mediaName: message.mediaName ?? 'video',
            isMe: isMe,
          ),
        ],
      ),
    );
  }

  // ── Voice ─────────────────────────────────────────────────────────────────

  Widget _buildVoiceContent(BuildContext context, ThemeData theme,
      Color textColor, String senderLabel, String timeStr, bool isMe) {
    return GestureDetector(
      onDoubleTap: _doubleTapAction(context),
      onLongPress:
          onReact == null ? null : () => _showContextMenu(context, theme),
      onSecondaryTapDown: onReact == null
          ? null
          : (details) => _showContextMenu(
                context,
                theme,
                globalPosition: details.globalPosition,
              ),
      behavior: HitTestBehavior.translucent,
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _VoicePlayer(
            audioBytes: message.audioBytes,
            localPath: message.localMediaPath,
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
  final Uint8List? videoBytes;
  final String? localPath;
  final String? mediaMime;
  final VideoNoteMetadata? metadata;
  const _VideoNotePlayer({
    this.videoBytes,
    this.localPath,
    this.mediaMime,
    this.metadata,
  });

  @override
  State<_VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<_VideoNotePlayer> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _playingSub;
  bool _loading = false;
  bool _initialized = false;
  bool _failed = false;
  bool _playing = false;
  bool _hasVideoTrack = true;
  Duration _duration = Duration.zero;
  String? _tmpPath;
  bool _ownsTempFile = false;

  Future<void> _ensureAudible(Player? player) async {
    final p = player;
    if (p == null) return;
    await p.setVolume(100);
  }

  bool _hasRenderableVideoTrack(Player player) {
    final params = player.state.videoParams;
    final width = params.dw ?? player.state.width ?? 0;
    final height = params.dh ?? player.state.height ?? 0;
    return width > 0 && height > 0;
  }

  @override
  void initState() {
    super.initState();
    // Load first frame for preview (like regular video thumbnails).
    _preparePreview();
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _player?.dispose();
    if (_ownsTempFile && _tmpPath != null) {
      try {
        File(_tmpPath!).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  String _tempExtForMime(String? mime) => switch (mime) {
        'video/mp4' => 'mp4',
        'video/quicktime' => 'mov',
        'video/webm' => 'webm',
        'video/x-msvideo' => 'avi',
        'video/x-matroska' => 'mkv',
        'video/x-m4v' => 'm4v',
        'video/3gpp' => '3gp',
        'audio/m4a' => 'm4a',
        'audio/mp4' => 'm4a',
        'audio/x-m4a' => 'm4a',
        'audio/aac' => 'aac',
        'audio/mp4a-latm' => 'aac',
        'audio/opus' => 'opus',
        'audio/mpeg' => 'mp3',
        _ => 'bin',
      };

  Future<void> _preparePreview({bool autoplay = false}) async {
    if (_initialized || _loading) return;
    setState(() => _loading = true);
    Player? player;
    VideoController? controller;
    StreamSubscription<bool>? playingSub;
    StreamSubscription<String>? errorSub;
    try {
      String path;
      if (widget.localPath != null && widget.localPath!.trim().isNotEmpty) {
        path = widget.localPath!;
        // Verify file exists on native — temp cache can be cleared by the OS.
        if (!kIsWeb && !await File(path).exists()) {
          throw Exception('Video file not found');
        }
        _ownsTempFile = false;
      } else {
        final bytes = widget.videoBytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Video data is unavailable');
        }
        if (kIsWeb) {
          path = XFile.fromData(
            bytes,
            mimeType: widget.mediaMime ?? 'video/mp4',
            name:
                'vnote_${bytes.hashCode}.${_tempExtForMime(widget.mediaMime)}',
          ).path;
          _ownsTempFile = false;
        } else {
          final tmpDir = await getTemporaryDirectory();
          final ext = _tempExtForMime(widget.mediaMime);
          final file = File('${tmpDir.path}/vnote_${bytes.hashCode}.$ext');
          if (!file.existsSync()) await file.writeAsBytes(bytes);
          path = file.path;
          _ownsTempFile = true;
        }
      }
      _tmpPath = path;

      player = Player();

      // VideoController must be created before player.open() so the native
      // texture surface is ready when the decoder starts producing frames.
      // We create it unconditionally here and discard it later if the media
      // turns out to be audio-only.
      controller = VideoController(player);

      // Track player errors so we can surface them instead of silently showing black.
      String? playerError;
      errorSub = player.stream.error.listen((e) => playerError = e);

      // Listen to playback state (also used for overlay visibility).
      playingSub = player.stream.playing.listen((p) {
        if (!mounted) return;
        setState(() => _playing = p);
      });

      final source = kIsWeb ? path : Uri.file(path).toString();
      await player.open(Media(source), play: false);
      await player.setVolume(100);
      await _waitForVideoMetadata(player);

      // Surface any player error (e.g. unsupported codec, file unreadable).
      if (playerError != null) throw Exception(playerError);

      final isDeclaredAudioOnly =
          (widget.mediaMime ?? '').toLowerCase().startsWith('audio/');
      var hasVideoTrack = _hasRenderableVideoTrack(player);

      // Some containers expose duration before video dimensions.
      // Probe a short decode step to materialize the first frame metadata.
      if (!kIsWeb && !hasVideoTrack && !isDeclaredAudioOnly) {
        try {
          await _ensureAudible(player);
          await player.play();
          await Future<void>.delayed(const Duration(milliseconds: 220));
          await player.pause();
          await _waitForVideoMetadata(player);
          hasVideoTrack = _hasRenderableVideoTrack(player);
        } catch (_) {}
      }

      // For declared video MIME, prefer rendering path even if metadata is late.
      if (!hasVideoTrack &&
          !isDeclaredAudioOnly &&
          (widget.mediaMime ?? '').toLowerCase().startsWith('video/')) {
        hasVideoTrack = true;
      }
      if (!hasVideoTrack) {
        // Audio-only: discard the pre-created controller.
        controller = null;
      }

      if (autoplay) {
        await _ensureAudible(player);
        await player.play();
      }

      if (hasVideoTrack && controller != null) {
        // Wait until the native renderer has produced at least one frame.
        // This is required on Windows/desktop — the Video widget shows the
        // `fill` color (black by default) until the native texture rect is set.
        try {
          await controller.waitUntilFirstFrameRendered
              .timeout(const Duration(seconds: 8));
        } catch (_) {
          // Timeout is tolerated: the Video widget will update once frames arrive.
        }
      } else if (!autoplay && !kIsWeb) {
        // Audio-only: give the player a moment to buffer.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      if (!autoplay) {
        if (!kIsWeb) {
          await player.pause();
          await player.seek(Duration.zero);
        }
      }

      if (!mounted) {
        await errorSub.cancel();
        await player.dispose();
        await playingSub.cancel();
        return;
      }

      // Error stream is no longer needed after successful init.
      try {
        await errorSub.cancel();
      } catch (_) {}

      final prevSub = _playingSub;
      _playingSub = playingSub;
      try {
        await prevSub?.cancel();
      } catch (_) {}

      final readyPlayer = player;
      final readyController = controller;
      setState(() {
        _player = readyPlayer;
        _controller = readyController;
        _initialized = true;
        _loading = false;
        _duration = readyPlayer.state.duration;
        _hasVideoTrack = hasVideoTrack;
      });
    } catch (e) {
      try {
        await playingSub?.cancel();
      } catch (_) {}
      try {
        await errorSub?.cancel();
      } catch (_) {}
      try {
        await player?.dispose();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _togglePlay() async {
    if (_loading || _failed) return;
    if (!_initialized) {
      await _preparePreview(autoplay: true);
      return;
    }
    await _ensureAudible(_player);
    if (_playing) {
      await _player?.pause();
    } else {
      await _player?.play();
    }
  }

  Widget _coverFillVideo({
    required VideoController controller,
  }) {
    return Positioned.fill(
      child: Video(
        controller: controller,
        controls: NoVideoControls,
        fit: BoxFit.cover,
        fill: const Color(0x00000000),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final thumbnailBytes = widget.metadata?.thumbnailBytes;
    final dominantColor = _parseHexColor(widget.metadata?.dominantColorHex) ??
        const Color(0xFF2C2C30);
    final duration = widget.metadata?.durationMs != null
        ? Duration(milliseconds: widget.metadata!.durationMs)
        : _duration;
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Placeholder — always show gradient so circle isn't transparent
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  dominantColor.withAlpha(220),
                  const Color(0xFF1F1F24),
                ],
              ),
            ),
          ),

          // Video (when loaded) — cover-fill the circle
          if (_initialized && _controller != null && _hasVideoTrack)
            _coverFillVideo(
              controller: _controller!,
            ),

          if (thumbnailBytes != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _playing ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Image.memory(
                    thumbnailBytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),

          // Audio-only "circle note" fallback (no video track).
          if (_initialized && !_hasVideoTrack)
            Center(
              child: Icon(
                Icons.graphic_eq_rounded,
                color: Colors.white.withAlpha(220),
                size: 56,
              ),
            ),

          // Playback progress ring (white stroke from 12:00)
          if (_initialized && player != null)
            Positioned.fill(
              child: IgnorePointer(
                child: StreamBuilder<Duration>(
                  stream: player.stream.position,
                  initialData: player.state.position,
                  builder: (context, posSnap) {
                    final position = posSnap.data ?? Duration.zero;
                    return StreamBuilder<Duration>(
                      stream: player.stream.duration,
                      initialData: _duration,
                      builder: (context, durSnap) {
                        final duration = durSnap.data ?? _duration;
                        final maxMs = duration.inMilliseconds;
                        final valueMs = position.inMilliseconds;
                        final progress =
                            maxMs > 0 ? (valueMs / maxMs).clamp(0.0, 1.0) : 0.0;
                        return CustomPaint(
                          painter: _VideoNoteProgressRingPainter(
                            progress: progress,
                            visible: maxMs > 0,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),

          // Error state — broken video icon instead of silent black circle.
          if (_failed)
            Center(
              child: Icon(
                Icons.broken_image_rounded,
                color: Colors.white.withAlpha(180),
                size: 48,
              ),
            ),

          // Play / loading overlay
          if (!_failed)
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

          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(120),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _formatDuration(duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Color? _parseHexColor(String? value) {
    if (value == null) return null;
    final hex = value.replaceFirst('#', '');
    if (hex.length != 6) return null;
    final parsed = int.tryParse('FF$hex', radix: 16);
    return parsed == null ? null : Color(parsed);
  }
}

class _DesktopMenuItem extends StatelessWidget {
  const _DesktopMenuItem({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF8E8E93)),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: Color(0xFFF5F5F5))),
      ],
    );
  }
}

class _VideoNoteProgressRingPainter extends CustomPainter {
  final double progress; // 0..1
  final bool visible;
  const _VideoNoteProgressRingPainter({
    required this.progress,
    required this.visible,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;

    final stroke = math.max(2.0, size.shortestSide * 0.02);
    final rect = Offset.zero & size;
    final ringRect = Rect.fromCircle(
      center: rect.center,
      radius: (size.shortestSide / 2) - (stroke / 2),
    );

    final paint = Paint()
      ..color = Colors.white.withAlpha(220)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final startAngle = -math.pi / 2; // 12:00
    final sweepAngle = (2 * math.pi) * progress;
    canvas.drawArc(ringRect, startAngle, sweepAngle, false, paint);
  }

  @override
  bool shouldRepaint(covariant _VideoNoteProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.visible != visible;
  }
}

// ─── Video thumbnail + inline player (media_kit) ──────────────────────────────

class _VideoThumbnail extends StatefulWidget {
  final Uint8List? videoBytes;
  final String? localPath;
  final String mediaName;
  final bool isMe;

  const _VideoThumbnail({
    this.videoBytes,
    this.localPath,
    required this.mediaName,
    required this.isMe,
  });

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  Player? _player;
  VideoController? _controller;
  bool _loading = false;
  Duration _duration = Duration.zero;
  double? _aspectRatio;
  bool _initialized = false;
  String? _tmpPath;
  bool _ownsTempFile = false;

  @override
  void dispose() {
    _player?.dispose();
    if (_ownsTempFile && _tmpPath != null) {
      try {
        File(_tmpPath!).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _preparePreview();
  }

  Future<void> _preparePreview() async {
    if (_initialized || _loading) return;
    setState(() => _loading = true);
    try {
      String path;
      if (widget.localPath != null && widget.localPath!.trim().isNotEmpty) {
        path = widget.localPath!;
        _ownsTempFile = false;
      } else {
        final bytes = widget.videoBytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Video data is unavailable');
        }
        if (kIsWeb) {
          path = XFile.fromData(
            bytes,
            mimeType: 'video/mp4',
            name: widget.mediaName,
          ).path;
          _ownsTempFile = false;
        } else {
          final tmpDir = await getTemporaryDirectory();
          final ext = widget.mediaName.split('.').last;
          final file = File('${tmpDir.path}/${widget.mediaName.hashCode}.$ext');
          if (!file.existsSync()) {
            await file.writeAsBytes(bytes);
          }
          path = file.path;
          _ownsTempFile = true;
        }
      }
      _tmpPath = path;

      final player = Player();
      final controller = VideoController(player);
      final source = kIsWeb ? path : Uri.file(path).toString();
      await player.open(Media(source), play: true);
      await player.setVolume(0);
      await _waitForVideoMetadata(player);
      final params = player.state.videoParams;
      final aspectRatio = params.aspect ??
          ((params.dw != null && params.dh != null && params.dh! > 0)
              ? params.dw! / params.dh!
              : null) ??
          ((player.state.width != null &&
                  player.state.height != null &&
                  player.state.height! > 0)
              ? player.state.width! / player.state.height!
              : 16 / 9);
      await player.pause();
      await player.seek(Duration.zero);

      if (mounted) {
        setState(() {
          _aspectRatio =
              aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
          _duration = player.state.duration;
          _player = player;
          _controller = controller;
          _initialized = true;
          _loading = false;
        });
      } else {
        await player.dispose();
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

  @override
  Widget build(BuildContext context) {
    final sourceAspectRatio = _aspectRatio ?? 16 / 9;
    final isPortraitVideo = sourceAspectRatio < 0.8;
    final previewFrameAspectRatio = isPortraitVideo ? 4 / 5 : sourceAspectRatio;
    final previewSize = _fitSizeForAspectRatio(
      aspectRatio: previewFrameAspectRatio,
      maxWidth: 300,
      maxHeight: 360,
    );

    return SizedBox(
      width: previewSize.width,
      height: previewSize.height,
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _VideoPlayerPage(
                videoBytes: widget.videoBytes,
                localPath: widget.localPath,
                mediaName: widget.mediaName,
              ),
            ),
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(widget.isMe ? 16 : 4),
            bottomRight: Radius.circular(widget.isMe ? 4 : 16),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_initialized && _controller != null)
                Stack(
                  fit: StackFit.expand,
                  children: [
                    Opacity(
                      opacity: 0.35,
                      child: Video(
                        controller: _controller!,
                        controls: NoVideoControls,
                        fit: BoxFit.cover,
                        aspectRatio: sourceAspectRatio,
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(70),
                      ),
                    ),
                    Center(
                      child: Video(
                        controller: _controller!,
                        controls: NoVideoControls,
                        fit: BoxFit.contain,
                        aspectRatio: sourceAspectRatio,
                      ),
                    ),
                  ],
                )
              else
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF1F1F24), Color(0xFF2C2C30)],
                    ),
                  ),
                ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withAlpha(26),
                        Colors.black.withAlpha(90),
                      ],
                    ),
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(150),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withAlpha(50),
                    ),
                  ),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                ),
              ),
              if (_duration > Duration.zero)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(150),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _fmt(_duration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _VideoPlayerPage extends StatefulWidget {
  final Uint8List? videoBytes;
  final String? localPath;
  final String mediaName;

  const _VideoPlayerPage({
    this.videoBytes,
    this.localPath,
    required this.mediaName,
  });

  @override
  State<_VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<_VideoPlayerPage> {
  Player? _player;
  VideoController? _controller;
  bool _loading = true;
  String? _tmpPath;
  double _aspectRatio = 16 / 9;
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _preferPortraitZoom = true;
  bool _ownsTempFile = false;

  Future<void> _ensureAudible(Player? player) async {
    final p = player;
    if (p == null) return;
    final volume = p.state.volume;
    if (volume <= 0) {
      await p.setVolume(100);
    }
  }

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _player?.dispose();
    if (_ownsTempFile && _tmpPath != null) {
      try {
        File(_tmpPath!).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _init() async {
    try {
      String path;
      if (widget.localPath != null && widget.localPath!.trim().isNotEmpty) {
        path = widget.localPath!;
        _ownsTempFile = false;
      } else {
        final bytes = widget.videoBytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Video data is unavailable');
        }
        if (kIsWeb) {
          path = XFile.fromData(
            bytes,
            mimeType: 'video/mp4',
            name: widget.mediaName,
          ).path;
          _ownsTempFile = false;
        } else {
          final tmpDir = await getTemporaryDirectory();
          final ext = widget.mediaName.split('.').last;
          final file = File('${tmpDir.path}/${widget.mediaName.hashCode}.$ext');
          if (!file.existsSync()) {
            await file.writeAsBytes(bytes);
          }
          path = file.path;
          _ownsTempFile = true;
        }
      }
      _tmpPath = path;

      final player = Player();
      final controller = VideoController(player);
      final source = kIsWeb ? path : Uri.file(path).toString();
      await player.open(Media(source), play: true);
      await _ensureAudible(player);
      await _waitForVideoMetadata(player);
      final aspectRatio = _resolveAspectRatio(player);

      if (!mounted) {
        await player.dispose();
        return;
      }

      setState(() {
        _player = player;
        _controller = controller;
        _aspectRatio = aspectRatio;
        _loading = false;
      });
      _scheduleControlsHide();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Video load error: $e'),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ));
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final controller = _controller;
    final isMobile = !_isDesktop;
    final isPortraitVideo = _aspectRatio < 0.8;

    return Scaffold(
      backgroundColor: AppColors.bgMain,
      body: SafeArea(
        child: _loading || player == null || controller == null
            ? const Center(
                child: CircularProgressIndicator(color: Colors.white),
              )
            : MouseRegion(
                onEnter: (_) => _onUserActivity(),
                onHover: (_) => _onUserActivity(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _onUserActivity();
                    _togglePlayback(player);
                  },
                  onPanDown: (_) => _onUserActivity(),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Center(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final viewportSize = constraints.biggest;
                              final fittedSize = _fitSizeForAspectRatio(
                                aspectRatio: _aspectRatio,
                                maxWidth: viewportSize.width,
                                maxHeight: viewportSize.height,
                              );
                              final shouldFillViewport =
                                  isPortraitVideo && _preferPortraitZoom;
                              final playerBoxSize = shouldFillViewport
                                  ? viewportSize
                                  : fittedSize;

                              return StreamBuilder<bool>(
                                stream: player.stream.playing,
                                initialData: player.state.playing,
                                builder: (context, snapshot) {
                                  final playing = snapshot.data ?? false;
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Positioned.fill(
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Opacity(
                                              opacity:
                                                  shouldFillViewport ? 1 : 0.28,
                                              child: Video(
                                                controller: controller,
                                                controls: NoVideoControls,
                                                fit: BoxFit.cover,
                                                aspectRatio: _aspectRatio,
                                              ),
                                            ),
                                            if (!shouldFillViewport)
                                              DecoratedBox(
                                                decoration: BoxDecoration(
                                                  color: Colors.black
                                                      .withAlpha(90),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (!shouldFillViewport)
                                        Center(
                                          child: SizedBox(
                                            width: playerBoxSize.width,
                                            height: playerBoxSize.height,
                                            child: Video(
                                              controller: controller,
                                              controls: NoVideoControls,
                                              fit: BoxFit.contain,
                                              aspectRatio: _aspectRatio,
                                            ),
                                          ),
                                        ),
                                      if (shouldFillViewport)
                                        Positioned.fill(
                                          child: Video(
                                            controller: controller,
                                            controls: NoVideoControls,
                                            fit: BoxFit.cover,
                                            aspectRatio: _aspectRatio,
                                          ),
                                        ),
                                      if (isMobile && !playing)
                                        IgnorePointer(
                                          child: Container(
                                            width: 60,
                                            height: 60,
                                            decoration: BoxDecoration(
                                              color:
                                                  Colors.black.withAlpha(150),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color:
                                                    Colors.white.withAlpha(50),
                                              ),
                                            ),
                                            child: const Icon(
                                              Icons.play_arrow_rounded,
                                              color: Colors.white,
                                              size: 34,
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !_controlsVisible,
                          child: AnimatedOpacity(
                            opacity: _controlsVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: Column(
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(8, 8, 8, 0),
                                  child: Row(
                                    children: [
                                      IconButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        icon: const Icon(
                                            Icons.arrow_back_rounded),
                                      ),
                                      const Spacer(),
                                      if (isPortraitVideo) ...[
                                        GestureDetector(
                                          onTap: () {
                                            _onUserActivity();
                                            setState(() {
                                              _preferPortraitZoom =
                                                  !_preferPortraitZoom;
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 8,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.bgSurface,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                  color: AppColors.border),
                                            ),
                                            child: Text(
                                              _preferPortraitZoom
                                                  ? 'Fill'
                                                  : 'Fit',
                                              style: const TextStyle(
                                                color: AppColors.textPrimary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      StreamBuilder<double>(
                                        stream: player.stream.rate,
                                        initialData: player.state.rate,
                                        builder: (context, snapshot) {
                                          final rate = snapshot.data ?? 1.0;
                                          return PopupMenuButton<double>(
                                            tooltip: 'Playback speed',
                                            color: AppColors.bgSurface,
                                            initialValue: rate,
                                            onSelected: (value) {
                                              _onUserActivity();
                                              player.setRate(value);
                                            },
                                            itemBuilder: (context) => const [
                                              PopupMenuItem(
                                                  value: 0.5,
                                                  child: Text('0.5x')),
                                              PopupMenuItem(
                                                  value: 1.0,
                                                  child: Text('1.0x')),
                                              PopupMenuItem(
                                                  value: 1.25,
                                                  child: Text('1.25x')),
                                              PopupMenuItem(
                                                  value: 1.5,
                                                  child: Text('1.5x')),
                                              PopupMenuItem(
                                                  value: 2.0,
                                                  child: Text('2.0x')),
                                            ],
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 8,
                                              ),
                                              decoration: BoxDecoration(
                                                color: AppColors.bgSurface,
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                border: Border.all(
                                                    color: AppColors.border),
                                              ),
                                              child: Text(
                                                '${rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 2)}x',
                                                style: const TextStyle(
                                                  color: AppColors.textPrimary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                const Spacer(),
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(20, 12, 20, 20),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      StreamBuilder<Duration>(
                                        stream: player.stream.position,
                                        initialData: player.state.position,
                                        builder: (context, posSnap) {
                                          final position =
                                              posSnap.data ?? Duration.zero;
                                          return StreamBuilder<Duration>(
                                            stream: player.stream.duration,
                                            initialData: player.state.duration,
                                            builder: (context, durSnap) {
                                              final duration =
                                                  durSnap.data ?? Duration.zero;
                                              final maxMs = duration
                                                  .inMilliseconds
                                                  .toDouble();
                                              final value = maxMs > 0
                                                  ? position.inMilliseconds
                                                      .clamp(
                                                          0,
                                                          duration
                                                              .inMilliseconds)
                                                      .toDouble()
                                                  : 0.0;
                                              return Column(
                                                children: [
                                                  _PlayerSliderTheme(
                                                    child: Slider(
                                                      min: 0,
                                                      max: maxMs <= 0
                                                          ? 1
                                                          : maxMs,
                                                      value: value,
                                                      onChanged: maxMs <= 0
                                                          ? null
                                                          : (v) {
                                                              _onUserActivity();
                                                              player.seek(
                                                                Duration(
                                                                  milliseconds:
                                                                      v.round(),
                                                                ),
                                                              );
                                                            },
                                                    ),
                                                  ),
                                                  Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    children: [
                                                      Text(
                                                        _fmt(position),
                                                        style: const TextStyle(
                                                          color: AppColors
                                                              .textSecondary,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                      Text(
                                                        _fmt(duration),
                                                        style: const TextStyle(
                                                          color: AppColors
                                                              .textSecondary,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              );
                                            },
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 12),
                                      if (_isDesktop)
                                        Row(
                                          children: [
                                            StreamBuilder<bool>(
                                              stream: player.stream.playing,
                                              initialData: player.state.playing,
                                              builder: (context, snapshot) {
                                                final playing =
                                                    snapshot.data ?? false;
                                                return IconButton.filled(
                                                  style: IconButton.styleFrom(
                                                    backgroundColor:
                                                        AppColors.bgSurface,
                                                    foregroundColor:
                                                        AppColors.textPrimary,
                                                  ),
                                                  onPressed: () {
                                                    _onUserActivity();
                                                    _togglePlayback(player);
                                                  },
                                                  icon: Icon(
                                                    playing
                                                        ? Icons.pause_rounded
                                                        : Icons
                                                            .play_arrow_rounded,
                                                  ),
                                                );
                                              },
                                            ),
                                            const SizedBox(width: 12),
                                            StreamBuilder<double>(
                                              stream: player.stream.volume,
                                              initialData: player.state.volume,
                                              builder: (context, snapshot) {
                                                final volume =
                                                    (snapshot.data ?? 100)
                                                        .clamp(0, 100);
                                                return Expanded(
                                                  child: Row(
                                                    children: [
                                                      IconButton(
                                                        onPressed: () {
                                                          _onUserActivity();
                                                          player.setVolume(
                                                            volume == 0
                                                                ? 100
                                                                : 0,
                                                          );
                                                        },
                                                        icon: Icon(
                                                          volume == 0
                                                              ? Icons
                                                                  .volume_off_rounded
                                                              : Icons
                                                                  .volume_up_rounded,
                                                          color: AppColors
                                                              .textPrimary,
                                                        ),
                                                      ),
                                                      Expanded(
                                                        child:
                                                            _PlayerSliderTheme(
                                                          child: Slider(
                                                            min: 0,
                                                            max: 100,
                                                            value: volume
                                                                .toDouble(),
                                                            onChanged: (value) {
                                                              _onUserActivity();
                                                              player.setVolume(
                                                                  value);
                                                            },
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _AlwaysVisibleProgressBar(player: player),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  double _resolveAspectRatio(Player player) {
    final params = player.state.videoParams;
    final aspect = params.aspect ??
        ((params.dw != null && params.dh != null && params.dh! > 0)
            ? params.dw! / params.dh!
            : null) ??
        ((player.state.width != null &&
                player.state.height != null &&
                player.state.height! > 0)
            ? player.state.width! / player.state.height!
            : 16 / 9);
    if (!aspect.isFinite || aspect <= 0) return 16 / 9;
    return aspect;
  }

  Future<void> _togglePlayback(Player player) async {
    await _ensureAudible(player);
    final duration = player.state.duration;
    final position = player.state.position;
    final isAtEnd = duration > Duration.zero &&
        (duration - position) <= const Duration(milliseconds: 250);
    if (isAtEnd) {
      await player.seek(Duration.zero);
      await player.play();
      _scheduleControlsHide();
      return;
    }
    await player.playOrPause();
    _scheduleControlsHide();
  }

  void _onUserActivity() {
    if (!mounted) return;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    final player = _player;
    if (player == null || !player.state.playing) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (_player?.state.playing != true) return;
      setState(() => _controlsVisible = false);
    });
  }

  String _fmt(Duration d) {
    final totalHours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (totalHours > 0) {
      return '${totalHours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

class _PlayerSliderTheme extends StatelessWidget {
  final Widget child;

  const _PlayerSliderTheme({required this.child});

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        activeTrackColor: Colors.white,
        inactiveTrackColor: AppColors.border,
        thumbColor: Colors.white,
        overlayColor: Colors.white.withAlpha(28),
      ),
      child: child,
    );
  }
}

class _AlwaysVisibleProgressBar extends StatelessWidget {
  final Player player;

  const _AlwaysVisibleProgressBar({required this.player});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, posSnap) {
        final position = posSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          initialData: player.state.duration,
          builder: (context, durSnap) {
            final duration = durSnap.data ?? Duration.zero;
            final progress = duration.inMilliseconds <= 0
                ? 0.0
                : (position.inMilliseconds / duration.inMilliseconds)
                    .clamp(0.0, 1.0);
            return SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.white.withAlpha(28),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Voice player ─────────────────────────────────────────────────────────────

class _VoicePlayer extends StatefulWidget {
  final Uint8List? audioBytes;
  final String? localPath;
  final String mediaMime;
  final bool isMe;

  const _VoicePlayer({
    this.audioBytes,
    this.localPath,
    required this.mediaMime,
    this.isMe = false,
  });

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;
  bool _metaReady = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _tmpPath;
  bool _ownsTempFile = false;
  late final List<double> _waveform;

  static const _barCount = 10;
  static const _waveWidth = 120.0;
  static const _waveHeight = 20.0;

  @override
  void initState() {
    super.initState();
    final bytes = widget.audioBytes;
    if (bytes != null && bytes.isNotEmpty) {
      _waveform = _generateWaveform(bytes, _barCount);
    } else {
      _waveform = List.generate(
          _barCount, (i) => 0.25 + ((i % 5) * 0.12).clamp(0.0, 0.7));
    }
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s.name == 'playing');
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) {
        setState(() {
          _duration = d;
          _metaReady = true;
        });
      }
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    });
    _player.setVolume(1.0);
    _prefetchDuration();
  }

  @override
  void dispose() {
    _player.dispose();
    if (_ownsTempFile && _tmpPath != null) {
      try {
        File(_tmpPath!).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  List<double> _generateWaveform(Uint8List bytes, int count) {
    if (bytes.isEmpty) return List.filled(count, 0.3);
    final step = bytes.length / count;
    // Compute raw average deviation per bar
    final raw = List.generate(count, (i) {
      final start = (i * step).round();
      final end = ((i + 1) * step).round().clamp(0, bytes.length);
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
    final range = maxVal - minVal;
    if (range < 1.0) return List.filled(count, 0.4);
    return raw.map((v) => (v - minVal) / range * 0.92 + 0.08).toList();
  }

  Future<void> _prefetchDuration() async {
    try {
      await _prepareTmp();
      if (kIsWeb) {
        await _player.setSource(UrlSource(_tmpPath!));
      } else {
        await _player.setSourceDeviceFile(_tmpPath!);
      }
    } catch (_) {}
  }

  Future<void> _prepareTmp() async {
    if (_tmpPath != null) return;
    if (widget.localPath != null && widget.localPath!.trim().isNotEmpty) {
      _tmpPath = widget.localPath!;
      _ownsTempFile = false;
      return;
    }
    final bytes = widget.audioBytes;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Audio data is unavailable');
    }
    if (kIsWeb) {
      _tmpPath = XFile.fromData(
        bytes,
        mimeType: widget.mediaMime,
        name: 'voice_play_${bytes.hashCode}.${_mimeToExt(widget.mediaMime)}',
      ).path;
      _ownsTempFile = false;
      return;
    }
    final tmpDir = await getTemporaryDirectory();
    final ext = _mimeToExt(widget.mediaMime);
    final file = File('${tmpDir.path}/voice_play_${bytes.hashCode}.$ext');
    if (!file.existsSync()) await file.writeAsBytes(bytes);
    _tmpPath = file.path;
    _ownsTempFile = true;
  }

  String _mimeToExt(String mime) => switch (mime) {
        'audio/m4a' => 'm4a',
        'audio/mp4' => 'm4a',
        'audio/x-m4a' => 'm4a',
        'audio/aac' => 'aac',
        'audio/mp4a-latm' => 'aac',
        'audio/opus' => 'opus',
        'audio/mpeg' => 'mp3',
        _ => 'audio',
      };

  Future<void> _togglePlay() async {
    if (_loading) return;
    if (_playing) {
      await _player.pause();
      return;
    }
    setState(() => _loading = true);
    try {
      await _prepareTmp();
      await _player.setVolume(1.0);
      if (kIsWeb) {
        await _player.play(UrlSource(_tmpPath!));
      } else {
        await _player.play(DeviceFileSource(_tmpPath!));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Playback error: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        ));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _seekFromTap(double tapX) {
    if (_duration.inMilliseconds == 0) return;
    final ratio = (tapX / _waveWidth).clamp(0.0, 1.0);
    _player.seek(
        Duration(milliseconds: (ratio * _duration.inMilliseconds).round()));
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    final posLabel = _fmt(_position);
    final durLabel = _metaReady ? _fmt(_duration) : '--:--';

    // HTML: own bubble → white play button + blue icon; other → dark blue button + white icon
    final btnBg = widget.isMe ? Colors.white : const Color(0xFF0056B3);
    final btnFg = widget.isMe ? const Color(0xFF0A84FF) : Colors.white;
    final activeWave = widget.isMe ? Colors.white : const Color(0xFF0A84FF);
    final inactiveWave =
        widget.isMe ? Colors.white.withAlpha(100) : const Color(0xFF8E8E93);
    final timeColor =
        widget.isMe ? Colors.white.withAlpha(180) : const Color(0xFF8E8E93);

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
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: btnFg),
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
    const gap = 2.0;
    final barW = (size.width - gap * (bars.length - 1)) / bars.length;
    final progressX = size.width * progress;

    for (int i = 0; i < bars.length; i++) {
      final x = i * (barW + gap);
      final barH = (bars[i] * size.height).clamp(2.0, size.height);
      final top = (size.height - barH) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barW, barH),
        const Radius.circular(2),
      );
      final isActive = (x + barW / 2) < progressX;
      canvas.drawRRect(
          rect, Paint()..color = isActive ? activeColor : inactiveColor);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.bars != bars ||
      old.activeColor != activeColor;
}
