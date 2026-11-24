#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

#include <shellapi.h>

inline constexpr wchar_t kShifterWindowClass[] = L"ShifterProxyAppWindow";
inline constexpr wchar_t kShifterActivateMessage[] = L"io.shifter.desktop.activate";

// Hosts the Flutter view and the user's notification-area icon.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RestoreWindow(HWND hwnd);
  void ShowTrayMenu(HWND hwnd);
  void AddTrayIcon();
  void RequestQuit(HWND hwnd);

  bool tray_added_ = false;
  bool can_connect_ = false;
  bool quitting_ = false;
  std::wstring connection_ = L"Starting";
  NOTIFYICONDATAW tray_{};
  const UINT taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  const UINT activate_message_ = RegisterWindowMessageW(kShifterActivateMessage);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
