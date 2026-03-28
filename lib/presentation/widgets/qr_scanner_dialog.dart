import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/qr_data.dart';

class QrScannerDialog extends StatefulWidget {
  final Function(QrShareData) onQrScanned;

  const QrScannerDialog({
    super.key,
    required this.onQrScanned,
  });

  @override
  State<QrScannerDialog> createState() => _QrScannerDialogState();
}

class _QrScannerDialogState extends State<QrScannerDialog> {
  late MobileScannerController _controller;
  // Guard against onDetect firing multiple times for the same QR frame
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return; // already processed — ignore repeated fires
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null) return;

    final data = QrShareData.fromBase64(value);
    if (data != null) {
      _handled = true;
      _controller.stop(); // stop camera immediately so onDetect stops firing
      widget.onQrScanned(data);
      Navigator.pop(context);
    } else {
      // Show error but don't set _handled — let user try again
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Invalid QR code format'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text('Scanner error',
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.error)),
                  const SizedBox(height: 8),
                  Text(error.errorCode.toString(),
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton.filled(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            bottom: 32, left: 24, right: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withAlpha(240),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: theme.colorScheme.onSurface, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Point camera at QR code',
                      style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
