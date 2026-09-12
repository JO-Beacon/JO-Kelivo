# FORK_NOTES — sherpa_onnx_windows 本地接管说明

## 来源与版本

- 上游：pub.dev 的 `sherpa_onnx_windows` **1.12.20**（随 `sherpa_onnx 1.12.20` 一同锁定的
  Windows FFI 插件），复制自本机 pub 缓存
  `AppData\Local\Pub\Cache\hosted\pub.dev\sherpa_onnx_windows-1.12.20`。
- Dart 代码（`lib/`）、`pubspec.yaml`、`CHANGELOG.md`、`LICENSE` 与上游**逐字节一致**，
  未做任何修改。本 fork 只改了两处：`windows/CMakeLists.txt` 与本说明文件。

## 为什么接管

上游只随包分发 **x64** 的预编译 DLL。构建 Windows ARM64 版时这些 x64 DLL 仍会被
原样打进产物，而 ARM64 原生进程不能加载 x64 DLL —— 语音识别（离线语音）在
ARM 版上会直接失效。要出原生 ARM64 版，必须换成 arm64 的 DLL。

上游 sherpa-onnx 在 GitHub 发布页的 v1.12.20 资产里**没有** win-arm64 包（只有
x64 / x86 / CUDA-x64，2026-09-12 用 GitHub API 核实）；但 NuGet 官方运行时包
`org.k2fsa.sherpa.onnx.runtime.win-arm64` **恰有 1.12.20**（NuGet flatcontainer
版本列表核实）。本 fork 据此按架构取 DLL，不混版本。

## Windows DLL 的两套来源

| 架构 | 来源 | 落点 |
|---|---|---|
| x64 | 本目录 `windows/` 下随 fork 提交的 DLL（与上游 pub 包逐字节一致） | 构建时直接随包分发 |
| ARM64 | NuGet `org.k2fsa.sherpa.onnx.runtime.win-arm64` **1.12.20**，构建时下载整包并校验 SHA256 后解包 | `build` 目录缓存，随包分发其中两个 DLL |

刻意不做的两件事：

1. **不把 x64 DLL 换成 NuGet win-x64 包里的同名文件。** 对比过指纹：`onnxruntime.dll`
   两者一致，但 `sherpa-onnx-c-api.dll` 大小相同、内容不同（构建签名或打包差异，
   无法证明行为等价）。x64 是当前发布在用的字节，不动。
2. **不把 ARM64 DLL 提交进仓库。** 构建时按 pin 死的地址 + 整包 SHA256 下载，
   可复现且仓库不增重（整包 5,525,978 字节）。仓库里已有
   `webview_windows` 构建时从 NuGet 拉依赖的先例。

## 指纹记录（2026-09-12 采集）

x64（本目录 `windows/`，来源 = 上游 pub 包，随 fork 提交）：

```
onnxruntime.dll                  10951200  sha256 b9dba35ec85d49c0...（与 NuGet win-x64 包一致）
sherpa-onnx-c-api.dll             3856384  sha256 bcefe7fe78b6391a...（与 NuGet win-x64 包不同，保留 pub 版）
sherpa-onnx-cxx-api.dll            196608  sha256 e7eaeff6e48d6d2e...
onnxruntime_providers_shared.dll    22560  sha256 ba645bf03bd60df6...
```

（后两个不在随包清单里，仅为对照记录。）

ARM64（NuGet 运行时包，构建时下载）：

```
包: org.k2fsa.sherpa.onnx.runtime.win-arm64 1.12.20
URL: https://api.nuget.org/v3-flatcontainer/org.k2fsa.sherpa.onnx.runtime.win-arm64/1.12.20/org.k2fsa.sherpa.onnx.runtime.win-arm64.1.12.20.nupkg
整包 SHA256: 5f3e1168dae13e2d61625c0de57c63ab2719d723f884b3a2aed86e7e64d0f2bb
包内取用:
  runtimes/win-arm64/native/sherpa-onnx-c-api.dll   3970560
  runtimes/win-arm64/native/onnxruntime.dll        10789296
```

## 与主仓的联动

- 根 `pubspec.yaml` 的 `dependency_overrides.sherpa_onnx_windows` 已指向本目录。
- 主仓 AGENTS.md / CLAUDE.md 的本地 path 依赖清单已登记本包。
- 升级上游版本时：核对上游是否开始随包发 arm64 DLL；若有，可考虑撤销本 fork。
  同时注意主仓对 `sherpa_onnx 1.12.20` 的锁版理由（macOS 部署目标），那是
  另一个包（sherpa_onnx_macos）的约束，与本 fork 无关但升级时必须一起评估。
