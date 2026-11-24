#include "flutter_window.h"

#include <optional>

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kOpen = 1;
constexpr UINT kToggle = 2;
constexpr UINT kQuit = 3;
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_hidden)
    : start_hidden_(start_hidden), project_(project) {}

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

  desktop_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "io.shifter.desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_->SetMethodCallHandler([this](const auto& call, auto reply) {
    if (call.method_name() != "connection") {
      reply->NotImplemented();
      return;
    }
    const auto* state = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!state) {
      reply->Error("state", "Missing connection state");
      return;
    }
    const auto status = state->find(flutter::EncodableValue("status"));
    const auto allowed = state->find(flutter::EncodableValue("canConnect"));
    if (status != state->end() && std::get_if<std::string>(&status->second)) {
      const auto& text = std::get<std::string>(status->second);
      connection_.assign(text.begin(), text.end());
    }
    can_connect_ = allowed != state->end() &&
                   std::get_if<bool>(&allowed->second) &&
                   std::get<bool>(allowed->second);
    const std::wstring tip = L"Shifter - " + connection_;
    wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
    if (tray_added_) Shell_NotifyIconW(NIM_MODIFY, &tray_);
    reply->Success();
  });
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle();
  tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"Shifter");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (!start_hidden_ || !tray_added_) Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::AddTrayIcon() {
  if (!tray_.hWnd) return;
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
  if (tray_added_) {
    tray_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_);
  }
}

void FlutterWindow::RestoreWindow(HWND hwnd) {
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu(HWND hwnd) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kOpen, L"Open Shifter");
  AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, connection_.c_str());
  AppendMenuW(menu, MF_STRING | (can_connect_ ? MF_ENABLED : MF_GRAYED), kToggle,
              connection_ == L"Connected" ? L"Disconnect" : L"Connect");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kQuit, L"Quit Shifter");
  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(hwnd);
  const UINT action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY,
                                    cursor.x, cursor.y, 0, hwnd, nullptr);
  DestroyMenu(menu);
  PostMessageW(hwnd, WM_NULL, 0, 0);
  if (action == kOpen) RestoreWindow(hwnd);
  if (action == kToggle && desktop_) desktop_->InvokeMethod("toggleConnection", nullptr);
  if (action == kQuit) RequestQuit(hwnd);
}

void FlutterWindow::RequestQuit(HWND hwnd) {
  if (quitting_ || !desktop_) return;
  quitting_ = true;
  desktop_->InvokeMethod("shutdown", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [hwnd](const flutter::EncodableValue*) { PostMessageW(hwnd, WM_APP + 2, 0, 0); },
          [this, hwnd](const std::string&, const std::string&, const flutter::EncodableValue*) {
            quitting_ = false;
            MessageBoxW(hwnd, L"Shifter could not restore proxy settings. Disconnect and try again.",
                        L"Shifter", MB_OK | MB_ICONWARNING);
          },
          [this]() { quitting_ = false; }));
}

void FlutterWindow::OnDestroy() {
  if (tray_added_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  desktop_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == activate_message_) {
    RestoreWindow(hwnd);
    return 0;
  }
  if (message == taskbar_created_) {
    AddTrayIcon();
    return 0;
  }
  if (message == WM_CLOSE && tray_added_) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (message == kTrayMessage) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT) RestoreWindow(hwnd);
    if (event == WM_CONTEXTMENU) ShowTrayMenu(hwnd);
    return 0;
  }
  if (message == WM_APP + 2) {
    DestroyWindow(hwnd);
    return 0;
  }
  if (message == WM_ENDSESSION && wparam && desktop_) {
    desktop_->InvokeMethod("shutdown", nullptr);
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
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
