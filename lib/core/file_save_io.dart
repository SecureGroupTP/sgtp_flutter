import 'dart:io';
import 'dart:typed_data';

Future<bool> saveBytesToPath(String path, Uint8List bytes) async {
  final file = File(path);
  await file.writeAsBytes(bytes, flush: true);
  return true;
}
