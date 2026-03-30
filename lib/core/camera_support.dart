import 'package:flutter/foundation.dart';

/// Returns true if the camera is available at all on this platform.
bool get isCameraSupported => true;

/// Returns true if the camera supports continuous image streaming (for ReaderWidget).
bool get cameraSupportsStreaming => true;

/// Human-readable reason why camera is not supported, or null if it is.
String? get cameraUnsupportedReason => null;
