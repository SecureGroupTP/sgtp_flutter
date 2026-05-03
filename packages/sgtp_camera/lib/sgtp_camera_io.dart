import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'sgtp_camera_types.dart';

typedef _FrameCallbackNative = Void Function(
  Pointer<Uint8> rgba,
  Int32 width,
  Int32 height,
  Int64 ptsMs,
);
typedef _ErrorCallbackNative = Void Function(Pointer<Utf8> message);

typedef _InitNative = Void Function();
typedef _DeinitNative = Void Function();
typedef _EnumerateNative = Int32 Function(Pointer<_NativeDeviceInfo>, Int32);
typedef _OpenNative = Int32 Function(
  Pointer<Utf8>,
  Int32,
  Int32,
  Pointer<NativeFunction<_FrameCallbackNative>>,
  Pointer<NativeFunction<_ErrorCallbackNative>>,
);
typedef _CloseNative = Void Function();
typedef _StartRecNative = Int32 Function(Pointer<Utf8>, Int32, Int32, Int32);
typedef _StopRecNative = Int64 Function();
typedef _IsRecordingNative = Int32 Function();

final class _NativeDeviceInfo extends Struct {
  @Array(256)
  external Array<Uint8> id;

  @Array(256)
  external Array<Uint8> displayName;
}

DynamicLibrary _loadLib() {
  if (Platform.isWindows) return DynamicLibrary.open('sgtp_camera.dll');
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('sgtp_camera.framework/sgtp_camera');
  }
  return DynamicLibrary.open('libsgtp_camera.so');
}

final DynamicLibrary _lib = _loadLib();

final void Function() _nativeInit =
    _lib.lookupFunction<_InitNative, void Function()>('sgtp_camera_init');
final void Function() _nativeDeinit =
    _lib.lookupFunction<_DeinitNative, void Function()>('sgtp_camera_deinit');
final int Function(Pointer<_NativeDeviceInfo>, int) _nativeEnumerate =
    _lib.lookupFunction<_EnumerateNative,
        int Function(Pointer<_NativeDeviceInfo>, int)>('sgtp_camera_enumerate');
final int Function(
  Pointer<Utf8>,
  int,
  int,
  Pointer<NativeFunction<_FrameCallbackNative>>,
  Pointer<NativeFunction<_ErrorCallbackNative>>,
) _nativeOpen = _lib.lookupFunction<
    _OpenNative,
    int Function(
      Pointer<Utf8>,
      int,
      int,
      Pointer<NativeFunction<_FrameCallbackNative>>,
      Pointer<NativeFunction<_ErrorCallbackNative>>,
    )>('sgtp_camera_open');
final void Function() _nativeClose =
    _lib.lookupFunction<_CloseNative, void Function()>('sgtp_camera_close');
final int Function(Pointer<Utf8>, int, int, int) _nativeStartRec =
    _lib.lookupFunction<_StartRecNative,
        int Function(Pointer<Utf8>, int, int, int)>(
      'sgtp_camera_start_recording',
    );
final int Function() _nativeStopRec =
    _lib.lookupFunction<_StopRecNative, int Function()>(
      'sgtp_camera_stop_recording',
    );
final int Function() _nativeIsRec =
    _lib.lookupFunction<_IsRecordingNative, int Function()>(
      'sgtp_camera_is_recording',
    );

class SgtpCamera {
  static bool _initialised = false;

  static final StreamController<CameraFrame> _frameCtrl =
      StreamController<CameraFrame>.broadcast();
  static Stream<CameraFrame> get previewStream => _frameCtrl.stream;

  static final StreamController<String> _errorCtrl =
      StreamController<String>.broadcast();
  static Stream<String> get errorStream => _errorCtrl.stream;

  static NativeCallable<_FrameCallbackNative>? _frameCb;
  static NativeCallable<_ErrorCallbackNative>? _errorCb;

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

  static List<CameraDeviceInfo> enumerate() {
    const max = 16;
    final Pointer<_NativeDeviceInfo> buf = calloc<_NativeDeviceInfo>(max);
    try {
      final int count = _nativeEnumerate(buf, max);
      final List<CameraDeviceInfo> result = <CameraDeviceInfo>[];
      for (var i = 0; i < count; i++) {
        final info = buf[i];
        result.add(
          CameraDeviceInfo(
            id: _arrayToString(info.id),
            displayName: _arrayToString(info.displayName),
          ),
        );
      }
      return result;
    } finally {
      calloc.free(buf);
    }
  }

  static int open({
    String? deviceId,
    int previewWidth = 480,
    int previewHeight = 480,
  }) {
    _frameCb?.close();
    _frameCb = NativeCallable<_FrameCallbackNative>.listener((
      Pointer<Uint8> rgba,
      int w,
      int h,
      int ptsMs,
    ) {
      final bytes = Uint8List.fromList(rgba.asTypedList(w * h * 4));
      _frameCtrl.add(
        CameraFrame(rgba: bytes, width: w, height: h, ptsMs: ptsMs),
      );
    });

    _errorCb?.close();
    _errorCb = NativeCallable<_ErrorCallbackNative>.listener((
      Pointer<Utf8> msg,
    ) {
      String text;
      try {
        text = msg.toDartString();
      } on FormatException {
        final bytes = <int>[];
        for (var i = 0; ; i++) {
          final b = msg.cast<Uint8>().elementAt(i).value;
          if (b == 0) break;
          bytes.add(b);
        }
        text = latin1.decode(bytes);
      }
      _errorCtrl.add(text);
    });

    final Pointer<Utf8> devPtr =
        deviceId != null ? deviceId.toNativeUtf8() : nullptr.cast<Utf8>();
    try {
      return _nativeOpen(
        devPtr,
        previewWidth,
        previewHeight,
        _frameCb!.nativeFunction,
        _errorCb!.nativeFunction,
      );
    } finally {
      if (deviceId != null) {
        calloc.free(devPtr);
      }
    }
  }

  static void close() {
    _nativeClose();
    _frameCb?.close();
    _frameCb = null;
    _errorCb?.close();
    _errorCb = null;
  }

  static int startRecording({
    required String outputPath,
    int targetSize = 480,
    int videoKbps = 1000,
    int audioKbps = 64,
  }) {
    final Pointer<Utf8> pathPtr = outputPath.toNativeUtf8();
    try {
      return _nativeStartRec(pathPtr, targetSize, videoKbps, audioKbps);
    } finally {
      calloc.free(pathPtr);
    }
  }

  static int stopRecording() => _nativeStopRec();

  static bool get isRecording => _nativeIsRec() != 0;

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
