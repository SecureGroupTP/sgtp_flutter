#ifndef RUNNER_APP_NOTIFICATION_MANAGER_H_
#define RUNNER_APP_NOTIFICATION_MANAGER_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

namespace flutter {
class BinaryMessenger;
}

class AppNotificationManager {
 public:
  explicit AppNotificationManager(flutter::BinaryMessenger* messenger);
  ~AppNotificationManager();

  static LRESULT CALLBACK WndProc(HWND hwnd,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam);

 private:
  struct NotificationItem;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool EnsureWindow();
  void ShowNotification(const flutter::EncodableMap& arguments);
  void DismissNotification(const std::string& id);
  void DismissAllNotifications();
  void Tick();
  void RenderWindow();
  void UpdateWindowBounds();
  void RemoveExpiredNotifications();
  LRESULT HandleWindowMessage(HWND hwnd,
                              UINT message,
                              WPARAM wparam,
                              LPARAM lparam);

  HWND window_ = nullptr;
  UINT current_dpi_ = 96;
  ULONG_PTR gdiplus_token_ = 0;
  UINT_PTR timer_id_ = 0;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<std::unique_ptr<NotificationItem>> notifications_;
  std::vector<std::unique_ptr<NotificationItem>> pending_notifications_;
};

#endif  // RUNNER_APP_NOTIFICATION_MANAGER_H_
