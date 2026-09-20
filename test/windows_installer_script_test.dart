import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Windows 安装包中文资源', () {
    late Directory root;
    late File installer;
    late File compiler;
    late File harness;
    late File cachedLanguage;
    late File installedLanguage;
    late File compilerArguments;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('joaiclient installer ');
      installer = File(
        p.join(root.path, 'scripts', 'windows', 'build_installer.ps1'),
      );
      await installer.parent.create(recursive: true);
      await File('scripts/windows/build_installer.ps1').copy(installer.path);
      await File(
        p.join(installer.parent.path, 'kelivo_installer.iss'),
      ).writeAsString('');
      final icon = File(
        p.join(root.path, 'windows', 'runner', 'resources', 'app_icon.ico'),
      );
      await icon.parent.create(recursive: true);
      await icon.writeAsBytes([]);
      await Directory(p.join(root.path, 'release')).create();
      compiler = File(p.join(root.path, 'compiler', 'ISCC.ps1'));
      await compiler.parent.create();
      compilerArguments = File(p.join(compiler.parent.path, 'arguments.json'));
      await compiler.writeAsString(r'''
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'arguments.json') -Value (ConvertTo-Json -InputObject @($args)) -Encoding UTF8
$global:LASTEXITCODE = 0
''');
      cachedLanguage = File(
        p.join(
          root.path,
          'build',
          'installer-languages',
          'ChineseSimplified.isl',
        ),
      );
      installedLanguage = File(
        p.join(compiler.parent.path, 'Languages', 'ChineseSimplified.isl'),
      );
      harness = File(p.join(root.path, 'run.ps1'));
      await harness.writeAsString(r'''
param([string]$Installer, [string]$Compiler, [string]$Source, [string]$Output)
$ErrorActionPreference = 'Stop'
function Invoke-WebRequest { throw 'DOWNLOAD_ATTEMPTED' }
try {
  & $Installer -AppVersion '0.0.0-test' -InnoSetupCompiler $Compiler -SourceDir $Source -OutputDir $Output
} catch {
  Write-Host $_.ScriptStackTrace
  throw
}
''');
    });

    tearDown(() => root.delete(recursive: true));

    Future<ProcessResult> buildInstaller() => Process.run('pwsh', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      harness.path,
      '-Installer',
      installer.path,
      '-Compiler',
      compiler.path,
      '-Source',
      p.join(root.path, 'release'),
      '-Output',
      p.join(root.path, 'dist'),
    ]);

    Future<List<dynamic>> readArguments() async =>
        jsonDecode(
              (await compilerArguments.readAsString()).replaceFirst(
                '\ufeff',
                '',
              ),
            )
            as List<dynamic>;

    test('复用已有缓存，不重复联网下载', () async {
      await cachedLanguage.parent.create(recursive: true);
      await cachedLanguage.writeAsString('cached language');
      final result = await buildInstaller();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        await readArguments(),
        contains('/DChineseMessagesFile=${cachedLanguage.path}'),
      );
    });

    test('优先使用编译器自带的语言文件', () async {
      for (final file in [cachedLanguage, installedLanguage]) {
        await file.parent.create(recursive: true);
        await file.writeAsString('language');
      }
      final result = await buildInstaller();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        await readArguments(),
        contains('/DChineseMessagesFile=${installedLanguage.path}'),
      );
    });

    test('无本地资源且下载失败时，不继续打包', () async {
      final result = await buildInstaller();
      expect(result.exitCode, isNot(0));
      expect(
        '${result.stdout}\n${result.stderr}',
        contains('DOWNLOAD_ATTEMPTED'),
      );
      expect(await compilerArguments.exists(), isFalse);
    });
  }, skip: !Platform.isWindows);
}
