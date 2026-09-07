# 本地 fork 说明（flutter_math_fork）

本目录是 pub 包 [`flutter_math_fork 0.7.4`](https://pub.dev/packages/flutter_math_fork) 的本地 fork，
自上游 Kelivo 1.2.5 基线升级引入（对应上游提交 `8f6cc748` 与 `8ecde7d0`）。

## fork 原因

pub 版在渲染数学公式时，字形 `TextStyle` 只使用 KaTeX 字体族且**不带 fontFamilyFallback**。
KaTeX 字体没有 CJK 字形，导致公式内的中文显示为豆腐块。
本 fork 让公式字形继承宿主 TextStyle 的字体回退链，中文可落到系统字体
（iOS: PingFang SC / Heiti SC / Hiragino Sans GB；Windows: Microsoft YaHei / SimHei；Android: sans-serif）。

## 相对 pub 0.7.4 的改动（仅 7 个文件）

| 文件 | 改动 |
| --- | --- |
| `lib/src/ast/options.dart` | `MathOptions` 新增 `fontFamilyFallback` 字段并贯穿构造/copyWith/工厂 |
| `lib/src/widgets/math.dart` | `Math` 从宿主 `effectiveTextStyle` 提取 `fontFamily` + `fontFamilyFallback` 传入 `MathOptions` |
| `lib/src/widgets/selectable.dart` | 同上（可选中公式分支） |
| `lib/src/render/symbols/make_symbol.dart` | 字形渲染时写入 `fontFamilyFallback`（疗效落点） |
| `lib/src/ast/nodes/enclosure.dart` | `EnclosureNode` 新增 `borderRadius`（圆角边框支持） |
| `lib/src/parser/tex/functions/katex_base/enclose.dart` | 新增 `\ovalbox` 处理器 |
| `lib/src/parser/tex/functions/katex_base/operator_name.dart` | `\operatorname` 不再把后续分组一并吞掉 |

其余文件与 pub 0.7.4 逐字节一致（行尾统一为 LF；`example/` 与 `test/` 未随 fork 收纳）。

## 升级注意

- 升级 pub 新版本时，需将上述 7 处补丁重新移植，并重跑仓库内疗效测试：
  `test/shared/widgets/markdown_with_highlight_test.dart` 中的
  "forwards Windows CJK fonts to math fallbacks" 与 "renders nested ovalbox and operatorname expressions"
  （这两例在 pub 原版下必然失败，可用来验证补丁是否就位）。
- 主工程 `pubspec.yaml` 与 `dependencies/gpt_markdown/pubspec.yaml` 必须引用**同一**本地路径，
  否则同名包出现两个来源，`pub get` 报冲突。
- 本包被 `analysis_options.yaml` 的 analyzer exclude 覆盖，不参与 `dart analyze`。

## 许可证

包本体 Apache-2.0（见 `LICENSE`）；内置 KaTeX 字体为 MIT（见 `lib/katex_fonts/LICENSE`）。均随 fork 原样保留。
