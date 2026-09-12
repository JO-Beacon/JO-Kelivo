#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

/// Window attributes that let an app paint its own caption bar.
///
/// Introduced in Windows 11 (build 22000), so they are redefined here for
/// SDKs older than that. On Windows 10 the calls fail and the frame keeps
/// the system default.
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

/// Registry value for the shell: taskbar, notification area and Start menu.
///
/// Windows keeps this separate from the value above so applications and the
/// shell can use different modes. A tray icon is drawn by the shell, so it has
/// to follow this one instead of the app theme.
constexpr const wchar_t kGetShellBrightnessRegValue[] = L"SystemUsesLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

// Set once the application has taken over the caption's appearance. From that
// point on the system theme must not repaint the frame; the Dart side re-pushes
// whenever the in-app theme changes.
static bool g_caption_overridden = false;

// Converts a 0xAARRGGBB value to the 0x00BBGGRR COLORREF that DWM expects.
COLORREF ToColorRef(unsigned int argb) {
  return RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
}

// Reads one of the personalisation light/dark flags. Returns false when the
// value is absent, which is normal on a machine that never changed the setting.
bool ReadLightThemeFlag(const wchar_t* value_name, bool* light_mode) {
  DWORD value = 1;
  DWORD value_size = sizeof(value);
  const LSTATUS result =
      RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey, value_name,
                  RRF_RT_REG_DWORD, nullptr, &value, &value_size);
  if (result != ERROR_SUCCESS) {
    return false;
  }
  *light_mode = value != 0;
  return true;
}

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  // Before creating a new window, first check whether there is already an
  // existing window with the same class name and title. If so, bring that
  // window to the foreground instead of creating another one.
  if (SendAppLinkToInstance(title)) {
    return false;
  }

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_CONTEXTMENU:
      // Swallow default system context-menu for the main window.
      // Otherwise, when the tray plugin brings the app to front and
      // shows its own popup menu, Windows may also show the standard
      // window system menu at an offset position, making it look like
      // a "second" phantom menu and causing clicks to appear invalid.
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

// static
bool Win32Window::SendAppLinkToInstance(const std::wstring& title,
                                        const std::wstring& backup_path) {
  // 1. Look for a window that matches the Flutter runner window class and the
  //    given title.
  HWND hwnd = ::FindWindow(kWindowClassName, title.c_str());

  if (hwnd) {
    // 2. Query the current placement so we can restore it appropriately.
    WINDOWPLACEMENT place;
    place.length = sizeof(WINDOWPLACEMENT);
    if (::GetWindowPlacement(hwnd, &place)) {
      switch (place.showCmd) {
        case SW_SHOWMAXIMIZED:
          ::ShowWindow(hwnd, SW_SHOWMAXIMIZED);
          break;
        case SW_SHOWMINIMIZED:
          ::ShowWindow(hwnd, SW_RESTORE);
          break;
        default:
          ::ShowWindow(hwnd, SW_NORMAL);
          break;
      }
    } else {
      // If we cannot query placement, just try to show it normally.
      ::ShowWindow(hwnd, SW_NORMAL);
    }

    // 3. Bring the window to the front.
    ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                   SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    ::SetForegroundWindow(hwnd);

    if (!backup_path.empty()) {
      COPYDATASTRUCT data{};
      data.dwData = 0x4A4F4149;
      data.cbData = static_cast<DWORD>(
          (backup_path.size() + 1) * sizeof(wchar_t));
      data.lpData = const_cast<wchar_t*>(backup_path.c_str());
      ::SendMessage(hwnd, WM_COPYDATA, 0,
                    reinterpret_cast<LPARAM>(&data));
    }

    return true;
  }

  // No existing window found.
  return false;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  // The application already decided how the frame should look; repainting it
  // from the system theme would fight with that.
  if (g_caption_overridden) {
    return;
  }

  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

void Win32Window::ApplyCaptionAppearance(HWND const window,
                                         bool dark,
                                         bool use_custom_colors,
                                         unsigned int caption_argb,
                                         unsigned int text_argb,
                                         unsigned int border_argb) {
  if (window == nullptr) {
    return;
  }

  // The caption buttons are drawn by the system, so their glyph colour comes
  // from this flag rather than from any colour we pass. It takes effect on
  // Windows 10 as well, where it is the only part that does anything.
  BOOL enable_dark_mode = dark ? TRUE : FALSE;
  const HRESULT dark_result = DwmSetWindowAttribute(
      window, DWMWA_USE_IMMERSIVE_DARK_MODE, &enable_dark_mode,
      sizeof(enable_dark_mode));

  // The handover is recorded here, not after the colour calls below: Windows 10
  // rejects those colours, yet the dark-mode flag above still lands, and
  // leaving the system free to repaint the frame would fight the in-app theme.
  if (SUCCEEDED(dark_result)) {
    g_caption_overridden = true;
  }

  if (!use_custom_colors) {
    return;
  }

  const COLORREF caption = ToColorRef(caption_argb);
  const COLORREF text = ToColorRef(text_argb);
  const COLORREF border = ToColorRef(border_argb);

  // A failure here means the OS does not support custom frame colours, so the
  // window simply keeps the frame the system draws for it.
  const HRESULT result = DwmSetWindowAttribute(
      window, DWMWA_CAPTION_COLOR, &caption, sizeof(caption));
  if (SUCCEEDED(result)) {
    DwmSetWindowAttribute(window, DWMWA_TEXT_COLOR, &text, sizeof(text));
    DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &border, sizeof(border));
  }
}

// static
bool Win32Window::SystemUsesDarkMode() {
  // Never configured means light, which is the Windows default.
  bool light_mode = true;
  ReadLightThemeFlag(kGetShellBrightnessRegValue, &light_mode);
  return !light_mode;
}
