import 'dart:typed_data';

class AppNotificationRequest {
  const AppNotificationRequest({
    this.imageBytes,
    this.title,
    this.subtitle,
    required this.duration,
  });

  final Uint8List? imageBytes;
  final String? title;
  final String? subtitle;
  final Duration duration;
}
