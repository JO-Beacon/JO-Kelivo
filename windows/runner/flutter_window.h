#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <cstdint>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
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
  bool system_sleeping_ = false;
  int64_t last_system_wake_at_ = 0;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      associated_backup_channel_;

  // Lets Dart drive the window frame appearance (caption / text / border
  // colours). Windows 11 honours the colours; older systems reject them and
  // keep their default frame.
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_appearance_channel_;

  // Tells Dart that Windows switched between light and dark for the shell
  // (taskbar, notification area). The shell repaints itself right away, so the
  // tray icon has to be swapped without waiting for the app's next rebuild.
  void NotifySystemBrightness();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
