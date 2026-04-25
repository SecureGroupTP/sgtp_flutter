enum LinuxNotificationMode {
  native,
  custom,
}

enum LinuxCustomNotificationPosition {
  topRight,
  bottomRight,
  topLeft,
  bottomLeft,
}

class LinuxNotificationSettings {
  const LinuxNotificationSettings({
    this.enabled = true,
    this.mode = LinuxNotificationMode.native,
    this.customDurationSeconds = 6,
    this.position = LinuxCustomNotificationPosition.topRight,
    this.maxVisibleCustomNotifications = 3,
    this.showMessagePreview = true,
    this.showAvatars = true,
  });

  final bool enabled;
  final LinuxNotificationMode mode;
  final int customDurationSeconds;
  final LinuxCustomNotificationPosition position;
  final int maxVisibleCustomNotifications;
  final bool showMessagePreview;
  final bool showAvatars;

  Duration get customDuration => Duration(
        seconds: customDurationSeconds.clamp(2, 30),
      );

  LinuxNotificationSettings copyWith({
    bool? enabled,
    LinuxNotificationMode? mode,
    int? customDurationSeconds,
    LinuxCustomNotificationPosition? position,
    int? maxVisibleCustomNotifications,
    bool? showMessagePreview,
    bool? showAvatars,
  }) {
    return LinuxNotificationSettings(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      customDurationSeconds:
          customDurationSeconds ?? this.customDurationSeconds,
      position: position ?? this.position,
      maxVisibleCustomNotifications:
          maxVisibleCustomNotifications ?? this.maxVisibleCustomNotifications,
      showMessagePreview: showMessagePreview ?? this.showMessagePreview,
      showAvatars: showAvatars ?? this.showAvatars,
    );
  }
}
