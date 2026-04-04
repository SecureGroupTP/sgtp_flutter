import 'dart:io';
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class VideoNoteCaptureResult {
  final XFile xFile;
  final String mime;

  const VideoNoteCaptureResult({
    required this.xFile,
    required this.mime,
  });
}

/// Full-screen video-note recorder overlay.
/// Shows live circular camera preview (front camera by default),
/// a hold-to-record button, and a swap-camera button.
///
/// Pops with [VideoNoteCaptureResult] on success, or `null` on cancel.
class VideoNoteRecorderPage extends StatefulWidget {
  final String? preferredCameraName;

  /// When set, audio is recorded separately using this microphone and merged
  /// into the final video. Falls back to camera audio if merging fails.
  final InputDevice? preferredMicrophone;

  const VideoNoteRecorderPage({
    super.key,
    this.preferredCameraName,
    this.preferredMicrophone,
  });

  @override
  State<VideoNoteRecorderPage> createState() => _VideoNoteRecorderPageState();
}

class _VideoNoteRecorderPageState extends State<VideoNoteRecorderPage>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _ctrl;
  int _cameraIndex = 0;

  bool _initialising = true;
  bool _recording = false;
  bool _merging = false;
  bool _recordActionInFlight = false;
  String? _initError;
  DateTime? _recordStartAt;

  static const Duration _minRecordDuration = Duration(milliseconds: 400);
  static const Duration _holdIntentThreshold = Duration(milliseconds: 350);

  bool _pointerDown = false;
  bool _toggleMode = false;
  bool _holdIntent = false;
  Timer? _holdIntentTimer;
  bool _pressWasRecording = false;

  // Separate audio recording for mic selection support.
  AudioRecorder? _audioRecorder;
  String? _audioRecordPath;

  bool get _useSeparateMic => !kIsWeb && widget.preferredMicrophone != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_useSeparateMic) {
      _audioRecorder = AudioRecorder();
    }
    _initCamera(selectDefault: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdIntentTimer?.cancel();
    _ctrl?.dispose();
    _audioRecorder?.dispose();
    _cleanupAudioFile();
    super.dispose();
  }

  void _cleanupAudioFile() {
    final p = _audioRecordPath;
    if (p != null && !kIsWeb) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    _audioRecordPath = null;
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

  Future<void> _initCamera({int index = 0, bool selectDefault = false}) async {
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

      int target = index;
      if (selectDefault) {
        // On first launch only: apply preferredCameraName from settings, or
        // fall back to the front camera as a sensible default for video notes.
        final preferred = widget.preferredCameraName;
        if (preferred != null && preferred.isNotEmpty) {
          final prefIdx = cameras.indexWhere((c) => c.name == preferred);
          if (prefIdx >= 0) target = prefIdx;
        } else {
          final frontIdx = cameras
              .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
          target = frontIdx >= 0 ? frontIdx : 0;
        }
        // Explicit swaps (selectDefault == false) always use the given index
        // so the user can freely switch between cameras regardless of settings.
      }
      _cameraIndex = target;

      await _ctrl?.dispose();
      final ctrl = CameraController(
        cameras[target],
        ResolutionPreset.high,
        // When using a separate mic, disable camera audio to avoid conflicts.
        enableAudio: !_useSeparateMic,
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
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        _recording ||
        _recordActionInFlight) {
      return;
    }
    _recordActionInFlight = true;
    try {
      if (ctrl.value.isRecordingVideo) {
        if (mounted) {
          setState(() {
            _recording = true;
            _recordStartAt ??= DateTime.now();
            _toggleMode = true;
          });
        }
        return;
      }
      await ctrl.startVideoRecording();
      // Start separate audio recording immediately after camera.
      if (_useSeparateMic) {
        unawaited(_startAudioRecording());
      }
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recordStartAt = DateTime.now();
        _toggleMode = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start recording: $e')),
        );
      }
    } finally {
      _recordActionInFlight = false;
    }
  }

  Future<void> _startAudioRecording() async {
    final recorder = _audioRecorder;
    if (recorder == null || kIsWeb) return;
    try {
      final tmpDir = await getTemporaryDirectory();
      final path =
          '${tmpDir.path}/vnote_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          device: widget.preferredMicrophone,
        ),
        path: path,
      );
      _audioRecordPath = path;
    } catch (_) {
      // Audio recording failed; merge will be skipped and camera audio used.
      _audioRecordPath = null;
    }
  }

  String _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.m4v')) return 'video/x-m4v';
    return 'video/mp4';
  }

  Future<VideoNoteCaptureResult?> _stopRecording() async {
    final ctrl = _ctrl;
    if (ctrl == null || !_recording || _recordActionInFlight) return null;
    _recordActionInFlight = true;
    try {
      if (!ctrl.value.isRecordingVideo) {
        if (mounted) setState(() => _recording = false);
        return null;
      }
      final xfile = await ctrl.stopVideoRecording();

      // Stop separate audio recording in parallel.
      String? audioPath;
      if (_useSeparateMic) {
        try {
          audioPath = await _audioRecorder?.stop();
        } catch (_) {}
        // Use the path we saved at start (some backends return null on stop).
        audioPath ??= _audioRecordPath;
      }

      final startedAt = _recordStartAt;
      _recordStartAt = null;
      if (mounted) setState(() => _recording = false);

      final elapsed = startedAt == null
          ? Duration.zero
          : DateTime.now().difference(startedAt);
      if (elapsed < _minRecordDuration) {
        await _deleteXFileIfPossible(xfile);
        if (audioPath != null) {
          try {
            await File(audioPath).delete();
          } catch (_) {}
        }
        _audioRecordPath = null;
        if (!mounted) return null;
        HapticFeedback.selectionClick();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hold a bit longer to record')),
        );
        return null;
      }

      final videoLength = await _xFileLength(xfile);
      if (videoLength == null || videoLength == 0) {
        if (audioPath != null) {
          try {
            await File(audioPath).delete();
          } catch (_) {}
        }
        _audioRecordPath = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recorded file is empty')),
          );
        }
        return null;
      }

      // Merge separate audio track into the video.
      if (audioPath != null && await File(audioPath).exists()) {
        if (mounted) setState(() => _merging = true);
        try {
          final merged = await _mergeVideoAudio(
            videoPath: xfile.path,
            audioPath: audioPath,
          );
          if (merged != null) {
            // Clean up originals.
            try {
              await File(xfile.path).delete();
            } catch (_) {}
            try {
              await File(audioPath).delete();
            } catch (_) {}
            _audioRecordPath = null;
            return VideoNoteCaptureResult(
              xFile: XFile(merged),
              mime: 'video/mp4',
            );
          }
        } finally {
          if (mounted) setState(() => _merging = false);
        }
        // Merge failed — fall back to video without the selected mic.
        try {
          await File(audioPath).delete();
        } catch (_) {}
        _audioRecordPath = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not apply selected mic — using default audio.',
              ),
            ),
          );
        }
        // Re-enable camera audio and fall through to return original video.
        // The camera video has no audio since enableAudio was false.
        // For now, return the video-only file.
        return VideoNoteCaptureResult(
          xFile: xfile,
          mime: _mimeForPath(xfile.path),
        );
      }

      return VideoNoteCaptureResult(
        xFile: xfile,
        mime: _mimeForPath(xfile.path),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _merging = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stop recording: $e')),
        );
      }
      return null;
    } finally {
      _recordActionInFlight = false;
    }
  }

  Future<int?> _xFileLength(XFile file) async {
    try {
      return await file.length();
    } catch (_) {
      try {
        return (await file.readAsBytes()).length;
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _deleteXFileIfPossible(XFile file) async {
    if (kIsWeb) return;
    try {
      await File(file.path).delete();
    } catch (_) {}
  }

  static const _mergerChannel =
      MethodChannel('com.example.sgtp_flutter/video_merger');

  /// Merges [videoPath] (video-only) with [audioPath] into a new MP4 file.
  ///
  /// On Android / iOS uses a native platform channel (MediaMuxer /
  /// AVMutableComposition — no extra library required).
  /// On Windows / Linux falls back to a system `ffmpeg` process.
  Future<String?> _mergeVideoAudio({
    required String videoPath,
    required String audioPath,
  }) async {
    if (kIsWeb) return null;
    final tmpDir = await getTemporaryDirectory();
    final outputPath =
        '${tmpDir.path}/vnote_merged_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // --- Native channel (Android / iOS / macOS) ---
    if (!Platform.isWindows && !Platform.isLinux) {
      try {
        final result = await _mergerChannel.invokeMethod<String>(
          'mergeVideoAudio',
          {'videoPath': videoPath, 'audioPath': audioPath, 'outputPath': outputPath},
        );
        if (result != null && await File(result).exists()) return result;
      } catch (_) {}
    }

    // --- System ffmpeg process (Windows / Linux / fallback) ---
    try {
      final result = await Process.run('ffmpeg', [
        '-i', videoPath,
        '-i', audioPath,
        '-map', '0:v:0',
        '-map', '1:a:0',
        '-c:v', 'copy',
        '-c:a', 'aac',
        '-shortest',
        '-y',
        outputPath,
      ]);
      if (result.exitCode == 0 && await File(outputPath).exists()) {
        return outputPath;
      }
    } catch (_) {}

    return null;
  }

  Future<void> _stopAndConfirmSend() async {
    final capture = await _stopRecording();
    if (capture == null || !mounted) return;

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
      Navigator.of(context).pop(capture);
      return;
    }
    await _deleteXFileIfPossible(capture.xFile);
  }

  Future<void> _stopAndDiscardRecording() async {
    try {
      final xfile = await _ctrl?.stopVideoRecording();
      if (xfile != null) {
        await _deleteXFileIfPossible(xfile);
      }
    } catch (_) {}
    // Also stop and discard any separate audio.
    try {
      await _audioRecorder?.stop();
    } catch (_) {}
    _cleanupAudioFile();
  }

  void _cancel() {
    if (_recording) {
      () async {
        await _stopAndDiscardRecording();
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

    if (_holdIntent) {
      _stopAndConfirmSend();
      return;
    }

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
          const ColoredBox(color: Colors.black),

          Center(child: _buildPreview()),

          // Top bar
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
                    _CircleBtn(icon: Icons.close, onTap: _cancel),
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

          // Recording progress ring
          if (_recording)
            Positioned.fill(
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

          // Merging overlay
          if (_merging)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text(
                        'Processing audio…',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Bottom controls
          if (!_merging)
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
                      AnimatedOpacity(
                        opacity: _recording ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 200),
                        child: const Text(
                          'Tap or hold to record',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ),
                      const SizedBox(height: 16),
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
          child: Text(
            _initError!,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final ctrl = _ctrl;
    if (ctrl == null) return const SizedBox.shrink();

    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 240,
          height: 240,
          child: ClipOval(child: _coverCameraPreview(ctrl)),
        ),
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

  Widget _coverCameraPreview(CameraController ctrl) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final preview = CameraPreview(ctrl);
        final previewAspect = ctrl.value.aspectRatio;
        final widgetAspect = size.width / size.height;
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
