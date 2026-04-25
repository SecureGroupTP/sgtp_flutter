import 'dart:async';
import 'dart:typed_data';

enum AppNotificationButtonColor {
  defaultColor,
  red,
}

typedef AppNotificationButtonCallback = FutureOr<void> Function();

class AppNotificationButton {
  const AppNotificationButton({
    required this.label,
    this.color = AppNotificationButtonColor.defaultColor,
    required this.onPressed,
  });

  final String label;
  final AppNotificationButtonColor color;
  final AppNotificationButtonCallback onPressed;
}

class AppNotificationRequest {
  const AppNotificationRequest({
    this.imageBytes,
    this.title,
    this.subtitle,
    this.buttons = const <AppNotificationButton>[],
    this.desktopDuration,
    this.mobileDuration,
  });

  final Uint8List? imageBytes;
  final String? title;
  final String? subtitle;
  final List<AppNotificationButton> buttons;
  final Duration? desktopDuration;
  final Duration? mobileDuration;
}

enum AppNotificationEventType {
  actionInvoked,
  dismissed,
}

class AppNotificationEvent {
  const AppNotificationEvent._({
    required this.type,
    required this.id,
    this.buttonIndex,
  });

  const AppNotificationEvent.actionInvoked({
    required String id,
    required int buttonIndex,
  }) : this._(
         type: AppNotificationEventType.actionInvoked,
         id: id,
         buttonIndex: buttonIndex,
       );

  const AppNotificationEvent.dismissed({required String id})
    : this._(type: AppNotificationEventType.dismissed, id: id);

  final AppNotificationEventType type;
  final String id;
  final int? buttonIndex;
}
