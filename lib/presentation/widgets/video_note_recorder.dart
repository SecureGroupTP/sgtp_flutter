import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/video_note_pipeline.dart';
import '../../domain/entities/video_note_metadata.dart';

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

  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;

  bool _initializing = true;
  bool _isRecording = false;
  bool _isProcessing = false;
  String? _error;
  Duration _elapsed = Duration.zero;

  CameraDescription? get _currentCamera =>
      _cameras.isEmpty ? null : _cameras[_cameraIndex];

  bool get _isFrontCamera =>
      _currentCamera?.lensDirection == CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initCamera(selectDefault: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _stopwatch.stop();
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      unawaited(controller.dispose());
      _controller = null;
    } else if (state == AppLifecycleState.resumed && !_isProcessing) {
      unawaited(_initCamera(index: _cameraIndex));
    }
  }

  Future<void> _initCamera({int index = 0, bool selectDefault = false}) async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _error = 'No cameras found';
        });
        return;
      }
      _cameras = cameras;

      var target = index.clamp(0, cameras.length - 1);
      if (selectDefault) {
        final preferredName = widget.preferredCameraName;
        if (preferredName != null && preferredName.isNotEmpty) {
          final preferredIndex =
              cameras.indexWhere((camera) => camera.name == preferredName);
          if (preferredIndex >= 0) {
            target = preferredIndex;
          }
        } else {
          final frontIndex = cameras.indexWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front,
          );
          target = frontIndex >= 0 ? frontIndex : 0;
        }
      }

      await _controller?.dispose();
      final controller = CameraController(
        cameras[target],
        ResolutionPreset.medium,
        enableAudio: true,
        fps: 30,
        videoBitrate: 1200000,
        audioBitrate: 64000,
      );
      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _cameraIndex = target;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Failed to initialize camera: $e';
      });
    }
  }

  Future<void> _swapCamera() async {
    if (_isRecording || _isProcessing || _cameras.length < 2) return;
    final next = (_cameraIndex + 1) % _cameras.length;
    await _initCamera(index: next);
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isRecording ||
        _isProcessing) {
      return;
    }
    try {
      await controller.startVideoRecording();
      HapticFeedback.mediumImpact();
      _stopwatch
        ..reset()
        ..start();
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        final elapsed = _stopwatch.elapsed;
        if (elapsed >= _maxDuration) {
          unawaited(_stopAndPrepare());
          return;
        }
        setState(() => _elapsed = elapsed);
      });
      setState(() {
        _isRecording = true;
        _elapsed = Duration.zero;
      });
    } catch (e) {
      _showSnack('Failed to start recording: $e');
    }
  }

  Future<void> _stopAndPrepare() async {
    final controller = _controller;
    if (controller == null || !_isRecording || _isProcessing) return;

    _ticker?.cancel();
    _stopwatch.stop();
    final elapsed = _stopwatch.elapsed;

    try {
      setState(() {
        _isProcessing = true;
        _isRecording = false;
        _elapsed = elapsed;
      });
      final recorded = await controller.stopVideoRecording();
      if (elapsed < _minDuration) {
        await _deleteFile(recorded.path);
        if (!mounted) return;
        setState(() => _isProcessing = false);
        _showSnack('Hold a bit longer to record');
        return;
      }

      final prepared = await VideoNotePipeline.prepare(
        sourceFile: recorded,
        isFrontCamera: _isFrontCamera,
        hasAudio: true,
      );
      await _deleteFile(recorded.path);

      if (!mounted) return;
      setState(() => _isProcessing = false);
      Navigator.of(context).pop(
        VideoNoteCaptureResult(
          xFile: prepared.xFile,
          mime: prepared.mime,
          metadata: prepared.metadata,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _isRecording = false;
      });
      _showSnack('Failed to finalize video note: $e');
    }
  }

  Future<void> _cancel() async {
    if (_isRecording) {
      try {
        final file = await _controller?.stopVideoRecording();
        if (file != null) {
          await _deleteFile(file.path);
        }
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop(null);
  }

  Future<void> _deleteFile(String path) async {
    if (kIsWeb || path.isEmpty) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _format(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final previewReady = controller != null && controller.value.isInitialized;
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
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed:
                        (_isProcessing || _isRecording || _cameras.length < 2)
                            ? null
                            : _swapCamera,
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
                          child: previewReady
                              ? Transform(
                                  alignment: Alignment.center,
                                  transform:
                                      (_isFrontCamera && Platform.isWindows)
                                          ? Matrix4.diagonal3Values(
                                              -1.0,
                                              1.0,
                                              1.0,
                                            )
                                          : Matrix4.identity(),
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: controller
                                              .value.previewSize?.height ??
                                          1,
                                      height:
                                          controller.value.previewSize?.width ??
                                              1,
                                      child: CameraPreview(controller),
                                    ),
                                  ),
                                )
                              : Center(
                                  child: _initializing
                                      ? const CircularProgressIndicator()
                                      : Text(
                                          _error ?? 'Camera unavailable',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                ),
                        ),
                      ),
                      if (_isProcessing)
                        Container(
                          decoration: const BoxDecoration(
                            color: Color(0x9906070A),
                            shape: BoxShape.circle,
                          ),
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
