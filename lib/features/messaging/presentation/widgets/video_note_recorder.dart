import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sgtp_camera/sgtp_camera.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/video_note_pipeline.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';

class VideoNoteCaptureResult {
  final XFile xFile;
  final String mime;
  final VideoNoteMetadata metadata;

  const VideoNoteCaptureResult({
    required this.xFile,
    required this.mime,
    required this.metadata,
  });
}

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

// ---------------------------------------------------------------------------

class VideoNoteRecorderPage extends StatefulWidget {
  final String? preferredCameraName;

  const VideoNoteRecorderPage({
    super.key,
    this.preferredCameraName,
  });

  @override
  State<VideoNoteRecorderPage> createState() => _VideoNoteRecorderPageState();
}

class _VideoNoteRecorderPageState extends State<VideoNoteRecorderPage>
    with WidgetsBindingObserver {
  static const _maxDuration = Duration(seconds: 60);
  static const _minDuration = Duration(milliseconds: 400);

  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;

  // --- Desktop (SgtpCamera) ---
  List<CameraDeviceInfo> _sgtpCameras = const [];
  int _sgtpIndex = 0;

  // --- Mobile (camera package) ---
  List<CameraDescription> _mobileCameras = const [];
  CameraController? _mobileController;
  int _mobileIndex = 0;

  bool _initializing = true;
  bool _isRecording = false;
  bool _isProcessing = false;
  String? _error;
  Duration _elapsed = Duration.zero;

  // path used for the current desktop recording
  String? _recordingPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktop) {
      SgtpCamera.init();
      unawaited(_initDesktop(selectDefault: true));
    } else {
      unawaited(_initMobile(selectDefault: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _stopwatch.stop();
    if (_isDesktop) {
      SgtpCamera.close();
    } else {
      unawaited(_mobileController?.dispose());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDesktop) return; // GStreamer handles this internally
    final ctrl = _mobileController;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      unawaited(ctrl.dispose());
      _mobileController = null;
    } else if (state == AppLifecycleState.resumed && !_isProcessing) {
      unawaited(_initMobile(index: _mobileIndex));
    }
  }

  // -------------------------------------------------------------------------
  // Desktop init
  // -------------------------------------------------------------------------

  Future<void> _initDesktop({int index = 0, bool selectDefault = false}) async {
    setState(() { _initializing = true; _error = null; });
    try {
      SgtpCamera.close();
      final cameras = SgtpCamera.enumerate();
      AppLogger.i('Desktop cameras: ${cameras.length}', tag: 'VIDEO');
      if (cameras.isEmpty) {
        setState(() { _initializing = false; _error = 'No cameras found'; });
        return;
      }
      _sgtpCameras = cameras;

      var target = index.clamp(0, cameras.length - 1);
      if (selectDefault) {
        final preferred = widget.preferredCameraName;
        if (preferred != null && preferred.isNotEmpty) {
          final i = cameras.indexWhere((c) => c.id == preferred || c.displayName == preferred);
          if (i >= 0) target = i;
        }
      }
      _sgtpIndex = target;

      final rc = SgtpCamera.open(
        deviceId: cameras[target].id,
        previewWidth: 480,
        previewHeight: 480,
      );
      if (rc != 0) throw Exception('sgtp_camera_open failed: $rc');

      if (!mounted) { SgtpCamera.close(); return; }
      setState(() { _initializing = false; });
    } catch (e) {
      AppLogger.e('Desktop camera init failed: $e', tag: 'VIDEO');
      if (!mounted) return;
      setState(() { _initializing = false; _error = 'Failed to open camera: $e'; });
    }
  }

  // -------------------------------------------------------------------------
  // Mobile init
  // -------------------------------------------------------------------------

  Future<void> _initMobile({
    int index = 0,
    bool selectDefault = false,
    bool enableAudio = false,
  }) async {
    setState(() { _initializing = true; _error = null; });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() { _initializing = false; _error = 'No cameras found'; });
        return;
      }
      _mobileCameras = cameras;

      var target = index.clamp(0, cameras.length - 1);
      if (selectDefault) {
        final preferred = widget.preferredCameraName;
        if (preferred != null && preferred.isNotEmpty) {
          final i = cameras.indexWhere((c) => c.name == preferred);
          if (i >= 0) target = i;
        } else {
          final front = cameras.indexWhere(
              (c) => c.lensDirection == CameraLensDirection.front);
          if (front >= 0) target = front;
        }
      }

      await _mobileController?.dispose();
      final ctrl = CameraController(cameras[target], ResolutionPreset.medium,
          enableAudio: enableAudio);
      await ctrl.initialize();
      await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (enableAudio && Platform.isIOS) await ctrl.prepareForVideoRecording();

      if (!mounted) { await ctrl.dispose(); return; }
      setState(() {
        _mobileController = ctrl;
        _mobileIndex = target;
        _initializing = false;
      });
    } catch (e) {
      AppLogger.e('Mobile camera init failed: $e', tag: 'VIDEO');
      if (!mounted) return;
      setState(() { _initializing = false; _error = 'Failed to open camera: $e'; });
    }
  }

  // -------------------------------------------------------------------------
  // Swap camera
  // -------------------------------------------------------------------------

  Future<void> _swapCamera() async {
    if (_isProcessing) return;
    if (_isDesktop) {
      if (_sgtpCameras.length < 2) return;
      final next = (_sgtpIndex + 1) % _sgtpCameras.length;
      await _initDesktop(index: next);
    } else {
      if (_mobileCameras.length < 2) return;
      final next = (_mobileIndex + 1) % _mobileCameras.length;
      if (_isRecording) {
        try {
          await _mobileController?.setDescription(_mobileCameras[next]);
          setState(() => _mobileIndex = next);
        } catch (e) { _showSnack('Failed to switch camera: $e'); }
      } else {
        await _initMobile(index: next);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Start recording
  // -------------------------------------------------------------------------

  Future<void> _startRecording() async {
    if (_isRecording || _isProcessing) return;
    try {
      if (_isDesktop) {
        final tmp = await getTemporaryDirectory();
        _recordingPath =
            '${tmp.path}/videonote_${DateTime.now().millisecondsSinceEpoch}.mp4';
        final rc = SgtpCamera.startRecording(outputPath: _recordingPath!);
        if (rc != 0) throw Exception('start_recording failed: $rc');
      } else {
        // Ensure audio is enabled on mobile
        final ctrl = _mobileController;
        if (ctrl == null) return;
        if (!ctrl.value.isInitialized) return;
        // Re-init with audio if not enabled
        final hasAudio = ctrl.value.description.lensDirection != CameraLensDirection.front;
        if (!hasAudio) {
          await _initMobile(index: _mobileIndex, enableAudio: true);
          if (_mobileController == null) return;
        }
        await _mobileController!.startVideoRecording();
      }

      HapticFeedback.mediumImpact();
      _stopwatch..reset()..start();
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        if (_stopwatch.elapsed >= _maxDuration) {
          unawaited(_stopAndPrepare());
          return;
        }
        setState(() => _elapsed = _stopwatch.elapsed);
      });
      setState(() { _isRecording = true; _elapsed = Duration.zero; });
    } catch (e) {
      AppLogger.e('Start recording failed: $e', tag: 'VIDEO');
      _showSnack('Failed to start recording: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Stop and prepare
  // -------------------------------------------------------------------------

  Future<void> _stopAndPrepare() async {
    if (!_isRecording || _isProcessing) return;
    _ticker?.cancel();
    _stopwatch.stop();
    final elapsed = _stopwatch.elapsed;

    setState(() { _isProcessing = true; _isRecording = false; _elapsed = elapsed; });

    try {
      if (_isDesktop) {
        await _stopDesktop(elapsed);
      } else {
        await _stopMobile(elapsed);
      }
    } catch (e) {
      AppLogger.e('Recorder finalize failed: $e', tag: 'VIDEO');
      if (!mounted) return;
      setState(() { _isProcessing = false; _isRecording = false; });
      _showSnack('Failed to finalize video note: $e');
    }
  }

  Future<void> _stopDesktop(Duration elapsed) async {
    if (elapsed < _minDuration) {
      SgtpCamera.stopRecording();
      if (_recordingPath != null) await _deleteFile(_recordingPath!);
      _recordingPath = null;
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _showSnack('Hold a bit longer to record');
      return;
    }

    final durationMs = SgtpCamera.stopRecording();
    final path = _recordingPath!;
    _recordingPath = null;

    final file = File(path);
    final fileSize = await file.length();
    final actualDurationMs = durationMs > 0 ? durationMs : elapsed.inMilliseconds;

    AppLogger.i('Desktop recording done: $path, ${actualDurationMs}ms, ${fileSize}B',
        tag: 'VIDEO');

    if (!mounted) return;
    setState(() => _isProcessing = false);
    Navigator.of(context).pop(VideoNoteCaptureResult(
      xFile: XFile(path),
      mime: 'video/mp4',
      metadata: VideoNoteMetadata(
        durationMs: actualDurationMs.clamp(0, 60000),
        width: 480,
        height: 480,
        hasAudio: true,
        fileSizeBytes: fileSize,
      ),
    ));
  }

  Future<void> _stopMobile(Duration elapsed) async {
    final ctrl = _mobileController;
    if (ctrl == null) return;

    final recorded = await ctrl.stopVideoRecording();
    AppLogger.i('Mobile recording done: ${recorded.path}', tag: 'VIDEO');

    if (elapsed < _minDuration) {
      await _deleteFile(recorded.path);
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _showSnack('Hold a bit longer to record');
      return;
    }

    final prepared = await VideoNotePipeline.prepare(sourceFile: recorded);
    if (prepared.xFile.path != recorded.path) await _deleteFile(recorded.path);

    if (!mounted) return;
    setState(() => _isProcessing = false);
    Navigator.of(context).pop(VideoNoteCaptureResult(
      xFile: prepared.xFile,
      mime: prepared.mime,
      metadata: prepared.metadata,
    ));
  }

  // -------------------------------------------------------------------------
  // Cancel
  // -------------------------------------------------------------------------

  Future<void> _cancel() async {
    if (_isRecording) {
      if (_isDesktop) {
        SgtpCamera.stopRecording();
        if (_recordingPath != null) await _deleteFile(_recordingPath!);
        _recordingPath = null;
      } else {
        try {
          final f = await _mobileController?.stopVideoRecording();
          if (f != null) await _deleteFile(f.path);
        } catch (_) {}
      }
    }
    if (mounted) Navigator.of(context).pop(null);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Future<void> _deleteFile(String path) async {
    if (kIsWeb || path.isEmpty) return;
    try { await File(path).delete(); } catch (_) {}
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  bool get _canSwap => _isDesktop
      ? _sgtpCameras.length >= 2
      : _mobileCameras.length >= 2;

  bool get _previewReady => _isDesktop
      ? !_initializing && _error == null
      : _mobileController?.value.isInitialized == true;

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final progress =
        (_elapsed.inMilliseconds / _maxDuration.inMilliseconds).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: const Color(0xFF06070A),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _isProcessing ? null : _cancel,
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  const Spacer(),
                  Text(
                    _isProcessing ? 'Preparing…' : _format(_elapsed),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: (_isProcessing || !_canSwap) ? null : _swapCamera,
                    icon: const Icon(Icons.cameraswitch_rounded,
                        color: Colors.white),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _isRecording
                                ? const Color(0xFF0A84FF)
                                : const Color(0x33FFFFFF),
                            width: 6,
                          ),
                        ),
                      ),
                      ClipOval(
                        child: Container(
                          color: const Color(0xFF151821),
                          child: _previewReady
                              ? (_isDesktop
                                  ? const _SgtpPreviewWidget()
                                  : _MobilePreviewWidget(
                                      controller: _mobileController!))
                              : Center(
                                  child: _initializing
                                      ? const CircularProgressIndicator()
                                      : Text(
                                          _error ?? 'Camera unavailable',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                              color: Colors.white70),
                                        ),
                                ),
                        ),
                      ),
                      if (_isProcessing)
                        Container(
                          decoration: const BoxDecoration(
                              color: Color(0x9906070A),
                              shape: BoxShape.circle),
                          child: const Padding(
                            padding: EdgeInsets.all(28),
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 6,
                            color: const Color(0xFFFF453A),
                            backgroundColor: Colors.transparent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: _isProcessing
                        ? null
                        : (_isRecording ? _stopAndPrepare : _startRecording),
                    child: Container(
                      width: 86,
                      height: 86,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isRecording
                            ? const Color(0xFFFF453A)
                            : const Color(0xFF0A84FF),
                      ),
                      child: Icon(
                        _isRecording
                            ? Icons.stop_rounded
                            : Icons.fiber_manual_record,
                        color: Colors.white,
                        size: _isRecording ? 38 : 44,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Desktop preview — RGBA stream from GStreamer via SgtpCamera
// ---------------------------------------------------------------------------

class _SgtpPreviewWidget extends StatefulWidget {
  const _SgtpPreviewWidget();

  @override
  State<_SgtpPreviewWidget> createState() => _SgtpPreviewWidgetState();
}

class _SgtpPreviewWidgetState extends State<_SgtpPreviewWidget> {
  ui.Image? _image;
  StreamSubscription<CameraFrame>? _sub;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _sub = SgtpCamera.previewStream.listen(_onFrame);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _onFrame(CameraFrame frame) {
    if (_decoding) return; // skip if still decoding previous frame
    _decoding = true;
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (img) {
        _decoding = false;
        if (!mounted) { img.dispose(); return; }
        setState(() {
          _image?.dispose();
          _image = img;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RawImage(image: img, fit: BoxFit.cover,
        width: double.infinity, height: double.infinity);
  }
}

// ---------------------------------------------------------------------------
// Mobile preview — existing CameraPreview widget
// ---------------------------------------------------------------------------

class _MobilePreviewWidget extends StatelessWidget {
  final CameraController controller;

  const _MobilePreviewWidget({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (!value.isInitialized) return const SizedBox.shrink();
        final baseSize = value.previewSize ?? const Size(1, 1);
        final isLandscape =
            value.deviceOrientation == DeviceOrientation.landscapeLeft ||
            value.deviceOrientation == DeviceOrientation.landscapeRight;
        final previewSize =
            isLandscape ? baseSize : Size(baseSize.height, baseSize.width);
        return LayoutBuilder(builder: (context, constraints) {
          final viewport = constraints.biggest;
          if (!viewport.width.isFinite || viewport.isEmpty) {
            return const SizedBox.shrink();
          }
          final scale = math.max(
            viewport.width / previewSize.width,
            viewport.height / previewSize.height,
          );
          return Center(
            child: SizedBox(
              width: previewSize.width * scale,
              height: previewSize.height * scale,
              child: CameraPreview(controller),
            ),
          );
        });
      },
    );
  }
}
