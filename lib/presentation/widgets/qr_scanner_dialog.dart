import 'dart:async';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart' hide ImageFormat;
import 'package:image_picker/image_picker.dart';

import '../../core/camera_support.dart';
import '../../core/qr_data.dart';

/// Full-screen QR scanner matching the design/scan-qr.html spec.
/// Uses flutter_zxing — works on all platforms (Android, iOS, macOS, Windows, Linux, Web).
/// Returns [QrShareData] via [Navigator.pop].
class QrScannerDialog extends StatefulWidget {
  const QrScannerDialog({super.key});

  @override
  State<QrScannerDialog> createState() => _QrScannerDialogState();
}

class _QrScannerDialogState extends State<QrScannerDialog>
    with SingleTickerProviderStateMixin {
  bool _handled = false;
  bool _flashOn = false;
  bool _cameraError = false;
  String? _cameraErrorMsg;
  CameraController? _cameraController;

  late final AnimationController _scanAnim;
  late final Animation<double> _scanPos;

  @override
  void initState() {
    super.initState();
    _scanAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
    _scanPos = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _scanAnim, curve: Curves.easeInOut),
    );
    if (!isCameraSupported) {
      _cameraError = true;
      _cameraErrorMsg = cameraUnsupportedReason;
    }
  }

  @override
  void dispose() {
    _scanAnim.dispose();
    super.dispose();
  }

  void _onScan(Code code) {
    if (_handled || !code.isValid || code.text == null) return;
    final data = QrShareData.parse(code.text!);
    if (data != null) {
      _handled = true;
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

  void _toggleFlash() {
    if (_cameraController == null) return;
    final next = _flashOn ? FlashMode.off : FlashMode.torch;
    _cameraController!.setFlashMode(next).then((_) {
      if (mounted) setState(() => _flashOn = !_flashOn);
    }).catchError((_) {});
  }

  Future<void> _pickFromGallery() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;

    final code = await zx.readBarcodeImagePath(
      file,
      DecodeParams(
        imageFormat: 0x03000102, // ImageFormat.rgb
        tryHarder: true,
        tryRotate: true,
      ),
    );
    if (!mounted) return;

    if (!code.isValid || code.text == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No QR code found in image'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ));
      return;
    }

    final data = QrShareData.parse(code.text!);
    if (data != null && !_handled) {
      _handled = true;
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera feed ──────────────────────────────────────────────────
          if (_cameraError)
            _buildCameraError()
          else if (cameraSupportsStreaming)
            ReaderWidget(
              onScan: _onScan,
              showScannerOverlay: false,
              showFlashlight: false,
              showToggleCamera: false,
              showGallery: false,
              tryHarder: true,
              resolution: ResolutionPreset.high,
              onControllerCreated: (controller, error) {
                _cameraController = controller;
                if (error != null && mounted && !_cameraError) {
                  setState(() {
                    _cameraError = true;
                    _cameraErrorMsg = 'Camera access required';
                  });
                }
              },
              loading: const ColoredBox(color: Colors.black),
            )
          else
            _WindowsScanner(onScan: _onScan),

          // ── Dimmed overlay + viewfinder corners + scan line ──────────────
          if (!_cameraError) _ScannerOverlay(scanPos: _scanPos),

          // ── Instruction text ─────────────────────────────────────────────
          if (!_cameraError)
            Positioned(
              top: MediaQuery.of(context).size.height / 2 + 152,
              left: 40,
              right: 40,
              child: const Text(
                'Align the QR code within the frame to add a new contact',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFFD1D1D6),
                  height: 1.4,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),

          // ── Floating AppBar ──────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildAppBar(context),
          ),

          // ── Gallery button ───────────────────────────────────────────────
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(child: _buildGalleryButton()),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      padding: EdgeInsets.fromLTRB(20, top + 16, 20, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          _IconBtn(icon: Icons.close, onTap: () => Navigator.pop(context)),
          const Expanded(
            child: Text(
              'Scan QR',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Colors.white,
                letterSpacing: -0.5,
                shadows: [Shadow(color: Colors.black, blurRadius: 4)],
              ),
            ),
          ),
          _IconBtn(
            icon: _flashOn ? Icons.flashlight_on : Icons.flashlight_off,
            iconColor: _flashOn ? const Color(0xFFFFCC00) : Colors.white,
            onTap: _cameraError ? null : _toggleFlash,
          ),
        ],
      ),
    );
  }

  Widget _buildGalleryButton() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: GestureDetector(
          onTap: _pickFromGallery,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xD91E1E24),
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: const Color(0xFF2C2C30)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, color: Colors.white, size: 20),
                SizedBox(width: 10),
                Text(
                  'Upload from Gallery',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCameraError() {
    return Container(
      color: const Color(0xFF0A0A0C),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_off_outlined,
                size: 56, color: Color(0xFF8E8E93)),
            const SizedBox(height: 16),
            const Text(
              'Camera access required',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: Color(0xFFF5F5F5),
              ),
            ),
            if (_cameraErrorMsg != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _cameraErrorMsg!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF8E8E93)),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Allow camera access in system settings',
              style: TextStyle(fontSize: 14, color: Color(0xFF8E8E93)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Windows snapshot scanner (fallback when streaming is not supported) ───────

class _WindowsScanner extends StatefulWidget {
  const _WindowsScanner({required this.onScan});
  final void Function(Code) onScan;

  @override
  State<_WindowsScanner> createState() => _WindowsScannerState();
}

class _WindowsScannerState extends State<_WindowsScanner> {
  CameraController? _ctrl;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (_disposed || cameras.isEmpty) return;
      final ctrl = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      if (_disposed) {
        ctrl.dispose();
        return;
      }
      if (mounted) setState(() => _ctrl = ctrl);
      _scheduleNextScan();
    } catch (_) {}
  }

  void _scheduleNextScan() {
    if (_disposed) return;
    Future.delayed(const Duration(milliseconds: 800), _scan);
  }

  Future<void> _scan() async {
    if (_disposed || _ctrl == null || !_ctrl!.value.isInitialized) return;
    try {
      final file = await _ctrl!.takePicture();
      if (_disposed) return;
      final code = await zx.readBarcodeImagePath(
        file,
        DecodeParams(imageFormat: 0x03000102, tryHarder: true, tryRotate: true),
      );
      if (!_disposed && code.isValid && code.text != null) {
        widget.onScan(code);
        return;
      }
    } catch (_) {}
    _scheduleNextScan();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return RepaintBoundary(
      child: LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final aspect = ctrl.value.aspectRatio;

        final double previewW, previewH;
        if (aspect >= w / h) {
          previewH = h;
          previewW = h * aspect;
        } else {
          previewW = w;
          previewH = w / aspect;
        }

        return ClipRect(
          child: Center(
            child: SizedBox(
              width: previewW,
              height: previewH,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(-1, 1, 1),
                child: ctrl.buildPreview(),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ── Viewfinder overlay ────────────────────────────────────────────────────────

class _ScannerOverlay extends StatelessWidget {
  const _ScannerOverlay({required this.scanPos});
  final Animation<double> scanPos;

  @override
  Widget build(BuildContext context) {
    const size = 260.0;
    final screen = MediaQuery.of(context).size;
    final left = (screen.width - size) / 2;
    final top = (screen.height - size) / 2;

    return Stack(children: [
      Positioned(
          left: 0,
          top: 0,
          right: 0,
          height: top,
          child: const ColoredBox(color: Color(0xA6000000))),
      Positioned(
          left: 0,
          top: top + size,
          right: 0,
          bottom: 0,
          child: const ColoredBox(color: Color(0xA6000000))),
      Positioned(
          left: 0,
          top: top,
          width: left,
          height: size,
          child: const ColoredBox(color: Color(0xA6000000))),
      Positioned(
          left: left + size,
          top: top,
          right: 0,
          height: size,
          child: const ColoredBox(color: Color(0xA6000000))),
      Positioned(
        left: left,
        top: top,
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _CornerPainter()),
        ),
      ),
      AnimatedBuilder(
        animation: scanPos,
        builder: (_, __) => Positioned(
          left: left + 2,
          top: top + scanPos.value * (size - 2),
          width: size - 4,
          height: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withAlpha(153),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    ]);
  }
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    const arm = 40.0;
    const r = 16.0;
    final w = size.width;
    final h = size.height;
    final radius = const Radius.circular(r);

    canvas.drawPath(
        Path()
          ..moveTo(0, arm)
          ..lineTo(0, r)
          ..arcToPoint(Offset(r, 0), radius: radius, clockwise: true)
          ..lineTo(arm, 0),
        paint);
    canvas.drawPath(
        Path()
          ..moveTo(w - arm, 0)
          ..lineTo(w - r, 0)
          ..arcToPoint(Offset(w, r), radius: radius, clockwise: false)
          ..lineTo(w, arm),
        paint);
    canvas.drawPath(
        Path()
          ..moveTo(0, h - arm)
          ..lineTo(0, h - r)
          ..arcToPoint(Offset(r, h), radius: radius, clockwise: false)
          ..lineTo(arm, h),
        paint);
    canvas.drawPath(
        Path()
          ..moveTo(w - arm, h)
          ..lineTo(w - r, h)
          ..arcToPoint(Offset(w, h - r), radius: radius, clockwise: true)
          ..lineTo(w, h - arm),
        paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => false;
}

// ── Floating icon button ──────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  const _IconBtn(
      {required this.icon, required this.onTap, this.iconColor = Colors.white});
  final IconData icon;
  final VoidCallback? onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(77),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
        ),
      ),
    );
  }
}
