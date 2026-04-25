import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/qr_data.dart';
import 'package:sgtp_flutter/features/settings/presentation/widgets/pretty_qr_share_panel.dart';

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
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: PrettyQrSharePanel(
          data: data,
          title: title,
          description: description,
          copyMessage: 'Room hex copied',
          exportName:
              title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-'),
          dialogMode: true,
        ),
      ),
    );
  }
}
