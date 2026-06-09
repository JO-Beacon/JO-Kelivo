# JO-Kelivo 0.1.3+3

## Release notes 草案

```markdown
# JO-Kelivo 0.1.3+3

发布时间：待发布
基于原版 Kelivo 版本：1.1.16+60
源码获取：本 Release 页面附带的 Source code 压缩包；也可以从本仓库对应 tag 获取完整源码。

## 说明

JO-Kelivo 是基于原版 Kelivo 1.1.16 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码会（且必须）在同一 Release 页面通过 Source code 压缩包提供。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 基于上游 Kelivo 1.1.16 重新建立 JO-Kelivo 底座。
- 保留 JO-Kelivo 应用身份独立化：平台包名、Bundle ID、Windows 可执行文件名、Linux binary/application ID、Web manifest、安装器身份和运行时数据目录均与原版 Kelivo 隔离。
- 更新检测固定指向 JO-Beacon/JO-Kelivo GitHub Releases，并仅匹配 JO-Kelivo 发布产物；`.sha1` / `.sha256` 校验文件不会被当作下载包。
- 发布产物命名继续使用 `JO-Kelivo-v{version}-{platform}-{arch}-{package}.{ext}` 规则。

## 许可证合规提示

- 本项目整体继续按 GNU AGPL-3.0 发布；许可证全文见仓库根目录 LICENSE。
- 第三方依赖仍遵循其各自许可证；本项目不改变第三方依赖原有许可证条款。
- JO-Kelivo 是原版 Kelivo 的非官方改版，不代表原版作者发布、维护或背书；原项目版权归原作者及贡献者所有。
```

## 二进制文件命名规范（不含源码）

JO-Kelivo-v0.1.3+3-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.3+3-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.3+3-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.3+3-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.3+3-android-x86_64-release.apk
JO-Kelivo-v0.1.3+3-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.3+3-windows-x64-portable.zip
JO-Kelivo-v0.1.3+3-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.3+3-windows-x64-setup.exe
JO-Kelivo-v0.1.3+3-windows-x64-setup.exe.sha256
JO-Kelivo-v0.1.3+3-linux-x64-appimage.AppImage
JO-Kelivo-v0.1.3+3-linux-x64-appimage.AppImage.sha256
JO-Kelivo-v0.1.3+3-linux-x64-tar.gz
JO-Kelivo-v0.1.3+3-linux-x64-tar.gz.sha256
JO-Kelivo-v0.1.3+3-linux-x64-deb.deb
JO-Kelivo-v0.1.3+3-linux-x64-deb.deb.sha256
JO-Kelivo-v0.1.3+3-linux-x64-rpm.rpm
JO-Kelivo-v0.1.3+3-linux-x64-rpm.rpm.sha256
