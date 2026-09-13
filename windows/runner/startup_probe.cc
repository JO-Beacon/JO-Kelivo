#include "startup_probe.h"

#include <dwmapi.h>

#include <cstdio>
#include <cwchar>
#include <string>
#include <utility>
#include <vector>

namespace {

// Windows 10 的 SDK 里没有这个属性定义，补一个以便调用能编过。
#ifndef DWMWA_CLOAKED
#define DWMWA_CLOAKED 14
#endif

constexpr const wchar_t kVendorDirectory[] = L"\\JO-Beacon";
constexpr const wchar_t kAppDirectory[] = L"\\JO-AIClient";
constexpr const wchar_t kLogDirectory[] = L"\\logs";
constexpr const wchar_t kFileName[] = L"startup_native.txt";
constexpr const wchar_t kPreferencesFileName[] = L"\\shared_preferences.json";

// 与设置页“应用日志打印”对应的偏好键。Dart 侧的 shared_preferences 会给
// 自建键统一加 `flutter.` 前缀，写进 JSON 后即为此字符串。
constexpr const char kLogSwitchKey[] = "\"flutter.flutter_log_enabled_v1\"";

// 单文件上限，超过即轮转。轮转出的历史文件不在“保持打开”的名单里，
// 因此会被既有的日志清理按天数与总大小一并收纳。
constexpr unsigned long long kMaxFileBytes = 1ULL << 20;

// 同类反复消息各记录多少条。
constexpr int kMaxRepeatedLines = 6;

std::wstring EnvironmentPath(const wchar_t* name) {
  wchar_t buffer[1024] = {};
  const DWORD length = GetEnvironmentVariableW(name, buffer, 1024);
  if (length == 0 || length >= 1024) {
    return std::wstring();
  }
  return std::wstring(buffer, length);
}

bool DirectoryExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool EnsureDirectory(const std::wstring& path) {
  if (DirectoryExists(path)) {
    return true;
  }
  return CreateDirectoryW(path.c_str(), nullptr) != 0;
}

// 应用数据目录。拿不到返回空串：此时既不解析开关，也不写任何文件。
std::wstring ResolveAppDirectory() {
  const std::wstring app_data = EnvironmentPath(L"APPDATA");
  if (app_data.empty()) {
    return std::wstring();
  }
  const std::wstring vendor_dir = app_data + kVendorDirectory;
  if (!DirectoryExists(vendor_dir)) {
    return std::wstring();
  }
  const std::wstring app_dir = vendor_dir + kAppDirectory;
  if (!DirectoryExists(app_dir)) {
    return std::wstring();
  }
  return app_dir;
}

std::string ReadFileToString(const std::wstring& path, size_t max_bytes) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return std::string();
  }
  LARGE_INTEGER size = {};
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      static_cast<unsigned long long>(size.QuadPart) > max_bytes) {
    CloseHandle(file);
    return std::string();
  }
  std::string content(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  const BOOL ok = ReadFile(file, content.data(),
                           static_cast<DWORD>(content.size()), &read, nullptr);
  CloseHandle(file);
  if (!ok) {
    return std::string();
  }
  content.resize(read);
  return content;
}

// 直接读偏好设置的落盘文件，判断日志开关是否打开。
//
// 刻意不去调用任何插件接口：这里跑在 Flutter 引擎起来之前，插件通道尚不
// 可用。代价是依赖该文件的存储格式；格式若变化，结果是“当作关闭”——
// 与旧行为相同，不会更糟。
bool ReadLogSwitch() {
  const std::wstring app_dir = ResolveAppDirectory();
  if (app_dir.empty()) {
    return false;
  }
  const std::string content =
      ReadFileToString(app_dir + kPreferencesFileName, 4ULL << 20);
  if (content.empty()) {
    return false;
  }
  const size_t key_pos = content.find(kLogSwitchKey);
  if (key_pos == std::string::npos) {
    return false;
  }
  const size_t colon = content.find(':', key_pos + sizeof(kLogSwitchKey) - 1);
  if (colon == std::string::npos) {
    return false;
  }
  size_t value_pos = colon + 1;
  while (value_pos < content.size() &&
         (content[value_pos] == ' ' || content[value_pos] == '\t')) {
    value_pos++;
  }
  return content.compare(value_pos, 4, "true") == 0;
}

// 进程内只解析一次：开关在启动过程中不会改变，重复读盘没有意义。
bool Enabled() {
  static const bool enabled = ReadLogSwitch();
  return enabled;
}

std::wstring LogPath() {
  static const std::wstring path = [] {
    const std::wstring app_dir = ResolveAppDirectory();
    if (!app_dir.empty()) {
      const std::wstring logs_dir = app_dir + kLogDirectory;
      if (EnsureDirectory(logs_dir)) {
        return logs_dir + L"\\" + kFileName;
      }
    }
    // 应用目录不可用时退回系统临时目录，并在首行写明实际路径以便自证。
    wchar_t temp[1024] = {};
    if (GetTempPathW(1024, temp) == 0) {
      return std::wstring();
    }
    return std::wstring(temp) + L"jo_aiclient_" + kFileName;
  }();
  return path;
}

std::string ToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                       static_cast<int>(text.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::string TimestampPrefix() {
  SYSTEMTIME now;
  GetLocalTime(&now);
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer),
                "[%04d-%02d-%02d %02d:%02d:%02d.%03d] pid=%lu ",
                now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
                now.wSecond, now.wMilliseconds,
                static_cast<unsigned long>(GetCurrentProcessId()));
  return std::string(buffer);
}

// 超过上限就把当前文件改名留档，返回是否真的发生了轮转。
//
// 日志清理按“保持打开”名单跳过活动文件，历史文件则会被正常收纳。
bool RotateIfNeeded(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA info = {};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) {
    return false;
  }
  const unsigned long long size =
      (static_cast<unsigned long long>(info.nFileSizeHigh) << 32) |
      info.nFileSizeLow;
  if (size < kMaxFileBytes) {
    return false;
  }

  // 目标名带时间戳；同一秒内重复轮转时追加序号，直到找到空位。
  const std::wstring stem = path.substr(0, path.size() - 4);  // 去掉 .txt
  SYSTEMTIME now;
  GetLocalTime(&now);
  for (int index = 0; index < 100; ++index) {
    wchar_t suffix[64] = {};
    const int written =
        (index == 0)
            ? std::swprintf(suffix, sizeof(suffix) / sizeof(suffix[0]),
                            L"_%04d%02d%02d-%02d%02d%02d.txt", now.wYear,
                            now.wMonth, now.wDay, now.wHour, now.wMinute,
                            now.wSecond)
            : std::swprintf(suffix, sizeof(suffix) / sizeof(suffix[0]),
                            L"_%04d%02d%02d-%02d%02d%02d_%d.txt", now.wYear,
                            now.wMonth, now.wDay, now.wHour, now.wMinute,
                            now.wSecond, index);
    if (written <= 0) {
      return false;
    }
    const std::wstring target = stem + suffix;
    if (MoveFileW(path.c_str(), target.c_str())) {
      return true;
    }
    const DWORD error = GetLastError();
    if (error != ERROR_ALREADY_EXISTS && error != ERROR_FILE_EXISTS) {
      return false;  // 其它失败原因（占用、权限）重试也没有意义。
    }
  }
  return false;
}

// 每类反复消息各留一笔额度；用尽后该类不再记录。返回是否还有额度。
bool ConsumeRepeatedBudget(const std::string& key) {
  static std::vector<std::pair<std::string, int>> used;
  for (auto& entry : used) {
    if (entry.first == key) {
      if (entry.second >= kMaxRepeatedLines) {
        return false;
      }
      entry.second++;
      return true;
    }
  }
  used.emplace_back(key, 1);
  return true;
}

// 每次追加都重新开关文件：进程随时可能被强制结束，保持句柄反而更容易丢内容，
// 也会和新进程抢同一个文件。
void Append(const std::string& line) {
  static bool wrote_header = false;

  const std::wstring& path = LogPath();
  if (path.empty()) {
    return;
  }
  if (RotateIfNeeded(path)) {
    // 轮转后是一个新文件，自证行要重新写一遍。
    wrote_header = false;
  }

  std::string payload;
  if (!wrote_header) {
    wrote_header = true;
    payload = "\n===== native probe start, file: " + ToUtf8(path) +
              " =====\n";
  }
  payload += TimestampPrefix();
  payload += line;
  payload += "\n";

  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  WriteFile(file, payload.data(), static_cast<DWORD>(payload.size()), &written,
            nullptr);
  CloseHandle(file);
}

}  // namespace

namespace startup_probe {

void Log(const char* message) {
  if (message == nullptr || !Enabled()) {
    return;
  }
  Append(std::string(message));
}

void LogWindowState(HWND window, const char* phase) {
  if (!Enabled()) {
    return;
  }
  const char* label = (phase == nullptr) ? "window" : phase;
  if (window == nullptr) {
    Append(std::string(label) + ": handle=null");
    return;
  }

  RECT rect = {};
  GetClientRect(window, &rect);
  const BOOL visible = IsWindowVisible(window);
  const BOOL minimized = IsIconic(window);
  DWORD cloaked = 0;
  const HRESULT cloaked_result =
      DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));

  char buffer[256];
  std::snprintf(buffer, sizeof(buffer),
                "%s: client=%ldx%ld visible=%d minimized=%d cloaked=%lu", label,
                static_cast<long>(rect.right - rect.left),
                static_cast<long>(rect.bottom - rect.top), visible ? 1 : 0,
                minimized ? 1 : 0,
                SUCCEEDED(cloaked_result) ? static_cast<unsigned long>(cloaked)
                                          : 999UL);
  Append(std::string(buffer));
}

void LogRepeated(const char* key, const char* message) {
  if (key == nullptr || message == nullptr || !Enabled()) {
    return;
  }
  if (!ConsumeRepeatedBudget(key)) {
    return;
  }
  Append(std::string(message));
}

void LogWindowStateRepeated(const char* key, HWND window, const char* phase) {
  if (key == nullptr || !Enabled()) {
    return;
  }
  if (!ConsumeRepeatedBudget(key)) {
    return;
  }
  LogWindowState(window, phase);
}

}  // namespace startup_probe
