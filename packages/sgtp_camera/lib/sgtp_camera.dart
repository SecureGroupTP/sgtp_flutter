import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Native bindings
// ---------------------------------------------------------------------------

typedef _FrameCallbackNative = Void Function(
    Pointer<Uint8> rgba, Int32 width, Int32 height, Int64 ptsMs);
typedef _ErrorCallbackNative = Void Function(Pointer<Utf8> message);

typedef _InitNative        = Void Function();
typedef _DeinitNative      = Void Function();
typedef _EnumerateNative   = Int32 Function(Pointer<_NativeDeviceInfo>, Int32);
typedef _OpenNative        = Int32 Function(
    Pointer<Utf8>, Int32, Int32,
    Pointer<NativeFunction<_FrameCallbackNative>>,
    Pointer<NativeFunction<_ErrorCallbackNative>>);
typedef _CloseNative       = Void Function();
typedef _StartRecNative    = Int32 Function(Pointer<Utf8>, Int32, Int32, Int32);
typedef _StopRecNative     = Int64 Function();
typedef _IsRecordingNative = Int32 Function();

// matches SgtpDeviceInfo in C (256 + 256 bytes)
final class _NativeDeviceInfo extends Struct {
  @Array(256)
  external Array<Uint8> id;
  @Array(256)
  external Array<Uint8> displayName;
}

DynamicLibrary _loadLib() {
  if (Platform.isWindows) return DynamicLibrary.open('sgtp_camera.dll');
  if (Platform.isMacOS)   return DynamicLibrary.open('libsgtp_camera.dylib');
  if (Platform.isIOS)     return DynamicLibrary.process();
  return DynamicLibrary.open('libsgtp_camera.so');
}

final _lib = _loadLib();

final _nativeInit     = _lib.lookupFunction<_InitNative,        void Function()>('sgtp_camera_init');
final _nativeDeinit   = _lib.lookupFunction<_DeinitNative,      void Function()>('sgtp_camera_deinit');
final _nativeEnumerate= _lib.lookupFunction<_EnumerateNative,   int Function(Pointer<_NativeDeviceInfo>, int)>('sgtp_camera_enumerate');
final _nativeOpen     = _lib.lookupFunction<_OpenNative,        int Function(Pointer<Utf8>, int, int, Pointer<NativeFunction<_FrameCallbackNative>>, Pointer<NativeFunction<_ErrorCallbackNative>>)>('sgtp_camera_open');
final _nativeClose    = _lib.lookupFunction<_CloseNative,       void Function()>('sgtp_camera_close');
final _nativeStartRec = _lib.lookupFunction<_StartRecNative,    int Function(Pointer<Utf8>, int, int, int)>('sgtp_camera_start_recording');
final _nativeStopRec  = _lib.lookupFunction<_StopRecNative,     int Function()>('sgtp_camera_stop_recording');
final _nativeIsRec    = _lib.lookupFunction<_IsRecordingNative, int Function()>('sgtp_camera_is_recording');

// ---------------------------------------------------------------------------
// Public data types
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// SgtpCamera
// ---------------------------------------------------------------------------

class SgtpCamera {
  static bool _initialised = false;

  // Preview frames stream
  static final _frameCtrl = StreamController<CameraFrame>.broadcast();
  static Stream<CameraFrame> get previewStream => _frameCtrl.stream;

  // Error stream
  static final _errorCtrl = StreamController<String>.broadcast();
  static Stream<String> get errorStream => _errorCtrl.stream;

  // Native callables (kept alive as long as camera is open)
  static NativeCallable<_FrameCallbackNative>? _frameCb;
  static NativeCallable<_ErrorCallbackNative>? _errorCb;

  // ---------------------------------------------------------------------------

  static void init() {
    if (_initialised) return;
    _nativeInit();
    _initialised = true;
  }

  static void deinit() {
    if (!_initialised) return;
    _nativeDeinit();
    _frameCb?.close();
    _frameCb = null;
    _errorCb?.close();
    _errorCb = null;
    _initialised = false;
  }

  // ---------------------------------------------------------------------------

  static List<CameraDeviceInfo> enumerate() {
    const max = 16;
    final buf = calloc<_NativeDeviceInfo>(max);
    try {
      final count = _nativeEnumerate(buf, max);
      final result = <CameraDeviceInfo>[];
      for (var i = 0; i < count; i++) {
        final info = buf[i];
        result.add(CameraDeviceInfo(
          id:          _arrayToString(info.id),
          displayName: _arrayToString(info.displayName),
        ));
      }
      return result;
    } finally {
      calloc.free(buf);
    }
  }

  // ---------------------------------------------------------------------------

  /// Open the camera and start delivering frames to [previewStream].
  /// [deviceId]: from [enumerate], or null for default device.
  /// [previewWidth]/[previewHeight]: frame size for preview.
  static int open({
    String? deviceId,
    int previewWidth  = 480,
    int previewHeight = 480,
  }) {
    // Frame callback — called from GStreamer thread via listener port.
    _frameCb?.close();
    _frameCb = NativeCallable<_FrameCallbackNative>.listener(
      (Pointer<Uint8> rgba, int w, int h, int ptsMs) {
        final bytes = Uint8List.fromList(rgba.asTypedList(w * h * 4));
        _frameCtrl.add(CameraFrame(rgba: bytes, width: w, height: h, ptsMs: ptsMs));
      },
    );

    // Error callback
    _errorCb?.close();
    _errorCb = NativeCallable<_ErrorCallbackNative>.listener(
      (Pointer<Utf8> msg) {
        String text;
        try {
          text = msg.toDartString();
        } on FormatException {
          // GStreamer on Windows may return messages in the system locale
          // encoding rather than UTF-8 — fall back to Latin-1.
          final bytes = <int>[];
          for (var i = 0; ; i++) {
            final b = msg.cast<Uint8>().elementAt(i).value;
            if (b == 0) break;
            bytes.add(b);
          }
          text = latin1.decode(bytes);
        }
        _errorCtrl.add(text);
      },
    );

    final devPtr = deviceId != null ? deviceId.toNativeUtf8() : nullptr.cast<Utf8>();
    try {
      return _nativeOpen(
        devPtr,
        previewWidth,
        previewHeight,
        _frameCb!.nativeFunction,
        _errorCb!.nativeFunction,
      );
    } finally {
      if (deviceId != null) calloc.free(devPtr);
    }
  }

  static void close() {
    _nativeClose();
    _frameCb?.close();
    _frameCb = null;
    _errorCb?.close();
    _errorCb = null;
  }

  // ---------------------------------------------------------------------------

  static int startRecording({
    required String outputPath,
    int targetSize = 480,
    int videoKbps  = 1000,
    int audioKbps  = 64,
  }) {
    final pathPtr = outputPath.toNativeUtf8();
    try {
      return _nativeStartRec(pathPtr, targetSize, videoKbps, audioKbps);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Stops recording and returns the duration in milliseconds.
  static int stopRecording() => _nativeStopRec();

  static bool get isRecording => _nativeIsRec() != 0;

  // ---------------------------------------------------------------------------

  static String _arrayToString(Array<Uint8> arr) {
    final buf = StringBuffer();
    for (var i = 0; i < 256; i++) {
      final c = arr[i];
      if (c == 0) break;
      buf.writeCharCode(c);
    }
    return buf.toString();
  }
}
