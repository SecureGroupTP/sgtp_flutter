import 'dart:async';

import 'sgtp_camera_types.dart';

class SgtpCamera {
  static final StreamController<CameraFrame> _frameCtrl =
      StreamController<CameraFrame>.broadcast();
  static final StreamController<String> _errorCtrl =
      StreamController<String>.broadcast();

  static Stream<CameraFrame> get previewStream => _frameCtrl.stream;
  static Stream<String> get errorStream => _errorCtrl.stream;

  static void init() {}

  static void deinit() {}

  static List<CameraDeviceInfo> enumerate() => const <CameraDeviceInfo>[];

  static int open({
    String? deviceId,
    int previewWidth = 480,
    int previewHeight = 480,
  }) {
    return -1;
  }

  static void close() {}

  static int startRecording({
    required String outputPath,
    int targetSize = 480,
    int videoKbps = 1000,
    int audioKbps = 64,
  }) {
    throw UnsupportedError('SgtpCamera is not supported on this platform');
  }

  static int stopRecording() => 0;

  static bool get isRecording => false;
}
