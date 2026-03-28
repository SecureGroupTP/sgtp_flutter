import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/qr_data.dart';

/// Dialog for displaying QR code and sharing options
class QrShareDialog extends StatelessWidget {
  final QrShareData data;
  final String title;
  final String? description;

  const QrShareDialog({
    super.key,
    required this.data,
    required this.title,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base64 = data.toBase64();

    return Dialog(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              title,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(
                description!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            
            // QR Code
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: base64,
                version: QrVersions.auto,
                size: 280,
              ),
            ),
            const SizedBox(height: 16),

            // Base64 code (collapsed by default)
            ExpansionTile(
              title: const Text('Show base64'),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    base64,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: base64));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Base64 copied')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  label: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
