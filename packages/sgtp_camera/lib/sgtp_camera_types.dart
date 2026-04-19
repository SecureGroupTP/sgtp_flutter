import 'dart:typed_data';

class CameraDeviceInfo {
  final String id;
  final String displayName;

  const CameraDeviceInfo({required this.id, required this.displayName});

  @override
  String toString() => displayName;
}

class CameraFrame {
  final Uint8List rgba;
  final int width;
  final int height;
  final int ptsMs;

  const CameraFrame({
    required this.rgba,
    required this.width,
    required this.height,
    required this.ptsMs,
  });
}
