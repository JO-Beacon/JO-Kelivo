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

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包，或项目仓库 https://github.com/JO-Beacon/JO-Kelivo 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

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

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包，或项目仓库 https://github.com/JO-Beacon/JO-Kelivo 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 修复 Windows 上原版 Kelivo 与 JO-Kelivo 同时运行时，双击 JO-Kelivo 快捷方式可能误唤起原版 Kelivo 窗口的问题。
- Windows 单实例唤起逻辑改为保留 Flutter 默认窗口类，并使用 JO-Kelivo 专属 Win32 窗口属性过滤自身窗口，避免破坏 `bitsdojo_window` 导致白屏。
- Windows 安装器构建脚本现在可自动定位用户级或系统级 Inno Setup 6，减少本地构建安装包时的路径问题。

## 许可证合规提示

- 第三方依赖仍遵循其各自许可证；本项目整体继续按 GNU AGPL-3.0 发布。
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

## SHA-256

```text
fc77d4e631a8ae9262957fb477225abc350e1954ec8a228e6f9269d88573fc6a  JO-Kelivo-v0.1.1+1-android-arm64-v8a-release.apk
5cebd330cfdc1f5762e00c7d4a7a615401cd7cb82c7c1a7fe1c903aa7f246ec9  JO-Kelivo-v0.1.1+1-android-armeabi-v7a-release.apk
6665c7ab7670701daac8594834bcddedde1d0f71a41a547cf5b8c23c43af88cf  JO-Kelivo-v0.1.1+1-android-x86_64-release.apk
8c0cfec448846ece706d5aeb14affd76ff694cb0e953c9a9ed1b2266a9100857  JO-Kelivo-v0.1.1+1-windows-x64-portable.zip
6c42d65e768ff046b404e67b188511ba68c9ae6946ce454ef815c1eab956e74f  JO-Kelivo-v0.1.1+1-windows-x64-setup.exe
```
