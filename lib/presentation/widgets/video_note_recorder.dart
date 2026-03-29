import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Full-screen video-note recorder overlay.
/// Shows live circular camera preview (front camera by default),
/// a hold-to-record button, and a swap-camera button.
///
/// Pops with `Uint8List` video bytes on success, or `null` on cancel.
class VideoNoteRecorderPage extends StatefulWidget {
  const VideoNoteRecorderPage({super.key});

  @override
  State<VideoNoteRecorderPage> createState() => _VideoNoteRecorderPageState();
}

class _VideoNoteRecorderPageState extends State<VideoNoteRecorderPage>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _ctrl;
  int _cameraIndex = 0; // 0 = front, 1 = back

  bool _initialising = true;
  bool _recording    = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    setState(() { _initialising = true; _initError = null; });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() { _initError = 'No cameras found'; _initialising = false; });
        return;
      }
      _cameras = cameras;

      // Prefer front camera (index 0 in list is usually back on Android,
      // so we search explicitly).
      int target = index;
      if (index == 0) {
        final frontIdx = cameras.indexWhere(
            (c) => c.lensDirection == CameraLensDirection.front);
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
        setState(() { _ctrl = ctrl; _initialising = false; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _initError = e.toString(); _initialising = false; });
      }
    }
  }

  Future<void> _swapCamera() async {
    if (_cameras.length < 2) return;
    if (_recording) await _ctrl?.stopVideoRecording();
    setState(() { _recording = false; });
    final next = (_cameraIndex + 1) % _cameras.length;
    await _initCamera(index: next);
  }

  Future<void> _startRecording() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _recording) return;
    try {
      await ctrl.startVideoRecording();
      setState(() => _recording = true);
    } catch (_) {}
  }

  Future<void> _stopAndSend() async {
    final ctrl = _ctrl;
    if (ctrl == null || !_recording) return;
    try {
      final xfile = await ctrl.stopVideoRecording();
      setState(() => _recording = false);
      final bytes = await File(xfile.path).readAsBytes();
      await File(xfile.path).delete().catchError((_) {});
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (_) {
      setState(() => _recording = false);
    }
  }

  void _cancel() {
    if (_recording) {
      _ctrl?.stopVideoRecording().catchError((_) {});
    }
    Navigator.of(context).pop(null);
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
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
              top: 0, left: 0, right: 0, bottom: 0,
              child: IgnorePointer(
                child: Center(
                  child: SizedBox(
                    width: 240,
                    height: 240,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      valueColor: const AlwaysStoppedAnimation(
                          Color(0xFFFF3B30)),
                    ),
                  ),
                ),
              ),
            ),

          // ── Bottom controls: hold-to-record button ────────────────────
          Positioned(
            bottom: 0, left: 0, right: 0,
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
                        'Hold to record',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Record button
                    GestureDetector(
                      onLongPressStart: (_) => _startRecording(),
                      onLongPressEnd:   (_) => _stopAndSend(),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width:  _recording ? 80 : 72,
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
                                  : Colors.white).withAlpha(60),
                              blurRadius: 24,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          _recording ? Icons.stop_rounded : Icons.videocam_rounded,
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
        width: 240, height: 240,
        child: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    if (_initError != null) {
      return SizedBox(
        width: 240, height: 240,
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
            child: CameraPreview(ctrl),
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
        width: 40, height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withAlpha(120),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}