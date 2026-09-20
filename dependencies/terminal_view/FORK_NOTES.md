# 本地维护说明

## 来源与边界

本目录为 JO-AIClient 随 Kelivo `v1.2.7` 接受的 `terminal_view 0.2.1` 源码快照，上游基线提交为 `4d4448a07d033dc78ca01b8f83acb1c967f74dfa`。保留原有许可证、来源说明和版本号。

本次不修改终端生产代码，只维护测试与截图基准。

## 二倍字号截图基准更新

2026 年 9 月 19 日，在 Windows x64 的 Flutter 3.44.9、Dart 3.12.2 上，两项字号测试均在同一张 `test/src/_goldens/text_scale_factor@2x.png` 处失败。每项差异为 520 像素，占图像约 0.11%。

处理前进行了以下核对，而非看到失败就刷新图片：

- 渲染样式、绘制器、段落缓存、终端布局源码，以及一倍／二倍字号基准，均与上述 Kelivo tag 相同；不是本仓库这轮修改了渲染实现。
- 用段落行高、基线、文字范围做数值实验。现行二倍字号行高为 26，文字范围为 0 至 26，没有顶部裁切。仅取消 strut 和更改 leading 分配的对照不能使旧图匹配，因此不能靠撤回对齐规则解决。
- 新增 `test/src/ui/paragraph_scaling_test.dart`，将段落缓存布局与 Flutter 标准 `TextPainter` 以及终端网格比较，覆盖 1、1.5、2、3 倍字号、缓存命中，以及二倍字号文字不得越出行边界。
- 保留并扩展原截图测试：从一倍放大到二倍后，再还原到一倍，仍必须逐像素匹配原有一倍截图。继承系统字号的二倍测试使用同一张二倍基准。

据此将问题限定为“继承的截图基准与当前验证环境不匹配”，没有据此改动生产渲染。尚未追溯到生成旧图的确切 Flutter 版本，也不把此结论扩大为任意字体、任意平台均已完成视觉验收。

通过以下命令仅重新生成受影响的二倍字号基准。工作目录为本依赖目录：

```powershell
flutter test --no-pub test/src/terminal_view_test.dart --plain-name "TerminalView.textScaler can obtain textScaler from parent" --update-goldens
```

一倍字号原图 SHA-256 保持不变：

```text
4e687e1d3d29f561296e2c3aba6668ef2db6ca873d0a7f2e61adffb95f21d36c
```

二倍字号原图 SHA-256：

```text
68fb45988c5005b5deeab4abca6d8d07ee9f06cd838156552b9cd4fcfd1c2f77
```

二倍字号新图 SHA-256：

```text
244539db20b77255b5d7a5dfa88eb9fa2e5f909c12259dfcfdd6502d0c4ef777
```

未修改像素比较器、没有提高误差容忍度、没有跳过这两项失败测试。探针已移出测试集，避免将故意失败的对照用例当作正式回归。

## 本次验证

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

- 本依赖分析无问题。
- 本依赖全量测试为 203 通过、2 跳过、0 失败。
- 两项跳过是原有的 macOS 专属截图测试，本次在 Windows 上未执行。
- 本次没有修改生产代码，未单独重建依赖原生库。
- 其他平台的截图匹配尚未复跑；未来升级 Flutter 或重新生成基准时，必须先复查字体布局约束，不能直接接受所有新图。
