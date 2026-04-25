import 'dart:convert';
import 'dart:typed_data';

Uint8List decodeEventBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  if (value is List) {
    try {
      return Uint8List.fromList(value.map((e) => (e as num).toInt()).toList());
    } catch (_) {
      return Uint8List(0);
    }
  }
  if (value is String) {
    if (value.isEmpty) return Uint8List(0);
    try {
      return Uint8List.fromList(base64.decode(value));
    } catch (_) {
      return Uint8List(0);
    }
  }
  return Uint8List(0);
}
