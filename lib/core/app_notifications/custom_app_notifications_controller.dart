import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/linux_notification_settings.dart';

typedef CustomNotificationTapCallback = FutureOr<void> Function();

class CustomAppNotificationEntry {
  const CustomAppNotificationEntry({
    required this.id,
    required this.title,
    required this.body,
    required this.initials,
    required this.createdAt,
    required this.duration,
    required this.position,
    required this.showAvatar,
    this.avatarBytes,
    this.onTap,
    this.actions = const <AppNotificationButton>[],
  });

  final String id;
  final String title;
  final String? body;
  final String initials;
  final DateTime createdAt;
  final Duration duration;
  final LinuxCustomNotificationPosition position;
  final bool showAvatar;
  final Uint8List? avatarBytes;
  final CustomNotificationTapCallback? onTap;
  final List<AppNotificationButton> actions;
}

class CustomAppNotificationsController extends ChangeNotifier {
  final List<CustomAppNotificationEntry> _visible =
      <CustomAppNotificationEntry>[];
  final Queue<CustomAppNotificationEntry> _queue =
      Queue<CustomAppNotificationEntry>();
  final Map<String, Timer> _timers = <String, Timer>{};
  LinuxNotificationSettings _settings = const LinuxNotificationSettings();

  List<CustomAppNotificationEntry> get visible =>
      List<CustomAppNotificationEntry>.unmodifiable(_visible);
  LinuxNotificationSettings get settings => _settings;

  Future<void> configure(LinuxNotificationSettings settings) async {
    _settings = settings;
    _rebalance();
  }

  Future<void> show(CustomAppNotificationEntry entry) async {
    _removeById(entry.id, notify: false);
    _queue.removeWhere((item) => item.id == entry.id);
    if (_visible.length >= _settings.maxVisibleCustomNotifications) {
      _queue.addLast(entry);
      notifyListeners();
      return;
    }
    _visible.add(entry);
    _armTimer(entry);
    notifyListeners();
  }

  Future<void> dismiss(String id) async {
    final changed = _removeById(id, notify: false);
    if (changed) {
      _promoteQueued();
      notifyListeners();
    }
  }

  Future<void> dismissAll() async {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _visible.clear();
    _queue.clear();
    notifyListeners();
  }

  Future<void> invokeTap(CustomAppNotificationEntry entry) async {
    final callback = entry.onTap;
    if (callback != null) {
      await Future<void>.sync(callback);
    }
    await dismiss(entry.id);
  }

  Future<void> invokeAction(
    CustomAppNotificationEntry entry,
    int actionIndex,
  ) async {
    if (actionIndex < 0 || actionIndex >= entry.actions.length) {
      return;
    }
    await Future<void>.sync(entry.actions[actionIndex].onPressed);
    await dismiss(entry.id);
  }

  void _rebalance() {
    while (_visible.length > _settings.maxVisibleCustomNotifications) {
      final overflow = _visible.removeLast();
      _timers.remove(overflow.id)?.cancel();
      _queue.addFirst(overflow);
    }
    _promoteQueued();
    notifyListeners();
  }

  bool _removeById(String id, {required bool notify}) {
    final index = _visible.indexWhere((item) => item.id == id);
    if (index >= 0) {
      _visible.removeAt(index);
      _timers.remove(id)?.cancel();
      if (notify) {
        notifyListeners();
      }
      return true;
    }
    final beforeLength = _queue.length;
    _queue.removeWhere((item) => item.id == id);
    final removedQueued = _queue.length != beforeLength;
    if (removedQueued && notify) {
      notifyListeners();
    }
    return removedQueued;
  }

  void _promoteQueued() {
    while (_visible.length < _settings.maxVisibleCustomNotifications &&
        _queue.isNotEmpty) {
      final next = _queue.removeFirst();
      _visible.add(next);
      _armTimer(next);
    }
  }

  void _armTimer(CustomAppNotificationEntry entry) {
    _timers[entry.id]?.cancel();
    _timers[entry.id] = Timer(entry.duration, () {
      unawaited(dismiss(entry.id));
    });
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
