#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT kShow = 1001, kHide = 1002, kNotify = 1003, kExit = 1004;
}

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "aer.home/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "notifyUnread") {
      const auto* count = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
      if (!count || *count < 1) {
        result->Error("invalid_count", "A positive notification count is required");
      } else {
        result->Success(flutter::EncodableValue(NotifyUnread(*count)));
      }
    } else if (call.method_name() == "show") {
      RestoreWindow();
      result->Success();
    } else if (call.method_name() == "hide") {
      if (tray_.hWnd) ShowWindow(GetHandle(), SW_HIDE);
      result->Success();
    } else if (call.method_name() == "status") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("tray"), flutter::EncodableValue(tray_.hWnd != nullptr)},
          {flutter::EncodableValue("visible"), flutter::EncodableValue(IsWindowVisible(GetHandle()) != FALSE)}}));
    } else {
      result->NotImplemented();
    }
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_.hWnd) Shell_NotifyIconW(NIM_DELETE, &tray_);
  tray_.hWnd = nullptr;
  desktop_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_ && message == taskbar_created_) {
    AddTrayIcon();
    return 0;
  }
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case NIN_SELECT:
        RestoreWindow();
        break;
      case NIN_BALLOONUSERCLICK:
        RestoreWindow();
        if (desktop_channel_) desktop_channel_->InvokeMethod("openMonitoring", nullptr);
        break;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        TrayMenu();
        break;
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  tray_ = {};
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle();
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"AER HOME");
  if (Shell_NotifyIconW(NIM_ADD, &tray_)) {
    tray_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_);
  } else {
    tray_.hWnd = nullptr; // Never hide a window without a working restore path.
  }
}

void FlutterWindow::RestoreWindow() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::TrayMenu() {
  const auto menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kShow, L"Open AER HOME");
  AppendMenuW(menu, MF_STRING, kHide, L"Hide to tray");
  AppendMenuW(menu, MF_STRING | (notifications_enabled_ ? MF_CHECKED : MF_UNCHECKED),
              kNotify, L"Notifications");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExit, L"Exit");
  POINT p{};
  GetCursorPos(&p);
  SetForegroundWindow(GetHandle());
  const auto command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                      p.x, p.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
  if (command == kShow) RestoreWindow();
  if (command == kHide && tray_.hWnd) ShowWindow(GetHandle(), SW_HIDE);
  if (command == kNotify) notifications_enabled_ = !notifications_enabled_;
  if (command == kExit) DestroyWindow(GetHandle());
}

bool FlutterWindow::NotifyUnread(int count) {
  if (!tray_.hWnd || !notifications_enabled_) return false;
  tray_.uFlags = NIF_INFO;
  wcscpy_s(tray_.szInfoTitle, L"AER HOME");
  // Only a count leaves the app: no device names, log text or credentials
  // can appear on the Windows lock screen.
  swprintf_s(tray_.szInfo, L"New monitoring notifications. Unread: %d", count);
  tray_.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
  return Shell_NotifyIconW(NIM_MODIFY, &tray_) != FALSE;
}
