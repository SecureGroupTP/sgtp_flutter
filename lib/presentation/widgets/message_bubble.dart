import 'package:flutter/material.dart';

import '../../domain/entities/message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isMe = message.isFromMe;

    final bgColor = isMe
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;

    final textColor = isMe
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    final timeStr = _formatTime(message.receivedAt);
    final senderLabel = isMe ? 'Me' : message.senderUUID.substring(0, 8);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Container(
          margin: EdgeInsets.only(
            left: isMe ? 48 : 8,
            right: isMe ? 8 : 48,
            top: 4,
            bottom: 4,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
          ),
          child: message.type == MessageType.image
              ? _buildImageContent(context, theme, textColor, senderLabel, timeStr, isMe)
              : _buildTextContent(theme, textColor, senderLabel, timeStr, isMe),
        ),
      ),
    );
  }

  Widget _buildTextContent(
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMe)
            Text(
              senderLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          const SizedBox(height: 2),
          Text(
            message.content,
            style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
          ),
          const SizedBox(height: 4),
          Text(
            '${message.isFromHistory ? '~ ' : ''}$timeStr',
            style: theme.textTheme.labelSmall?.copyWith(
              color: textColor.withAlpha(160),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageContent(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    String senderLabel,
    String timeStr,
    bool isMe,
  ) {
    return ClipRRect(
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
          if (!isMe)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                senderLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          GestureDetector(
            onTap: () => _showFullImage(context),
            child: Image.memory(
              message.imageBytes!,
              fit: BoxFit.cover,
              errorBuilder: (context, err, st) => const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.broken_image_outlined, size: 48),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Text(
              '${message.isFromHistory ? '~ ' : ''}$timeStr',
              style: theme.textTheme.labelSmall?.copyWith(
                color: textColor.withAlpha(160),
              ),
            ),
          ),
        ],
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

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
