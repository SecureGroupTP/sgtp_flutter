import 'dart:typed_data';

class NotificationSafePayload {
  const NotificationSafePayload({
    required this.title,
    this.subtitle,
    this.avatarBytes,
  });

  final String title;
  final String? subtitle;
  final Uint8List? avatarBytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'subtitle': subtitle,
        'avatarBytes': avatarBytes,
      };
}
