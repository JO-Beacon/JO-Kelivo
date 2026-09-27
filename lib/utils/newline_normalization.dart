import 'package:flutter/services.dart';

/// 把 `\r\n`（CRLF）与孤立的 `\r`（CR）统一成 `\n`（LF）。
///
/// Windows 剪贴板给出的换行是 `\r\n`，部分来源还可能只剩一个 `\r`。
/// Flutter 里孤立的 `\r` **不产生换行**，会变成看不见、却需要删两次的字符；
/// `\r\n` 又可能把 `\r` 渲染成一个空格。键入的 Enter 本身是 `\n`，只有粘贴
/// 这类外部文本会带进来，所以统一在输入边界做归一化。
String normalizeNewlines(String text) {
  if (!text.contains('\r')) return text;
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/// 覆盖键入与粘贴的换行归一化输入格式器。
///
/// 框架内置的粘贴同样会经过 [TextInputFormatter]，因此这个格式器能覆盖
/// 默认粘贴路径；绕开输入系统直接改 controller 的路径需要显式调用
/// [normalizeNewlines]。
class NormalizeNewlinesFormatter extends TextInputFormatter {
  const NormalizeNewlinesFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final source = newValue.text;
    if (!source.contains('\r')) return newValue;
    final text = normalizeNewlines(source);

    int mapOffset(int offset) {
      final clamped = offset.clamp(0, source.length);
      return normalizeNewlines(source.substring(0, clamped)).length;
    }

    final selection = newValue.selection;
    final mappedSelection = selection.isValid
        ? TextSelection(
            baseOffset: mapOffset(selection.baseOffset),
            extentOffset: mapOffset(selection.extentOffset),
            affinity: selection.affinity,
          )
        : selection;
    return TextEditingValue(text: text, selection: mappedSelection);
  }
}
