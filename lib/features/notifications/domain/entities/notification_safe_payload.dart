import 'dart:typed_data';

class NotificationSafePayload {
  const NotificationSafePayload({
    required this.title,
    this.body,
    this.avatarBytes,
  });

  final String title;
  final String? body;
  final Uint8List? avatarBytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'body': body,
        'avatarBytes': avatarBytes,
      };
}
