import 'dart:typed_data';

import 'file_save_stub.dart' if (dart.library.io) 'file_save_io.dart' as impl;

Future<bool> saveBytesToPath(String path, Uint8List bytes) {
  return impl.saveBytesToPath(path, bytes);
}
