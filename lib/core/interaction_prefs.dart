import 'package:shared_preferences/shared_preferences.dart';

/// Persisted per-user interaction preferences for message gestures.
///
/// Desktop defaults:
///   double-click  → react picker
///   right-click   → context menu (react + reply)
///   (no swipe on desktop)
///
/// Mobile defaults:
///   double-tap    → react picker
///   long-press    → context menu (react + reply)
///   swipe-right   → reply
class InteractionPrefs {
  InteractionPrefs._();

  // Keys
  static const _kDoubleTapDesktop = 'iprefs_doubletap_desktop'; // 'react' | 'reply'
  static const _kSwipeToReply     = 'iprefs_swipe_to_reply';   // bool
  static const _kLongPressMenu    = 'iprefs_longpress_menu';   // bool (mobile: show menu vs direct react)

  /// Double-tap on desktop: 'react' opens picker, 'reply' sets reply. Default: 'react'.
  static String doubleTapDesktop = 'react';

  /// Swipe right to reply on mobile. Default: true.
  static bool swipeToReply = true;

  /// Long-press shows full context menu (react + reply). Default: true.
  /// If false, long-press goes directly to react picker.
  static bool longPressShowsMenu = true;

  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    doubleTapDesktop  = p.getString(_kDoubleTapDesktop) ?? 'react';
    swipeToReply      = p.getBool(_kSwipeToReply)       ?? true;
    longPressShowsMenu = p.getBool(_kLongPressMenu)     ?? true;
  }

  static Future<void> setDoubleTapDesktop(String value) async {
    doubleTapDesktop = value;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDoubleTapDesktop, value);
  }

  static Future<void> setSwipeToReply(bool value) async {
    swipeToReply = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSwipeToReply, value);
  }

  static Future<void> setLongPressShowsMenu(bool value) async {
    longPressShowsMenu = value;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kLongPressMenu, value);
  }
}
