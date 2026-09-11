#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 重复启动时，占着运行权的那个实例已经找不到可以唤到前台的主窗口：它的窗口
// 不在，但进程还没有退出。此时若直接静默结束，用户看到的就是双击图标后毫无
// 反应，无从判断该做什么。给出说明，让他至少知道去哪里处理。
//
// 文案跟随系统界面语言。只有一段话，不值得引入完整的资源本地化；runner 的
// 原生弹窗也不经过应用的 ARB 文案。
void ShowExistingInstanceNotice() {
  const LANGID language = ::GetUserDefaultUILanguage();
  const bool chinese = PRIMARYLANGID(language) == LANG_CHINESE;
  const wchar_t* message =
      chinese
          ? L"JO-AIClient 已经在运行，但它的窗口没有出现在屏幕上。\n\n"
            L"如果找不到它，请在任务管理器中结束所有 JO-AIClient 进程，"
            L"然后重新打开。"
          : L"JO-AIClient is already running, but its window is not on "
            L"screen.\n\n"
            L"If you cannot find it, end every JO-AIClient process in "
            L"Task Manager, then start it again.";
  ::MessageBoxW(nullptr, message, L"JO-AIClient",
                MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const std::wstring associated_backup_path =
      GetAssociatedBackupPath(command_line_arguments);

  // Enforce a single running instance on Windows using a named mutex.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"JOAIClientMutex");
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // restart_app launches the replacement process before terminating the
    // current one. Give that short handoff a chance to acquire the mutex;
    // ordinary duplicate launches still fall back to the existing focus path
    // after the bounded wait.
    const DWORD wait_result = ::WaitForSingleObject(instance_mutex, 2000);
    if (wait_result != WAIT_OBJECT_0 && wait_result != WAIT_ABANDONED) {
      bool handed_off = false;
      for (int attempt = 0; attempt < 20; ++attempt) {
        if (Win32Window::SendAppLinkToInstance(
                L"JO-AIClient", associated_backup_path)) {
          handed_off = true;
          break;
        }
        ::Sleep(100);
      }
      // 唤不到窗口就不再默默结束：那正是看起来毫无反应的来源。
      if (!handed_off) {
        ShowExistingInstanceNotice();
      }
      ::CloseHandle(instance_mutex);
      return 0;
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // https://github.com/flutter/flutter/issues/175135
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"JO-AIClient", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
