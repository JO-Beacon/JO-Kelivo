# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "sherpa_onnx_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

# ---------------------------------------------------------------------------
# JO-AIClient 本地接管（详见仓库本包目录下 FORK_NOTES.md）：
#
# 上游 pub 包只随包分发 x64 的预编译 DLL。ARM64 构建时这些 DLL 仍然会被原样
# 打进产物，而 ARM64 原生进程不能加载 x64 DLL，语音功能会直接失效。
#
# 本 fork 保持 Dart 代码与上游 1.12.20 逐字节一致，只改本文件：
# 按目标架构选择要随包分发的 DLL。
#
#   x64   ：用本目录随 fork 提交的 DLL，与上游 pub 包逐字节一致
#           （指纹与来源见 FORK_NOTES.md）。
#   ARM64 ：上游 pub 包与 GitHub 发布页在 1.12.20 都没有 arm64 的库，
#           但 NuGet 官方运行时包 org.k2fsa.sherpa.onnx.runtime.win-arm64
#           恰有 1.12.20。构建时按 pin 死的地址与整包 SHA256 下载并解包，
#           从中取出对应 DLL，保证可复现。
# ---------------------------------------------------------------------------

# Flutter 工具用 -A x64 / -A ARM64 生成工程；生成插件工程时据此判断目标架构。
string(TOLOWER "${CMAKE_VS_PLATFORM_NAME}" sherpa_vs_platform)
if(sherpa_vs_platform STREQUAL "arm64")
  set(SHERPA_TARGET_ARCH "arm64")
else()
  set(SHERPA_TARGET_ARCH "x64")
endif()

if(SHERPA_TARGET_ARCH STREQUAL "x64")
  # 与上游 pub 包行为一致：直接随包分发本目录的 x64 DLL。
  set(sherpa_onnx_windows_bundled_libraries
    "${CMAKE_CURRENT_SOURCE_DIR}/sherpa-onnx-c-api.dll"
    "${CMAKE_CURRENT_SOURCE_DIR}/onnxruntime.dll"
    PARENT_SCOPE
  )
else()
  set(SHERPA_NUGET_PACKAGE_URL
    "https://api.nuget.org/v3-flatcontainer/org.k2fsa.sherpa.onnx.runtime.win-arm64/1.12.20/org.k2fsa.sherpa.onnx.runtime.win-arm64.1.12.20.nupkg")
  set(SHERPA_NUGET_PACKAGE_SHA256
    "5f3e1168dae13e2d61625c0de57c63ab2719d723f884b3a2aed86e7e64d0f2bb")
  set(SHERPA_NUGET_DIR "${CMAKE_BINARY_DIR}/sherpa-onnx-win-arm64-1.12.20")

  if(NOT EXISTS "${SHERPA_NUGET_DIR}/runtimes/win-arm64/native/sherpa-onnx-c-api.dll")
    if(CMAKE_VERSION VERSION_LESS "3.18")
      message(FATAL_ERROR "ARM64 构建需要 CMake 3.18+（file(ARCHIVE_EXTRACT)），当前 ${CMAKE_VERSION}")
    endif()
    set(SHERPA_NUGET_ARCHIVE "${SHERPA_NUGET_DIR}/package.nupkg")
    file(MAKE_DIRECTORY "${SHERPA_NUGET_DIR}")
    file(DOWNLOAD
      "${SHERPA_NUGET_PACKAGE_URL}"
      "${SHERPA_NUGET_ARCHIVE}"
      STATUS sherpa_download_status
    )
    list(GET sherpa_download_status 0 sherpa_download_error)
    if(NOT sherpa_download_error EQUAL 0)
      list(GET sherpa_download_status 1 sherpa_download_message)
      message(FATAL_ERROR "下载 sherpa-onnx ARM64 运行时包失败: ${sherpa_download_message} (${SHERPA_NUGET_PACKAGE_URL})")
    endif()
    file(SHA256 "${SHERPA_NUGET_ARCHIVE}" sherpa_download_hash)
    if(NOT sherpa_download_hash STREQUAL SHERPA_NUGET_PACKAGE_SHA256)
      message(FATAL_ERROR "sherpa-onnx ARM64 运行时包 SHA256 不匹配: ${sherpa_download_hash} (期望 ${SHERPA_NUGET_PACKAGE_SHA256})")
    endif()
    file(ARCHIVE_EXTRACT INPUT "${SHERPA_NUGET_ARCHIVE}" DESTINATION "${SHERPA_NUGET_DIR}")
  endif()

  set(sherpa_onnx_windows_bundled_libraries
    "${SHERPA_NUGET_DIR}/runtimes/win-arm64/native/sherpa-onnx-c-api.dll"
    "${SHERPA_NUGET_DIR}/runtimes/win-arm64/native/onnxruntime.dll"
    PARENT_SCOPE
  )
endif()
