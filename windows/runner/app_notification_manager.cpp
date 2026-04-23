#include "app_notification_manager.h"

#include <flutter/encodable_value.h>
#include <gdiplus.h>
#include <objidl.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kNotificationWindowClassName[] =
    L"SGTP_APP_NOTIFICATION_WINDOW";
constexpr wchar_t kNotificationWindowTitle[] = L"SGTP App Notifications";
constexpr wchar_t kAppLabel[] = L"SGTP";
constexpr wchar_t kNowLabel[] = L"now";
constexpr float kNotificationUiScale = 0.8f;

constexpr int kWindowWidth = 432;
constexpr int kCardHeightImageButtons = 168;
constexpr int kCardHeightImageNoButtons = 140;
constexpr int kCardHeightNoImageButtons = 122;
constexpr int kCardHeightNoImageNoButtons = 98;
constexpr int kMaxCardHeight = kCardHeightImageButtons;
constexpr int kCardSpacing = 12;
constexpr int kStackStep = kMaxCardHeight + kCardSpacing;
constexpr int kRolloverStackStep = 94;
constexpr int kMaxVisibleNotifications = 3;
constexpr int kPadding = 12;
constexpr int kMaxButtons = 2;
constexpr int kMaxStackHeight =
    (kPadding * 2) + (kMaxCardHeight * kMaxVisibleNotifications) +
    (kCardSpacing * (kMaxVisibleNotifications - 1));
constexpr int kCornerRadius = 14;
constexpr int kFadeInMs = 220;
constexpr int kFadeOutMs = 1000;
constexpr double kPositionLerp = 0.24;
constexpr UINT_PTR kAnimationTimerId = 1001;
constexpr UINT kAnimationTimerIntervalMs = 16;

int ScalePx(int value, UINT dpi) {
  const auto scaled_value = static_cast<int>(std::lround(value * kNotificationUiScale));
  return MulDiv(scaled_value, static_cast<int>(dpi), 96);
}

float ScalePx(float value, UINT dpi) {
  return (value * kNotificationUiScale * static_cast<float>(dpi)) / 96.0f;
}

const flutter::EncodableValue* FindMapValue(const flutter::EncodableMap& map,
                                            const char* key) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  if (iterator == map.end()) {
    return nullptr;
  }
  return &iterator->second;
}

std::string ValueToString(const flutter::EncodableValue* value) {
  if (value == nullptr) {
    return std::string();
  }
  if (const auto* string_value = std::get_if<std::string>(value)) {
    return *string_value;
  }
  return std::string();
}

int ValueToInt(const flutter::EncodableValue* value, int fallback) {
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* int_value = std::get_if<int32_t>(value)) {
    return *int_value;
  }
  if (const auto* long_value = std::get_if<int64_t>(value)) {
    return static_cast<int>(*long_value);
  }
  return fallback;
}

const std::vector<uint8_t>* ValueToBytes(const flutter::EncodableValue* value) {
  if (value == nullptr) {
    return nullptr;
  }
  return std::get_if<std::vector<uint8_t>>(value);
}

const flutter::EncodableList* ValueToList(const flutter::EncodableValue* value) {
  if (value == nullptr) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableList>(value);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int wide_length = MultiByteToWideChar(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (wide_length <= 0) {
    return std::wstring();
  }
  std::wstring wide_value(wide_length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      wide_value.data(), wide_length);
  return wide_value;
}

std::unique_ptr<Gdiplus::Image> DecodeImage(
    const std::vector<uint8_t>& bytes) {
  if (bytes.empty()) {
    return nullptr;
  }
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (handle == nullptr) {
    return nullptr;
  }
  void* buffer = GlobalLock(handle);
  if (buffer == nullptr) {
    GlobalFree(handle);
    return nullptr;
  }
  std::memcpy(buffer, bytes.data(), bytes.size());
  GlobalUnlock(handle);

  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(handle, TRUE, &stream) != S_OK) {
    GlobalFree(handle);
    return nullptr;
  }

  auto image = std::make_unique<Gdiplus::Image>(stream);
  stream->Release();
  if (image->GetLastStatus() != Gdiplus::Ok) {
    return nullptr;
  }
  return image;
}

Gdiplus::Color WithAlpha(const Gdiplus::Color& color, double opacity) {
  const auto alpha = static_cast<BYTE>(
      std::clamp(std::lround(255.0 * opacity), 0L, 255L));
  return Gdiplus::Color(alpha, color.GetR(), color.GetG(), color.GetB());
}

void BuildRoundedRect(Gdiplus::GraphicsPath* path,
                      const Gdiplus::RectF& rect,
                      float radius) {
  if (path == nullptr) {
    return;
  }
  const auto diameter = radius * 2.0f;
  path->AddArc(rect.X, rect.Y, diameter, diameter, 180.0f, 90.0f);
  path->AddArc(rect.GetRight() - diameter, rect.Y, diameter, diameter, 270.0f,
               90.0f);
  path->AddArc(rect.GetRight() - diameter, rect.GetBottom() - diameter,
               diameter, diameter, 0.0f, 90.0f);
  path->AddArc(rect.X, rect.GetBottom() - diameter, diameter, diameter, 90.0f,
               90.0f);
  path->CloseFigure();
}

void BuildCirclePath(Gdiplus::GraphicsPath* path, const Gdiplus::RectF& rect) {
  if (path == nullptr) {
    return;
  }
  path->AddEllipse(rect);
  path->CloseFigure();
}

RECT RectFToRect(const Gdiplus::RectF& rect) {
  RECT native_rect{};
  native_rect.left = static_cast<LONG>(std::floor(rect.X));
  native_rect.top = static_cast<LONG>(std::floor(rect.Y));
  native_rect.right = static_cast<LONG>(std::ceil(rect.GetRight()));
  native_rect.bottom = static_cast<LONG>(std::ceil(rect.GetBottom()));
  return native_rect;
}

void DrawClippedImage(Gdiplus::Graphics* graphics,
                      Gdiplus::Image* image,
                      const Gdiplus::RectF& rect,
                      bool circular,
                      double opacity) {
  if (graphics == nullptr || image == nullptr) {
    return;
  }
  const auto state = graphics->Save();
  if (circular) {
    Gdiplus::GraphicsPath clip_path(Gdiplus::FillModeAlternate);
    BuildCirclePath(&clip_path, rect);
    graphics->SetClip(&clip_path);
  } else {
    Gdiplus::GraphicsPath clip_path(Gdiplus::FillModeAlternate);
    BuildRoundedRect(&clip_path, rect, rect.Height * 0.24f);
    graphics->SetClip(&clip_path);
  }
  Gdiplus::ImageAttributes image_attributes;
  Gdiplus::ColorMatrix color_matrix = {
      1.0f, 0.0f, 0.0f, 0.0f, 0.0f,
      0.0f, 1.0f, 0.0f, 0.0f, 0.0f,
      0.0f, 0.0f, 1.0f, 0.0f, 0.0f,
      0.0f, 0.0f, 0.0f, static_cast<Gdiplus::REAL>(opacity), 0.0f,
      0.0f, 0.0f, 0.0f, 0.0f, 1.0f,
  };
  image_attributes.SetColorMatrix(&color_matrix);
  graphics->DrawImage(
      image, rect,
      0.0f, 0.0f,
      static_cast<Gdiplus::REAL>(image->GetWidth()),
      static_cast<Gdiplus::REAL>(image->GetHeight()),
      Gdiplus::UnitPixel, &image_attributes);
  graphics->Restore(state);
}

void DrawHeaderBadge(Gdiplus::Graphics* graphics,
                     const Gdiplus::RectF& rect,
                     double opacity) {
  if (graphics == nullptr) {
    return;
  }
  Gdiplus::GraphicsPath badge_path(Gdiplus::FillModeAlternate);
  BuildRoundedRect(&badge_path, rect, rect.Height * 0.32f);

  Gdiplus::LinearGradientBrush fill(
      rect, WithAlpha(Gdiplus::Color(255, 227, 229, 233), opacity),
      WithAlpha(Gdiplus::Color(255, 109, 109, 116), opacity), 45.0f);
  graphics->FillPath(&fill, &badge_path);

  Gdiplus::RectF highlight_rect(rect.X + rect.Width * 0.08f,
                                rect.Y + rect.Height * 0.05f, rect.Width * 0.7f,
                                rect.Height * 0.55f);
  Gdiplus::SolidBrush highlight(
      WithAlpha(Gdiplus::Color(255, 255, 255, 255), opacity * 0.30));
  graphics->FillEllipse(&highlight, highlight_rect);

  Gdiplus::Pen border(
      WithAlpha(Gdiplus::Color(255, 255, 255, 255), opacity * 0.14), 1.0f);
  graphics->DrawPath(&border, &badge_path);
}

void DrawSoftSpotlight(Gdiplus::Graphics* graphics,
                       const Gdiplus::RectF& ellipse_rect,
                       const Gdiplus::PointF& center_point,
                       const Gdiplus::Color& center_color) {
  if (graphics == nullptr) {
    return;
  }
  Gdiplus::GraphicsPath ellipse_path(Gdiplus::FillModeAlternate);
  ellipse_path.AddEllipse(ellipse_rect);
  Gdiplus::PathGradientBrush brush(&ellipse_path);
  brush.SetCenterPoint(center_point);
  brush.SetCenterColor(center_color);

  const auto transparent =
      Gdiplus::Color(static_cast<BYTE>(0), center_color.GetR(),
                     center_color.GetG(), center_color.GetB());
  INT count = 1;
  brush.SetSurroundColors(&transparent, &count);
  graphics->FillEllipse(&brush, ellipse_rect);
}

int ResolveCardHeight(bool has_image, size_t button_count) {
  if (has_image) {
    return button_count > 0 ? kCardHeightImageButtons : kCardHeightImageNoButtons;
  }
  return button_count > 0 ? kCardHeightNoImageButtons
                          : kCardHeightNoImageNoButtons;
}

void RegisterNotificationWindowClass() {
  static bool registered = false;
  if (registered) {
    return;
  }
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = AppNotificationManager::WndProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kNotificationWindowClassName;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.hbrBackground = nullptr;
  RegisterClassW(&window_class);
  registered = true;
}

}  // namespace

struct AppNotificationManager::NotificationButton {
  std::wstring label;
  bool is_red = false;
  RECT rect{};
};

struct AppNotificationManager::NotificationItem {
  std::string id;
  std::wstring title;
  std::wstring subtitle;
  std::unique_ptr<Gdiplus::Image> image;
  std::vector<NotificationButton> buttons;
  int layout_height = kMaxCardHeight;
  int duration_ms = 5000;
  ULONGLONG created_at_ms = 0;
  ULONGLONG dismiss_started_at_ms = 0;
  bool dismissing = false;
  double opacity = 0.0;
  double current_y = -static_cast<double>(kMaxCardHeight);
  RECT close_rect{};
};

AppNotificationManager::AppNotificationManager(flutter::BinaryMessenger* messenger) {
  Gdiplus::GdiplusStartupInput startup_input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &startup_input, nullptr);

  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.example.sgtp_flutter/app_notifications",
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& method_call, auto result) {
        HandleMethodCall(method_call, std::move(result));
      });
}

AppNotificationManager::~AppNotificationManager() {
  if (timer_id_ != 0 && window_ != nullptr) {
    KillTimer(window_, timer_id_);
  }
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
  if (gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
  }
}

void AppNotificationManager::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method_name = method_call.method_name();
  if (method_name == "showNotification") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_args", "Expected map arguments.");
      return;
    }
    ShowNotification(*arguments);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method_name == "dismissNotification") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments != nullptr) {
      DismissNotification(ValueToString(FindMapValue(*arguments, "id")));
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method_name == "dismissAllNotifications") {
    DismissAllNotifications();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->NotImplemented();
}

bool AppNotificationManager::EnsureWindow() {
  if (window_ != nullptr) {
    return true;
  }
  RegisterNotificationWindowClass();
  window_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
      kNotificationWindowClassName, kNotificationWindowTitle, WS_POPUP, 0, 0,
      kWindowWidth, kMaxStackHeight, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  if (window_ == nullptr) {
    return false;
  }
  current_dpi_ = GetDpiForWindow(window_);
  timer_id_ = SetTimer(window_, kAnimationTimerId, kAnimationTimerIntervalMs,
                       nullptr);
  return true;
}

void AppNotificationManager::ShowNotification(
    const flutter::EncodableMap& arguments) {
  if (!EnsureWindow()) {
    return;
  }

  auto item = std::make_unique<NotificationItem>();
  item->id = ValueToString(FindMapValue(arguments, "id"));
  item->title = Utf8ToWide(ValueToString(FindMapValue(arguments, "title")));
  item->subtitle =
      Utf8ToWide(ValueToString(FindMapValue(arguments, "subtitle")));
  item->duration_ms = std::max(
      1000, ValueToInt(FindMapValue(arguments, "durationMs"), 5000));
  item->created_at_ms = GetTickCount64();

  if (const auto* image_bytes = ValueToBytes(FindMapValue(arguments, "imageBytes"));
      image_bytes != nullptr && !image_bytes->empty()) {
    item->image = DecodeImage(*image_bytes);
  }

  if (const auto* buttons = ValueToList(FindMapValue(arguments, "buttons"));
      buttons != nullptr) {
    for (const auto& entry : *buttons) {
      if (item->buttons.size() >= static_cast<size_t>(kMaxButtons)) {
        break;
      }
      const auto* button_map = std::get_if<flutter::EncodableMap>(&entry);
      if (button_map == nullptr) {
        continue;
      }
      NotificationButton button;
      button.label =
          Utf8ToWide(ValueToString(FindMapValue(*button_map, "label")));
      button.is_red =
          ValueToString(FindMapValue(*button_map, "color")) == "red";
      if (!button.label.empty()) {
        item->buttons.push_back(std::move(button));
      }
    }
  }

  item->layout_height =
      ResolveCardHeight(item->image != nullptr, item->buttons.size());
  item->current_y = -static_cast<double>(item->layout_height);

  notifications_.erase(
      std::remove_if(
          notifications_.begin(), notifications_.end(),
          [&](const auto& existing) { return existing->id == item->id; }),
      notifications_.end());
  pending_notifications_.erase(
      std::remove_if(
          pending_notifications_.begin(), pending_notifications_.end(),
          [&](const auto& existing) { return existing->id == item->id; }),
      pending_notifications_.end());

  if (notifications_.size() >= static_cast<size_t>(kMaxVisibleNotifications)) {
    BeginDismiss(notifications_.back().get());
    pending_notifications_.push_back(std::move(item));
  } else {
    notifications_.insert(notifications_.begin(), std::move(item));
  }

  const auto now = GetTickCount64();
  for (size_t index = static_cast<size_t>(kMaxVisibleNotifications);
       index < notifications_.size();
       index += 1) {
    if (!notifications_[index]->dismissing) {
      notifications_[index]->dismissing = true;
      notifications_[index]->dismiss_started_at_ms = now;
    }
  }

  ShowWindow(window_, SW_SHOWNOACTIVATE);
  UpdateWindowBounds();
  RenderWindow();
}

void AppNotificationManager::DismissNotification(const std::string& id) {
  if (id.empty()) {
    return;
  }
  pending_notifications_.erase(
      std::remove_if(
          pending_notifications_.begin(), pending_notifications_.end(),
          [&](const auto& item) { return item->id == id; }),
      pending_notifications_.end());
  for (auto& item : notifications_) {
    if (item->id == id) {
      BeginDismiss(item.get());
    }
  }
  if (window_ != nullptr) {
    RenderWindow();
  }
}

void AppNotificationManager::DismissAllNotifications() {
  pending_notifications_.clear();
  for (auto& item : notifications_) {
    BeginDismiss(item.get());
  }
  if (window_ != nullptr) {
    RenderWindow();
  }
}

void AppNotificationManager::BeginDismiss(NotificationItem* item) {
  if (item == nullptr || item->dismissing) {
    return;
  }
  item->dismissing = true;
  item->dismiss_started_at_ms = GetTickCount64();
}

void AppNotificationManager::DispatchDismissed(const std::string& id) {
  if (channel_ == nullptr || id.empty()) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
  channel_->InvokeMethod(
      "notificationDismissed",
      std::make_unique<flutter::EncodableValue>(arguments));
}

void AppNotificationManager::DispatchActionInvoked(const std::string& id,
                                                   int button_index) {
  if (channel_ == nullptr || id.empty()) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
  arguments[flutter::EncodableValue("buttonIndex")] =
      flutter::EncodableValue(button_index);
  channel_->InvokeMethod(
      "notificationActionInvoked",
      std::make_unique<flutter::EncodableValue>(arguments));
}

void AppNotificationManager::Tick() {
  if (notifications_.empty()) {
    if (window_ != nullptr) {
      ShowWindow(window_, SW_HIDE);
    }
    return;
  }

  const auto now = GetTickCount64();
  const auto visible_count = static_cast<int>(notifications_.size());
  const bool rollover_mode =
      !pending_notifications_.empty() && visible_count == kMaxVisibleNotifications &&
      notifications_.back()->dismissing;

  std::vector<double> target_positions(notifications_.size(), 0.0);
  if (rollover_mode) {
    const auto bottom_anchor = static_cast<double>(kMaxStackHeight - kPadding);
    for (size_t index = 0; index < notifications_.size(); index += 1) {
      const auto reverse_index =
          static_cast<double>(visible_count - 1 - static_cast<int>(index));
      target_positions[index] =
          bottom_anchor - notifications_[index]->layout_height -
          (reverse_index * static_cast<double>(kRolloverStackStep));
    }
  } else {
    auto total_height = 0.0;
    for (const auto& item : notifications_) {
      total_height += static_cast<double>(item->layout_height);
    }
    if (visible_count > 1) {
      total_height += static_cast<double>((visible_count - 1) * kCardSpacing);
    }
    auto next_y = static_cast<double>(kMaxStackHeight - kPadding) - total_height;
    for (size_t index = 0; index < notifications_.size(); index += 1) {
      target_positions[index] = next_y;
      next_y += notifications_[index]->layout_height + kCardSpacing;
    }
  }

  for (size_t index = 0; index < notifications_.size(); index += 1) {
    auto& item = notifications_[index];
    if (!item->dismissing &&
        now >= item->created_at_ms + static_cast<ULONGLONG>(item->duration_ms)) {
      BeginDismiss(item.get());
    }

    const auto target_y = target_positions[index];
    if (item->dismissing) {
      const auto progress = std::clamp(
          static_cast<double>(now - item->dismiss_started_at_ms) / kFadeOutMs,
          0.0, 1.0);
      item->opacity = 1.0 - progress;
    } else {
      const auto progress = std::clamp(
          static_cast<double>(now - item->created_at_ms) / kFadeInMs, 0.0,
          1.0);
      item->opacity = progress;
      item->current_y += (target_y - item->current_y) * kPositionLerp;
    }
  }

  RemoveExpiredNotifications();
  UpdateWindowBounds();
  if (window_ != nullptr) {
    RenderWindow();
  }
}

void AppNotificationManager::RenderWindow() {
  if (window_ == nullptr) {
    return;
  }
  RECT client_rect{};
  GetClientRect(window_, &client_rect);
  const auto width = client_rect.right - client_rect.left;
  const auto height = client_rect.bottom - client_rect.top;
  if (width <= 0 || height <= 0) {
    return;
  }

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  auto screen_dc = GetDC(nullptr);
  auto memory_dc = CreateCompatibleDC(screen_dc);
  auto bitmap = CreateDIBSection(memory_dc, &bitmap_info, DIB_RGB_COLORS, &bits,
                                 nullptr, 0);
  auto old_bitmap = SelectObject(memory_dc, bitmap);
  std::memset(bits, 0, static_cast<size_t>(width) * height * 4);

  Gdiplus::Bitmap layered_bitmap(
      width, height, width * 4,
      static_cast<Gdiplus::PixelFormat>(PixelFormat32bppPARGB),
      static_cast<BYTE*>(bits));
  Gdiplus::Graphics graphics(&layered_bitmap);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);
  graphics.Clear(Gdiplus::Color(0, 0, 0, 0));

  Gdiplus::FontFamily font_family(L"Segoe UI");
  Gdiplus::Font app_font(&font_family, ScalePx(13.0f, current_dpi_),
                         Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::Font time_font(&font_family, ScalePx(12.0f, current_dpi_),
                          Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::Font title_font(&font_family, ScalePx(17.0f, current_dpi_),
                           Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
  Gdiplus::Font subtitle_font(&font_family, ScalePx(14.0f, current_dpi_),
                              Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::Font button_font(&font_family, ScalePx(13.0f, current_dpi_),
                            Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);

  Gdiplus::StringFormat ellipsis_format;
  ellipsis_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  ellipsis_format.SetFormatFlags(Gdiplus::StringFormatFlagsLineLimit);

  Gdiplus::StringFormat centered_format;
  centered_format.SetAlignment(Gdiplus::StringAlignmentCenter);
  centered_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  centered_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);

  for (auto iterator = notifications_.rbegin();
       iterator != notifications_.rend(); ++iterator) {
    auto& item = *iterator;
    if (item->opacity <= 0.01) {
      continue;
    }
    const auto scaled_padding = ScalePx(kPadding, current_dpi_);
    const auto scaled_card_height = ScalePx(item->layout_height, current_dpi_);
    const auto scaled_window_width = ScalePx(kWindowWidth, current_dpi_);
    const auto scaled_corner_radius =
        static_cast<float>(ScalePx(kCornerRadius, current_dpi_));
    const auto rect = Gdiplus::RectF(
        static_cast<Gdiplus::REAL>(scaled_padding),
        static_cast<Gdiplus::REAL>(ScalePx(
            static_cast<float>(item->current_y), current_dpi_)),
        static_cast<Gdiplus::REAL>(scaled_window_width - (scaled_padding * 2)),
        static_cast<Gdiplus::REAL>(scaled_card_height));
    Gdiplus::GraphicsPath card_path(Gdiplus::FillModeAlternate);
    BuildRoundedRect(&card_path, rect, scaled_corner_radius);

    Gdiplus::SolidBrush card_fill(
        WithAlpha(Gdiplus::Color(255, 20, 20, 20), item->opacity));
    graphics.FillPath(&card_fill, &card_path);

    {
      const auto state = graphics.Save();
      graphics.SetClip(&card_path);

      const auto inner_rect =
          Gdiplus::RectF(rect.X + 1.0f, rect.Y + 1.0f, rect.Width - 2.0f,
                         rect.Height - 2.0f);
      Gdiplus::LinearGradientBrush top_sheen(
          Gdiplus::PointF(inner_rect.X, inner_rect.Y),
          Gdiplus::PointF(inner_rect.X, inner_rect.GetBottom()),
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.018),
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), 0.0));
      graphics.FillRectangle(&top_sheen, inner_rect);

      Gdiplus::LinearGradientBrush lower_wash(
          Gdiplus::PointF(inner_rect.X, inner_rect.Y),
          Gdiplus::PointF(inner_rect.GetRight(), inner_rect.GetBottom()),
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), 0.0),
          WithAlpha(Gdiplus::Color(255, 180, 200, 255), item->opacity * 0.010));
      graphics.FillRectangle(&lower_wash, inner_rect);

      DrawSoftSpotlight(
          &graphics,
          Gdiplus::RectF(inner_rect.X - inner_rect.Width * 0.04f,
                         inner_rect.Y - inner_rect.Height * 0.18f,
                         inner_rect.Width * 0.72f, inner_rect.Height * 0.42f),
          Gdiplus::PointF(inner_rect.X + inner_rect.Width * 0.10f,
                          inner_rect.Y + inner_rect.Height * 0.08f),
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.022));

      DrawSoftSpotlight(
          &graphics,
          Gdiplus::RectF(inner_rect.GetRight() - inner_rect.Width * 0.44f,
                         inner_rect.GetBottom() - inner_rect.Height * 0.32f,
                         inner_rect.Width * 0.52f, inner_rect.Height * 0.36f),
          Gdiplus::PointF(inner_rect.GetRight() - inner_rect.Width * 0.08f,
                          inner_rect.GetBottom() - inner_rect.Height * 0.06f),
          WithAlpha(Gdiplus::Color(255, 180, 200, 255), item->opacity * 0.015));

      graphics.Restore(state);
    }

    Gdiplus::Pen border_pen(
        WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.06), 1.0f);
    graphics.DrawPath(&border_pen, &card_path);

    const auto header_left = rect.X + ScalePx(20.0f, current_dpi_);
    const auto header_top = rect.Y + ScalePx(18.0f, current_dpi_);
    const auto badge_size = ScalePx(22.0f, current_dpi_);
    const auto close_size = ScalePx(26.0f, current_dpi_);

    const Gdiplus::RectF badge_rect(header_left, header_top, badge_size, badge_size);
    DrawHeaderBadge(&graphics, badge_rect, item->opacity);

    const auto app_label_left = badge_rect.GetRight() + ScalePx(10.0f, current_dpi_);
    Gdiplus::SolidBrush app_brush(
        WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.78));
    graphics.DrawString(
        kAppLabel, -1, &app_font,
        Gdiplus::PointF(app_label_left, header_top + ScalePx(1.0f, current_dpi_)),
        &app_brush);

    Gdiplus::RectF app_label_bounds;
    graphics.MeasureString(
        kAppLabel, -1, &app_font,
        Gdiplus::PointF(app_label_left, header_top + ScalePx(1.0f, current_dpi_)),
        &app_label_bounds);

    const auto dot_center_x =
        app_label_bounds.GetRight() + ScalePx(10.0f, current_dpi_);
    const auto dot_center_y = header_top + ScalePx(11.0f, current_dpi_);
    Gdiplus::SolidBrush dot_brush(
        WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.35));
    graphics.FillEllipse(
        &dot_brush,
        Gdiplus::RectF(dot_center_x - ScalePx(1.5f, current_dpi_),
                       dot_center_y - ScalePx(1.5f, current_dpi_),
                       ScalePx(3.0f, current_dpi_), ScalePx(3.0f, current_dpi_)));

    Gdiplus::SolidBrush time_brush(
        WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.45));
    graphics.DrawString(
        kNowLabel, -1, &time_font,
        Gdiplus::PointF(dot_center_x + ScalePx(10.0f, current_dpi_),
                        header_top + ScalePx(2.0f, current_dpi_)),
        &time_brush);

    const Gdiplus::RectF close_rect(
        rect.GetRight() - ScalePx(20.0f, current_dpi_) - close_size,
        header_top - ScalePx(2.0f, current_dpi_), close_size, close_size);
    item->close_rect = RectFToRect(close_rect);

    Gdiplus::GraphicsPath close_path(Gdiplus::FillModeAlternate);
    BuildCirclePath(&close_path, close_rect);
    Gdiplus::Pen close_border(
        WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.08), 1.0f);
    graphics.DrawPath(&close_border, &close_path);

    Gdiplus::Pen close_icon(
        WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.58),
        ScalePx(1.4f, current_dpi_));
    close_icon.SetStartCap(Gdiplus::LineCapRound);
    close_icon.SetEndCap(Gdiplus::LineCapRound);
    graphics.DrawLine(
        &close_icon, close_rect.X + close_rect.Width * 0.34f,
        close_rect.Y + close_rect.Height * 0.34f,
        close_rect.GetRight() - close_rect.Width * 0.34f,
        close_rect.GetBottom() - close_rect.Height * 0.34f);
    graphics.DrawLine(
        &close_icon, close_rect.GetRight() - close_rect.Width * 0.34f,
        close_rect.Y + close_rect.Height * 0.34f,
        close_rect.X + close_rect.Width * 0.34f,
        close_rect.GetBottom() - close_rect.Height * 0.34f);

    const bool has_image = item->image != nullptr;
    const bool has_buttons = !item->buttons.empty();
    const auto thumb_size = ScalePx(64.0f, current_dpi_);
    const auto body_top =
        rect.Y + ScalePx(has_image ? 52.0f : 56.0f, current_dpi_);
    const auto body_left = rect.X + ScalePx(20.0f, current_dpi_);
    const auto text_left =
        has_image ? body_left + thumb_size + ScalePx(16.0f, current_dpi_) : body_left;
    const auto text_right = rect.GetRight() - ScalePx(20.0f, current_dpi_);
    const auto text_width = text_right - text_left;
    const auto title_top = body_top + (has_image ? ScalePx(6.0f, current_dpi_) : 0.0f);
    const auto subtitle_top = title_top + ScalePx(28.0f, current_dpi_);

    if (has_image) {
      const Gdiplus::RectF thumb_rect(body_left, body_top, thumb_size, thumb_size);
      DrawClippedImage(&graphics, item->image.get(), thumb_rect, true, item->opacity);
      Gdiplus::Pen thumb_border(
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.14), 1.0f);
      Gdiplus::GraphicsPath thumb_path(Gdiplus::FillModeAlternate);
      BuildCirclePath(&thumb_path, thumb_rect);
      graphics.DrawPath(&thumb_border, &thumb_path);
    }

    const std::wstring& primary_text =
        item->title.empty() ? item->subtitle : item->title;
    const std::wstring& secondary_text =
        item->title.empty() ? std::wstring() : item->subtitle;

    if (!primary_text.empty()) {
      Gdiplus::SolidBrush title_brush(
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity));
      graphics.DrawString(primary_text.c_str(), -1, &title_font,
                          Gdiplus::RectF(text_left, title_top, text_width,
                                         ScalePx(24.0f, current_dpi_)),
                          &ellipsis_format, &title_brush);
    }

    if (!secondary_text.empty()) {
      Gdiplus::SolidBrush subtitle_brush(
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.58));
      graphics.DrawString(secondary_text.c_str(), -1, &subtitle_font,
                          Gdiplus::RectF(text_left, subtitle_top, text_width,
                                         ScalePx(has_buttons ? 42.0f : 34.0f, current_dpi_)),
                          &ellipsis_format, &subtitle_brush);
    }

    for (auto& button : item->buttons) {
      button.rect = RECT{};
    }

    if (!item->buttons.empty()) {
      const auto actions_top = rect.GetBottom() - ScalePx(34.0f, current_dpi_);
      Gdiplus::Pen top_rule(
          WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.12), 1.0f);
      graphics.DrawLine(&top_rule, rect.X + ScalePx(20.0f, current_dpi_), actions_top,
                        rect.GetRight() - ScalePx(20.0f, current_dpi_), actions_top);

      const auto actions_left = rect.X + ScalePx(20.0f, current_dpi_);
      const auto actions_width = rect.Width - ScalePx(40.0f, current_dpi_);
      const auto actions_height = ScalePx(28.0f, current_dpi_);
      if (item->buttons.size() == 1) {
        const Gdiplus::RectF button_rect(
            actions_left, actions_top + ScalePx(6.0f, current_dpi_), actions_width,
            actions_height);
        item->buttons[0].rect = RectFToRect(button_rect);
        Gdiplus::SolidBrush brush(
            WithAlpha(item->buttons[0].is_red ? Gdiplus::Color(255, 255, 107, 107)
                                              : Gdiplus::Color(255, 255, 255, 255),
                      item->opacity));
        graphics.DrawString(item->buttons[0].label.c_str(), -1, &button_font,
                            button_rect, &centered_format, &brush);
      } else {
        const auto separator_x = actions_left + (actions_width / 2.0f);
        Gdiplus::Pen separator(
            WithAlpha(Gdiplus::Color(255, 255, 255, 255), item->opacity * 0.12), 1.0f);
        graphics.DrawLine(
            &separator, separator_x, actions_top + ScalePx(11.0f, current_dpi_),
            separator_x, actions_top + ScalePx(27.0f, current_dpi_));
        for (size_t button_index = 0; button_index < item->buttons.size();
             button_index += 1) {
          const auto button_width = (actions_width / 2.0f) - ScalePx(1.0f, current_dpi_);
          const auto button_left =
              actions_left + (button_index == 0 ? 0.0f : (actions_width / 2.0f));
          const Gdiplus::RectF button_rect(
              button_left, actions_top + ScalePx(6.0f, current_dpi_), button_width,
              actions_height);
          item->buttons[button_index].rect = RectFToRect(button_rect);
          Gdiplus::SolidBrush brush(
              WithAlpha(item->buttons[button_index].is_red
                            ? Gdiplus::Color(255, 255, 107, 107)
                            : Gdiplus::Color(255, 255, 255, 255),
                        item->opacity));
          graphics.DrawString(item->buttons[button_index].label.c_str(), -1,
                              &button_font, button_rect, &centered_format, &brush);
        }
      }
    }
  }

  POINT source_point{0, 0};
  SIZE window_size{width, height};
  RECT window_rect{};
  GetWindowRect(window_, &window_rect);
  POINT destination_point{window_rect.left, window_rect.top};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(window_, screen_dc, &destination_point, &window_size,
                      memory_dc, &source_point, 0, &blend, ULW_ALPHA);

  SelectObject(memory_dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);
}

void AppNotificationManager::UpdateWindowBounds() {
  if (window_ == nullptr) {
    return;
  }
  if (notifications_.empty()) {
    ShowWindow(window_, SW_HIDE);
    return;
  }

  const auto scaled_window_width = ScalePx(kWindowWidth, current_dpi_);
  const auto scaled_height = ScalePx(kMaxStackHeight, current_dpi_);
  const auto screen_margin = ScalePx(16, current_dpi_);

  RECT work_area{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  const auto x = work_area.right - scaled_window_width - screen_margin;
  const auto y = work_area.bottom - scaled_height - screen_margin;

  SetWindowPos(window_, HWND_TOPMOST, x, y, scaled_window_width, scaled_height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ShowWindow(window_, SW_SHOWNOACTIVATE);
}

void AppNotificationManager::RemoveExpiredNotifications() {
  const auto now = GetTickCount64();
  std::vector<std::string> removed_ids;
  notifications_.erase(
      std::remove_if(
          notifications_.begin(), notifications_.end(),
          [&](const auto& item) {
            const bool should_remove =
                item->dismissing &&
                (now - item->dismiss_started_at_ms) >= kFadeOutMs;
            if (should_remove) {
              removed_ids.push_back(item->id);
            }
            return should_remove;
          }),
      notifications_.end());

  for (const auto& id : removed_ids) {
    DispatchDismissed(id);
  }

  while (notifications_.size() < static_cast<size_t>(kMaxVisibleNotifications) &&
         !pending_notifications_.empty()) {
    auto next = std::move(pending_notifications_.front());
    pending_notifications_.erase(pending_notifications_.begin());
    next->created_at_ms = now;
    next->dismiss_started_at_ms = 0;
    next->dismissing = false;
    next->opacity = 0.0;
    next->current_y = -static_cast<double>(next->layout_height);
    notifications_.insert(notifications_.begin(), std::move(next));
  }
}

void AppNotificationManager::HandlePointerUp(POINT point) {
  for (auto& item : notifications_) {
    if (item->opacity <= 0.01 || item->dismissing) {
      continue;
    }
    if (PtInRect(&item->close_rect, point)) {
      BeginDismiss(item.get());
      RenderWindow();
      return;
    }
    for (size_t button_index = 0; button_index < item->buttons.size();
         button_index += 1) {
      if (PtInRect(&item->buttons[button_index].rect, point)) {
        BeginDismiss(item.get());
        DispatchActionInvoked(item->id, static_cast<int>(button_index));
        RenderWindow();
        return;
      }
    }
  }
}

LRESULT CALLBACK AppNotificationManager::WndProc(HWND hwnd,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create_struct = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create_struct->lpCreateParams));
  }
  auto* manager = reinterpret_cast<AppNotificationManager*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (manager == nullptr) {
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  return manager->HandleWindowMessage(hwnd, message, wparam, lparam);
}

LRESULT AppNotificationManager::HandleWindowMessage(HWND hwnd,
                                                    UINT message,
                                                    WPARAM wparam,
                                                    LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_ERASEBKGND:
      return 1;
    case WM_DPICHANGED:
      current_dpi_ = HIWORD(wparam);
      UpdateWindowBounds();
      RenderWindow();
      return 0;
    case WM_LBUTTONUP: {
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      HandlePointerUp(point);
      return 0;
    }
    case WM_TIMER:
      if (wparam == kAnimationTimerId) {
        Tick();
        return 0;
      }
      break;
    case WM_PAINT: {
      PAINTSTRUCT paint_struct{};
      BeginPaint(hwnd, &paint_struct);
      EndPaint(hwnd, &paint_struct);
      return 0;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
