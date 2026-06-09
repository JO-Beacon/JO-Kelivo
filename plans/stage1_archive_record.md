# 阶段一归档记录

## 归档目标

按 `plans/JO-Kelivo 基于上游 1.1.16 的迁移总计划.md` 的阶段一要求，将当前主项目保存为旧 JO 参考版本，供后续基于上游 1.1.16 迁移时查回平台身份、更新源、功能补丁、测试和文档。

## 归档位置

```text
参考文件/改版1.1.15/JO-Kelivo-0.1.2+2/
```

## 已归档内容

已复制当前项目中的源码、配置、平台目录、文档、测试、本地路径依赖和资源，包括：

- `维护者改版记录.md`
- `README.md`
- `Release日志.md`
- `pubspec.yaml`
- `pubspec.lock`
- `l10n.yaml`
- `.gitignore`
- `.metadata`
- `AGENTS.md`
- `CLAUDE.md`
- `analysis_options.yaml`
- `devtools_options.yaml`
- `flutter_launcher_icons.yaml`
- `LICENSE`
- `.github/`
- `android/`
- `ios/`
- `macos/`
- `windows/`
- `linux/`
- `web/`
- `lib/`
- `test/`
- `scripts/`
- `optimize_chat_archive/`
- `dependencies/`
- `assets/`
- `docs/`
- `docx/`

## 已排除内容

归档时未复制以下目录：

- `plans/`
- `.dart_tool/`
- `build/`
- `.vscode/`
- `.idea/`
- `历史Release二进制文件/`

## 验证结果

已验证归档目录存在，并检查了阶段一要求的关键项。验证结果：

- 阶段一要求的主文档、配置、平台目录、源码目录、测试目录、脚本目录、本地路径依赖、资源和文档均存在。
- `plans/` 未进入归档副本，后续迁移计划仍保留在主项目。
- `.dart_tool/`、`build/`、IDE 缓存和历史 Release 二进制产物未进入归档副本。
- 抽样验证通过：`lib/main.dart`、`lib/l10n/app_en.arb`、`dependencies/mcp_client/pubspec.yaml`、`dependencies/tray_manager/packages/tray_manager/lib/tray_manager.dart`、`android/app/build.gradle.kts`、`windows/runner/main.cpp`、`macos/Runner/Info.plist`、`linux/runner/main.cc`、`web/manifest.json`。
- 归档副本当前文件数：5981。

## 后续入口条件

阶段一已完成。后续阶段二可以从以下前提开始：

- 主项目当前 JO 版本已经在 `参考文件/改版1.1.15/JO-Kelivo-0.1.2+2/` 形成对照副本。
- `plans/` 保持在主项目内，不参与迁移覆盖。
- 阶段二应只执行上游 1.1.16 替换和纯 JO 化，不混入业务功能补丁。


