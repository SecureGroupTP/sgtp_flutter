import 'dart:io';
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen video-note recorder overlay.
/// Shows live circular camera preview (front camera by default),
/// a hold-to-record button, and a swap-camera button.
///
/// Pops with `Uint8List` video bytes on success, or `null` on cancel.
class VideoNoteRecorderPage extends StatefulWidget {
  final String? preferredCameraName;
  const VideoNoteRecorderPage({super.key, this.preferredCameraName});

  @override
  State<VideoNoteRecorderPage> createState() => _VideoNoteRecorderPageState();
}

class _VideoNoteRecorderPageState extends State<VideoNoteRecorderPage>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _ctrl;
  int _cameraIndex = 0; // 0 = front, 1 = back

  bool _initialising = true;
  bool _recording = false;
  String? _initError;
  DateTime? _recordStartAt;

  static const Duration _minRecordDuration = Duration(milliseconds: 400);
  static const Duration _holdIntentThreshold = Duration(milliseconds: 350);

  bool _pointerDown = false;
  bool _toggleMode = false;
  bool _holdIntent = false;
  Timer? _holdIntentTimer;
  bool _pressWasRecording = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdIntentTimer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(index: _cameraIndex);
    }
  }

  Future<void> _initCamera({int index = 0}) async {
    setState(() {
      _initialising = true;
      _initError = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _initError = 'No cameras found';
          _initialising = false;
        });
        return;
      }
      _cameras = cameras;

      // Prefer camera selected in settings, then front camera fallback.
      int target = index;
      final preferred = widget.preferredCameraName;
      if (preferred != null && preferred.isNotEmpty) {
        final prefIdx = cameras.indexWhere((c) => c.name == preferred);
        if (prefIdx >= 0) {
          target = prefIdx;
        }
      } else if (index == 0) {
        final frontIdx = cameras
            .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
        target = frontIdx >= 0 ? frontIdx : 0;
      }
      _cameraIndex = target;

      await _ctrl?.dispose();
      final ctrl = CameraController(
        cameras[target],
        ResolutionPreset.high,
        enableAudio: true,
      );
      await ctrl.initialize();
      if (mounted) {
        setState(() {
          _ctrl = ctrl;
          _initialising = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = e.toString();
          _initialising = false;
        });
      }
    }
  }

  Future<void> _swapCamera() async {
    if (_cameras.length < 2) return;
    if (_recording) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Can't switch camera while recording")),
      );
      return;
    }
    final next = (_cameraIndex + 1) % _cameras.length;
    await _initCamera(index: next);
  }

  Future<void> _startRecording() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _recording) return;
    try {
      HapticFeedback.mediumImpact();
      setState(() {
        _recording = true;
        _recordStartAt = DateTime.now();
        _toggleMode = true; // default: tap-to-start, tap-to-stop
      });
      await ctrl.startVideoRecording();
    } catch (_) {}
  }

  Future<Uint8List?> _stopRecording() async {
    final ctrl = _ctrl;
    if (ctrl == null || !_recording) return null;
    try {
      if (!ctrl.value.isRecordingVideo) {
        setState(() => _recording = false);
        return null;
      }
      final xfile = await ctrl.stopVideoRecording();
      final startedAt = _recordStartAt;
      _recordStartAt = null;
      setState(() => _recording = false);

      final elapsed = startedAt == null
          ? Duration.zero
          : DateTime.now().difference(startedAt);
      final bytes = await File(xfile.path).readAsBytes();
      try {
        await File(xfile.path).delete();
      } catch (_) {}
      if (elapsed < _minRecordDuration) {
        if (!mounted) return null;
        HapticFeedback.selectionClick();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hold a bit longer to record')),
        );
        return null;
      }
      return bytes;
    } catch (_) {
      setState(() => _recording = false);
      return null;
    }
  }

  Future<void> _stopAndConfirmSend() async {
    final bytes = await _stopRecording();
    if (bytes == null || !mounted) return;

    HapticFeedback.lightImpact();
    final send = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send this video note?'),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF453A),
              side: const BorderSide(color: Color(0xFFFF453A)),
            ),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (send == true) {
      Navigator.of(context).pop(bytes);
    }
  }

  void _cancel() {
    if (_recording) {
      () async {
        try {
          await _ctrl?.stopVideoRecording();
        } catch (_) {}
      }();
    }
    if (mounted) Navigator.of(context).pop(null);
  }

  void _onPressDown() {
    _pointerDown = true;
    _pressWasRecording = _recording;
    _holdIntent = false;
    _holdIntentTimer?.cancel();

    if (_recording) return;

    _startRecording();
    _holdIntentTimer = Timer(_holdIntentThreshold, () {
      if (!mounted) return;
      if (_pointerDown && _recording) {
        setState(() => _holdIntent = true);
        HapticFeedback.selectionClick();
      }
    });
  }

  void _onPressUp() {
    _pointerDown = false;
    _holdIntentTimer?.cancel();

    if (!_recording) return;

    // Hold-to-record: stop on release.
    if (_holdIntent) {
      _stopAndConfirmSend();
      return;
    }

    // Tap-to-start keeps recording; a subsequent tap stops.
    if (_toggleMode && _pressWasRecording) {
      _stopAndConfirmSend();
    }
  }

  void _onPressCancel() {
    _pointerDown = false;
    _holdIntentTimer?.cancel();
    if (_recording && _holdIntent) {
      _stopAndConfirmSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Dark background ───────────────────────────────────────────
          const ColoredBox(color: Colors.black),

          // ── Circular camera preview ───────────────────────────────────
          Center(
            child: _buildPreview(),
          ),

          // ── Top bar: cancel + "Video note" label ─────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    _CircleBtn(
                      icon: Icons.close,
                      onTap: _cancel,
                    ),
                    const Spacer(),
                    const Text(
                      'Video note',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    // Swap camera
                    if (_cameras.length > 1)
                      _CircleBtn(
                        icon: Icons.flip_camera_ios_outlined,
                        onTap: _swapCamera,
                      )
                    else
                      const SizedBox(width: 40),
                  ],
                ),
              ),
            ),
          ),

          // ── Recording indicator ───────────────────────────────────────
          if (_recording)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Center(
                  child: SizedBox(
                    width: 240,
                    height: 240,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      valueColor:
                          const AlwaysStoppedAnimation(Color(0xFFFF3B30)),
                    ),
                  ),
                ),
              ),
            ),

          // ── Bottom controls: hold-to-record button ────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Hint
                    AnimatedOpacity(
                      opacity: _recording ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      child: const Text(
                        'Tap or hold to record',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Record button
                    GestureDetector(
                      onTapDown: (_) => _onPressDown(),
                      onTapUp: (_) => _onPressUp(),
                      onTapCancel: _onPressCancel,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: _recording ? 80 : 72,
                        height: _recording ? 80 : 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _recording
                              ? const Color(0xFFFF3B30)
                              : Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: (_recording
                                      ? const Color(0xFFFF3B30)
                                      : Colors.white)
                                  .withAlpha(60),
                              blurRadius: 24,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          _recording
                              ? Icons.stop_rounded
                              : Icons.videocam_rounded,
                          color: _recording ? Colors.white : Colors.black,
                          size: 32,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_initialising) {
      return const SizedBox(
        width: 240,
        height: 240,
        child: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    if (_initError != null) {
      return SizedBox(
        width: 240,
        height: 240,
        child: Center(
          child: Text(_initError!,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center),
        ),
      );
    }
    final ctrl = _ctrl;
    if (ctrl == null) return const SizedBox.shrink();

    return Stack(
      alignment: Alignment.center,
      children: [
        // Circle clip around camera preview
        SizedBox(
          width: 240,
          height: 240,
          child: ClipOval(
            child: _coverCameraPreview(ctrl),
          ),
        ),
        // Blue border (thicker when recording)
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 240,
          height: 240,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: _recording
                  ? const Color(0xFFFF3B30)
                  : const Color(0xFF0A84FF),
              width: _recording ? 4 : 3,
            ),
          ),
        ),
      ],
    );
  }

  /// Scale camera preview to cover-fill a square, then we clip it as a circle.
  Widget _coverCameraPreview(CameraController ctrl) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final preview = CameraPreview(ctrl);
        final previewAspect = ctrl.value.aspectRatio;
        final widgetAspect = size.width / size.height;

        // Scale so that preview covers the widget bounds (no squish).
        final scale = previewAspect / widgetAspect;
        return Transform.scale(
          scale: scale < 1 ? 1 / scale : scale,
          child: Center(child: preview),
        );
      },
    );
  }
}

/// Small semi-transparent circle button.
class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withAlpha(120),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
