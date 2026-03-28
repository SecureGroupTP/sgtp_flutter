import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/qr_data.dart';

/// Dialog for scanning QR code
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
  bool _hasPermission = true;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final barcode = barcodes.first;
                final value = barcode.rawValue;
                
                if (value != null) {
                  print('📱 [QR] Scanned: $value');
                  final data = QrShareData.fromBase64(value);
                  
                  if (data != null) {
                    print('✅ [QR] Decoded successfully');
                    widget.onQrScanned(data);
                    Navigator.pop(context);
                  } else {
                    print('❌ [QR] Failed to decode');
                    _showError('Invalid QR code format');
                  }
                }
              }
            },
            errorBuilder: (context, error, child) {
              if (!_hasPermission) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.camera_alt_outlined,
                          size: 64, color: theme.colorScheme.error),
                      const SizedBox(height: 16),
                      Text('Camera permission required',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.error,
                          )),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              }

              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline,
                        size: 64, color: theme.colorScheme.error),
                    const SizedBox(height: 16),
                    Text('Scanner error',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.error,
                        )),
                    const SizedBox(height: 8),
                    Text(error.errorCode.toString(),
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              );
            },
          ),
          // Close button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton.filled(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          // Info text
          Positioned(
            bottom: 32,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withAlpha(240),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: theme.colorScheme.onSurface, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Point camera at QR code',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}
