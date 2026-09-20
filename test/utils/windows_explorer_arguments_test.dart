import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:Kelivo/utils/windows_explorer_arguments.dart';

void main() {
  test('托管工作区混合分隔符转换为 Windows 目录路径', () {
    expect(
      windowsExplorerArguments(
        r'C:\Users\tester\AppData\Roaming\JO-AIClient/workspaces/project/files',
      ),
      [r'C:\Users\tester\AppData\Roaming\JO-AIClient\workspaces\project\files'],
    );
  });

  test('中文、空格和 shell 特殊字符保留为一个原样参数', () {
    expect(windowsExplorerArguments('C:/项目 空间/文件夹 & 数据, 1/files'), [
      r'C:\项目 空间\文件夹 & 数据, 1\files',
    ]);
  });

  test('文件选中也转换分隔符，不把文件当作目录打开', () {
    expect(windowsExplorerArguments('C:/项目 空间/report.txt', select: true), [
      r'/select,C:\项目 空间\report.txt',
    ]);
  });

  test('已规范化路径不改变大小写或增加手工引号', () {
    const path = r'C:\Data Folder\MixedCase';
    expect(windowsExplorerArguments(path), [path]);
  });

  test('保留 UNC 根路径并规范化子目录', () {
    expect(windowsExplorerArguments(r'\\server\shared folder/中文/files'), [
      r'\\server\shared folder\中文\files',
    ]);
  });

  test('处理目录回退和磁盘根目录', () {
    expect(windowsExplorerArguments('C:/base/../项目/./files/'), [
      r'C:\项目\files',
    ]);
    expect(windowsExplorerArguments('C:/'), [r'C:\']);
  });

  test('相对路径在调用边界转为绝对路径', () {
    expect(windowsExplorerArguments('workspace/files'), [
      p.windows.join(Directory.current.path, 'workspace', 'files'),
    ]);
  }, skip: !Platform.isWindows);

  test('空路径和 NUL 路径明确拒绝，不能意外打开默认目录', () {
    for (final path in ['', 'C:/workspace/\u0000files']) {
      expect(() => windowsExplorerArguments(path), throwsArgumentError);
    }
  });
  test('规范化后的目录和文件仍指向同一份本机数据', () async {
    final temp = await Directory.systemTemp.createTemp('joaiclient-explorer-');
    addTearDown(() => temp.delete(recursive: true));
    final dir = await Directory(
      '${temp.path}/workspaces/项目 空间/files',
    ).create(recursive: true);
    final marker = await File(
      '${dir.path}/marker.txt',
    ).writeAsString('same workspace');
    final directoryArgument = windowsExplorerArguments(dir.path).single;
    expect(await Directory(directoryArgument).exists(), isTrue);
    expect(
      await File(p.join(directoryArgument, 'marker.txt')).readAsString(),
      'same workspace',
    );
    final fileArgument = windowsExplorerArguments(
      marker.path,
      select: true,
    ).single;
    expect(
      await File(fileArgument.substring('/select,'.length)).readAsString(),
      'same workspace',
    );
  }, skip: !Platform.isWindows);
}
