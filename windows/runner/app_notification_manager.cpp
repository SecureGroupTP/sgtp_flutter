#include "app_notification_manager.h"

#include <flutter/encodable_value.h>
#include <gdiplus.h>
#include <objidl.h>
#include <shellscalingapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kNotificationWindowClassName[] =
    L"SGTP_APP_NOTIFICATION_WINDOW";
constexpr wchar_t kNotificationWindowTitle[] = L"SGTP App Notifications";

constexpr int kWindowWidth = 360;
constexpr int kCardHeight = 88;
constexpr int kCardSpacing = 12;
constexpr int kStackStep = kCardHeight + kCardSpacing;
constexpr int kRolloverStackStep = 68;
constexpr int kMaxVisibleNotifications = 3;
constexpr int kPadding = 12;
constexpr int kMaxStackHeight =
    (kPadding * 2) + (kCardHeight * kMaxVisibleNotifications) +
    (kCardSpacing * (kMaxVisibleNotifications - 1));
constexpr int kImageSize = 48;
constexpr int kCornerRadius = 18;
constexpr int kFadeInMs = 180;
constexpr int kFadeOutMs = 1000;
constexpr double kPositionLerp = 0.24;
constexpr UINT_PTR kAnimationTimerId = 1001;
constexpr UINT kAnimationTimerIntervalMs = 16;

int ScalePx(int value, UINT dpi) {
  return MulDiv(value, static_cast<int>(dpi), 96);
}

float ScalePx(float value, UINT dpi) {
  return value * static_cast<float>(dpi) / 96.0f;
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
  window_class.hbrBackground =
      reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassW(&window_class);
  registered = true;
}

}  // namespace

struct AppNotificationManager::NotificationItem {
  std::string id;
  std::wstring title;
  std::wstring subtitle;
  std::unique_ptr<Gdiplus::Image> image;
  int duration_ms = 5000;
  ULONGLONG created_at_ms = 0;
  ULONGLONG dismiss_started_at_ms = 0;
  bool dismissing = false;
  double opacity = 0.0;
  double current_y = -static_cast<double>(kCardHeight);
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
      kWindowWidth, kCardHeight + (kPadding * 2), nullptr, nullptr,
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

  if (notifications_.size() >= kMaxVisibleNotifications) {
    if (!notifications_.back()->dismissing) {
      notifications_.back()->dismissing = true;
      notifications_.back()->dismiss_started_at_ms = GetTickCount64();
    }
    pending_notifications_.push_back(std::move(item));
  } else {
    notifications_.insert(notifications_.begin(), std::move(item));
  }

  const auto now = GetTickCount64();
  for (size_t index = kMaxVisibleNotifications; index < notifications_.size();
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
  const auto now = GetTickCount64();
  for (auto& item : notifications_) {
    if (item->id == id && !item->dismissing) {
      item->dismissing = true;
      item->dismiss_started_at_ms = now;
    }
  }
  if (window_ != nullptr) {
    RenderWindow();
  }
}

void AppNotificationManager::DismissAllNotifications() {
  pending_notifications_.clear();
  const auto now = GetTickCount64();
  for (auto& item : notifications_) {
    if (!item->dismissing) {
      item->dismissing = true;
      item->dismiss_started_at_ms = now;
    }
  }
  if (window_ != nullptr) {
    RenderWindow();
  }
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
  const auto base_slot =
      std::max(0, kMaxVisibleNotifications - visible_count);
  const bool rollover_mode =
      !pending_notifications_.empty() && visible_count == kMaxVisibleNotifications &&
      notifications_.back()->dismissing;
  const auto layout_step = rollover_mode ? kRolloverStackStep : kStackStep;
  const auto bottom_anchor =
      static_cast<double>(kPadding + (kMaxVisibleNotifications - 1) * kStackStep);
  for (size_t index = 0; index < notifications_.size(); index += 1) {
    auto& item = notifications_[index];
    if (!item->dismissing &&
        now >= item->created_at_ms + static_cast<ULONGLONG>(item->duration_ms)) {
      item->dismissing = true;
      item->dismiss_started_at_ms = now;
    }

    const auto target_y = rollover_mode
                              ? (bottom_anchor -
                                 static_cast<double>(
                                     (visible_count - 1 - static_cast<int>(index)) *
                                     layout_step))
                              : static_cast<double>(
                                    kPadding +
                                    (base_slot + static_cast<int>(index)) *
                                        kStackStep);
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
  Gdiplus::Font title_font(&font_family, ScalePx(15.5f, current_dpi_),
                           Gdiplus::FontStyleBold,
                           Gdiplus::UnitPixel);
  Gdiplus::Font subtitle_font(&font_family, ScalePx(13.0f, current_dpi_),
                              Gdiplus::FontStyleRegular,
                              Gdiplus::UnitPixel);

  Gdiplus::StringFormat string_format;
  string_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);

  for (auto iterator = notifications_.rbegin();
       iterator != notifications_.rend(); ++iterator) {
    const auto& item = *iterator;
    if (item->opacity <= 0.01) {
      continue;
    }
    const auto scaled_padding = ScalePx(kPadding, current_dpi_);
    const auto scaled_card_height = ScalePx(kCardHeight, current_dpi_);
    const auto scaled_window_width = ScalePx(kWindowWidth, current_dpi_);
    const auto scaled_corner_radius =
        static_cast<float>(ScalePx(kCornerRadius, current_dpi_));
    const auto scaled_image_size = ScalePx(kImageSize, current_dpi_);
    const auto rect = Gdiplus::RectF(
        static_cast<Gdiplus::REAL>(scaled_padding),
        static_cast<Gdiplus::REAL>(ScalePx(
            static_cast<float>(item->current_y), current_dpi_)),
        static_cast<Gdiplus::REAL>(scaled_window_width - (scaled_padding * 2)),
        static_cast<Gdiplus::REAL>(scaled_card_height));
    Gdiplus::GraphicsPath card_path(Gdiplus::FillModeAlternate);
    BuildRoundedRect(&card_path, rect, scaled_corner_radius);

    Gdiplus::SolidBrush card_fill(
        WithAlpha(Gdiplus::Color(255, 30, 35, 43), item->opacity));
    graphics.FillPath(&card_fill, &card_path);

    Gdiplus::Pen border_pen(
        WithAlpha(Gdiplus::Color(255, 58, 66, 79), item->opacity), 1.0f);
    graphics.DrawPath(&border_pen, &card_path);

    Gdiplus::REAL text_left = rect.X + ScalePx(18.0f, current_dpi_);
    if (item->image != nullptr) {
      const auto image_rect =
          Gdiplus::RectF(rect.X + ScalePx(16.0f, current_dpi_),
                         rect.Y + ScalePx(20.0f, current_dpi_),
                         static_cast<Gdiplus::REAL>(scaled_image_size),
                         static_cast<Gdiplus::REAL>(scaled_image_size));
      graphics.DrawImage(item->image.get(), image_rect);
      text_left = image_rect.GetRight() + ScalePx(14.0f, current_dpi_);
    }

    const auto text_width =
        rect.GetRight() - text_left - ScalePx(16.0f, current_dpi_);
    if (!item->title.empty()) {
      Gdiplus::SolidBrush title_brush(
          WithAlpha(Gdiplus::Color(255, 246, 248, 250), item->opacity));
      const auto title_rect =
          Gdiplus::RectF(text_left, rect.Y + ScalePx(18.0f, current_dpi_),
                         text_width, ScalePx(24.0f, current_dpi_));
      graphics.DrawString(item->title.c_str(), -1, &title_font, title_rect,
                          &string_format, &title_brush);
    }

    if (!item->subtitle.empty()) {
      Gdiplus::SolidBrush subtitle_brush(
          WithAlpha(Gdiplus::Color(255, 176, 184, 196), item->opacity));
      const auto subtitle_top = item->title.empty()
                                    ? rect.Y + ScalePx(30.0f, current_dpi_)
                                    : rect.Y + ScalePx(42.0f, current_dpi_);
      const auto subtitle_rect =
          Gdiplus::RectF(text_left, subtitle_top, text_width,
                         ScalePx(20.0f, current_dpi_));
      graphics.DrawString(item->subtitle.c_str(), -1, &subtitle_font,
                          subtitle_rect, &string_format, &subtitle_brush);
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
  const auto old_size = notifications_.size();
  notifications_.erase(
      std::remove_if(
          notifications_.begin(), notifications_.end(),
          [&](const auto& item) {
            return item->dismissing &&
                   (now - item->dismiss_started_at_ms) >= kFadeOutMs;
          }),
      notifications_.end());
  if (notifications_.size() == old_size) {
    return;
  }

  while (notifications_.size() < kMaxVisibleNotifications &&
         !pending_notifications_.empty()) {
    auto next = std::move(pending_notifications_.front());
    pending_notifications_.erase(pending_notifications_.begin());
    next->created_at_ms = now;
    next->dismiss_started_at_ms = 0;
    next->dismissing = false;
    next->opacity = 0.0;
    next->current_y = -static_cast<double>(kCardHeight);
    notifications_.insert(notifications_.begin(), std::move(next));
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
