import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/qr_data.dart';

/// Full-screen QR scanner.
/// Returns [QrShareData] via [Navigator.pop] — callers should use:
///   final data = await Navigator.push<QrShareData>(context, MaterialPageRoute(...));
/// This avoids the "black screen" bug caused by opening a bottom sheet
/// while the scanner Scaffold was still mounted.
class QrScannerDialog extends StatefulWidget {
  const QrScannerDialog({super.key});

  @override
  State<QrScannerDialog> createState() => _QrScannerDialogState();
}

class _QrScannerDialogState extends State<QrScannerDialog> {
  late final MobileScannerController _controller;
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
    if (_handled) return;
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null) return;

    final data = QrShareData.fromBase64(value);
    if (data != null) {
      _handled = true;
      _controller.stop();
      // Pop FIRST carrying the data — the caller handles it after the scanner
      // page is fully gone, avoiding any context/scaffold conflicts.
      Navigator.pop(context, data);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Invalid QR code format'),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline,
                      size: 64, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text('Camera error',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: theme.colorScheme.error)),
                  const SizedBox(height: 8),
                  Text(error.errorCode.toString(),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white70)),
                ],
              ),
            ),
          ),

          // Close button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),

          // Viewfinder hint frame
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),

          // Hint label
          Positioned(
            bottom: 48,
            left: 24,
            right: 24,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_scanner_outlined,
                      color: Colors.white70, size: 18),
                  SizedBox(width: 8),
                  Text('Point camera at QR code',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
