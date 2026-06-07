# 0.1.0+0

## Release notes

```markdown
# JO-Kelivo 0.1.0+0

发布时间：2026-06-06
基于原版 Kelivo 版本：1.1.15+52
源码获取：本 Release 页面附带的 Source code 压缩包

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 许可证合规提示

- 第三方依赖仍遵循其各自许可证；本项目整体继续按 GNU AGPL-3.0 发布。
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.0+0-android-x86_64-release.apk
JO-Kelivo-v0.1.0+0-android-x86_64-release.apk.sha1
JO-Kelivo-v0.1.0+0-windows-x64-portable.zip
JO-Kelivo-v0.1.0+0-windows-x64-setup.exe
JO-Kelivo-v0.1.0+0-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.0+0-android-arm64-v8a-release.apk.sha1
JO-Kelivo-v0.1.0+0-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.0+0-android-armeabi-v7a-release.apk.sha1

---

# 0.1.1+1

## Release notes

```markdown
# JO-Kelivo 0.1.1+1

发布时间：2026-06-06
基于原版 Kelivo 版本：1.1.15+52
源码获取：本 Release 页面附带的 Source code 压缩包

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 修复 Windows 上原版 Kelivo 与 JO-Kelivo 同时运行时，双击 JO-Kelivo 快捷方式可能误唤起原版 Kelivo 窗口的问题。
- Windows 单实例唤起逻辑改为保留 Flutter 默认窗口类，并使用 JO-Kelivo 专属 Win32 窗口属性过滤自身窗口，避免破坏 `bitsdojo_window` 导致白屏。
- Windows 安装器构建脚本现在可自动定位用户级或系统级 Inno Setup 6，减少本地构建安装包时的路径问题。

## 许可证合规提示

- 第三方依赖仍遵循其各自许可证；本项目整体继续按 GNU AGPL-3.0 发布。

## SHA-256

fc77d4e631a8ae9262957fb477225abc350e1954ec8a228e6f9269d88573fc6a  JO-Kelivo-v0.1.1+1-android-arm64-v8a-release.apk
5cebd330cfdc1f5762e00c7d4a7a615401cd7cb82c7c1a7fe1c903aa7f246ec9  JO-Kelivo-v0.1.1+1-android-armeabi-v7a-release.apk
6665c7ab7670701daac8594834bcddedde1d0f71a41a547cf5b8c23c43af88cf  JO-Kelivo-v0.1.1+1-android-x86_64-release.apk
8c0cfec448846ece706d5aeb14affd76ff694cb0e953c9a9ed1b2266a9100857  JO-Kelivo-v0.1.1+1-windows-x64-portable.zip
6c42d65e768ff046b404e67b188511ba68c9ae6946ce454ef815c1eab956e74f  JO-Kelivo-v0.1.1+1-windows-x64-setup.exe
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.1+1-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.1+1-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.1+1-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.1+1-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.1+1-android-x86_64-release.apk
JO-Kelivo-v0.1.1+1-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.1+1-windows-x64-portable.zip
JO-Kelivo-v0.1.1+1-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.1+1-windows-x64-setup.exe
JO-Kelivo-v0.1.1+1-windows-x64-setup.exe.sha256


---

# 0.1.2+2

## Release notes

```markdown
# JO-Kelivo 0.1.2+2

发布时间：2026-06-07
基于原版 Kelivo 版本：1.1.15+52
源码获取：本 Release 页面附带的 Source code 压缩包；也可从本仓库对应 tag 获取完整源码。

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包或本仓库对应 tag 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 新增“聊天区域拉宽”显示设置：移动端宽屏/平板布局和桌面端均可选择让聊天消息列表与输入栏尽量占满可用宽度；默认关闭，保留原有窄宽度阅读体验。
- 修复新版本检测来源：JO-Kelivo 现在固定检查 JO-Beacon/JO-Kelivo 的 GitHub Releases，不再跟随原版 Kelivo 更新源。
- 更新检测会按当前平台匹配 JO-Kelivo Release assets，并避免把 `.sha1` / `.sha256` 校验文件误作为更新包。

## 许可证合规提示

- 本项目整体继续按 GNU AGPL-3.0 发布；许可证全文见仓库根目录 LICENSE。
- 本 Release 若附带 Android APK、Windows 安装包或 Windows 便携包等二进制产物，对应源代码会（且必须）在同一 Release 页面通过 Source code 压缩包或清晰链接提供。
- 第三方依赖仍遵循其各自许可证；本项目不改变第三方依赖原有许可证条款。
- JO-Kelivo 是原版 Kelivo 的非官方改版，不代表原版作者发布、维护或背书；原项目版权归原作者及贡献者所有。

## SHA-256

986224199efa6c914ac8837ef20e2bc365464282a9f0acf334d32ecad02b7084  JO-Kelivo-v0.1.2+2-android-arm64-v8a-release.apk
d71c592820b69efceb3c6d36f9778fa1fbcb04840aefdbc84c0cfb7219bc26fb  JO-Kelivo-v0.1.2+2-android-armeabi-v7a-release.apk
7e0717c2f9735490b3bd34bcd83e751bdcd3751999000125aad62a4880c885c2  JO-Kelivo-v0.1.2+2-android-x86_64-release.apk
1da64553792e6e1a217114aa74788b04125b74bccffbf02569d6f76abbfa2e09  JO-Kelivo-v0.1.2+2-windows-x64-portable.zip
259c600201f5505898c8663458752b14dca502a68d78eaf9426f96aac3b0909a  JO-Kelivo-v0.1.2+2-windows-x64-setup.exe
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.2+2-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.2+2-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.2+2-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.2+2-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.2+2-android-x86_64-release.apk
JO-Kelivo-v0.1.2+2-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.2+2-windows-x64-portable.zip
JO-Kelivo-v0.1.2+2-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.2+2-windows-x64-setup.exe
JO-Kelivo-v0.1.2+2-windows-x64-setup.exe.sha256
