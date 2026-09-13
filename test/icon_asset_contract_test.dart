import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 图标资产的契约测试。
///
/// 这些断言不检查图标好不好看，只钉住几件容易悄悄坏掉的事：
/// 生成配置指向的文件确实存在、没有游离的图标文件、Windows 图标是多尺寸、
/// iOS 的深浅两套完整。此前“配置指向不存在的文件”与“图标只有单一尺寸”
/// 都是靠人工发现的，本测试把它们变成自动拦截。
void main() {
  // 下面的断言要解码 PNG 取像素，先准备好绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JO-AIClient icon assets', () {
    test('生成配置只有一处生效来源，且引用的文件都存在', () {
      expect(
        File('flutter_launcher_icons.yaml').existsSync(),
        isTrue,
        reason: '启动器图标配置必须存在于仓库根目录',
      );

      // pubspec 里不允许再出现同名的顶层配置段：该工具优先读独立配置文件，
      // pubspec 里的同名段不会生效，一旦残留就会误导后来者。
      expect(
        RegExp(
          r'^flutter_launcher_icons:\s*$',
          multiLine: true,
        ).hasMatch(_read('pubspec.yaml')),
        isFalse,
        reason: 'pubspec.yaml 不得残留 flutter_launcher_icons 配置段（不会生效）',
      );

      final config = _read('flutter_launcher_icons.yaml');
      final referenced = <String>{
        ...RegExp(
          r'"([^"]+\.(?:png|ico|svg))"',
        ).allMatches(config).map((m) => m.group(1)!),
        ...RegExp(
          r':\s*([^\s"#]+\.(?:png|ico|svg))',
        ).allMatches(config).map((m) => m.group(1)!),
      };
      expect(referenced, isNotEmpty, reason: '配置里应当能解析出图片路径');
      for (final path in referenced) {
        expect(File(path).existsSync(), isTrue, reason: '配置引用了缺失的文件：$path');
      }

      // iOS 图标不允许带透明通道，而母版是透明底，故必须开启压平。
      expect(config, contains('remove_alpha_ios: true'));
      expect(config, contains('background_color_ios'));
    });

    test('图标母版齐备，且派生脚本引用它们', () {
      expect(
        File('assets/icon_sources/app-icon-light.svg').existsSync(),
        isTrue,
      );
      expect(
        File('assets/icon_sources/app-icon-dark.svg').existsSync(),
        isTrue,
      );

      final script = _read('scripts/icons/build_icons.py');
      expect(script, contains('assets/icon_sources/app-icon-light.svg'));
      expect(script, contains('assets/icon_sources/app-icon-dark.svg'));

      // 托盘母版是应用图标母版的副本（浅色、深色各一份），
      // 脚本必须把两份都登记上，否则托盘的深浅跟随会失效。
      for (final name in const [
        'assets/icon_sources/app-icon-tray-light.svg',
        'assets/icon_sources/app-icon-tray-dark.svg',
      ]) {
        expect(File(name).existsSync(), isTrue, reason: '缺少托盘母版：$name');
        expect(script, contains(name));
      }

      expect(
        File('scripts/icons/render_svg.js').existsSync(),
        isTrue,
        reason: '缺少光栅化助手',
      );
    });

    test('顶层图标资产没有游离项（每个都被引用）', () {
      final assets =
          Directory('assets')
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((name) => name.endsWith('.png') || name.endsWith('.ico'))
              .toList()
            ..sort();
      expect(assets, isNotEmpty);

      final haystack = _collectReferenceText();
      for (final name in assets) {
        expect(
          haystack.contains(name),
          isTrue,
          reason: 'assets/$name 没有被任何配置或代码引用，属于游离资产',
        );
      }
    });

    test('两处 Windows 图标都是多尺寸，且含 256', () {
      for (final path in const [
        'assets/app_icon.ico',
        'windows/runner/resources/app_icon.ico',
      ]) {
        final sizes = _icoSizes(path);
        expect(
          sizes.length,
          greaterThanOrEqualTo(4),
          reason: '$path 只含 ${sizes.length} 档尺寸，缩放会发虚',
        );
        expect(sizes, contains(16), reason: '$path 缺少 16 档（托盘与列表视图使用）');
        expect(sizes, contains(256), reason: '$path 缺少 256 档（大图标视图使用）');
      }
    });

    test('iOS 与 macOS 的图标集完整，且 iOS 带深色变体', () {
      for (final iconSet in const [
        'ios/Runner/Assets.xcassets/AppIcon.appiconset',
        'macos/Runner/Assets.xcassets/AppIcon.appiconset',
      ]) {
        final manifest =
            json.decode(_read('$iconSet/Contents.json'))
                as Map<String, dynamic>;
        final images = (manifest['images'] as List)
            .cast<Map<String, dynamic>>();
        expect(images, isNotEmpty);
        for (final entry in images) {
          final filename = entry['filename'] as String?;
          if (filename == null) continue;
          expect(
            File('$iconSet/$filename').existsSync(),
            isTrue,
            reason: '清单引用了缺失的图标：$iconSet/$filename',
          );
        }
      }

      // iOS 的深色变体必须在清单里声明；只放文件不改清单不会被系统采用。
      final iosManifest =
          json.decode(
                _read(
                  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
                ),
              )
              as Map<String, dynamic>;
      final darkEntries = (iosManifest['images'] as List)
          .cast<Map<String, dynamic>>()
          .where((entry) => entry['appearances'] != null)
          .toList();
      expect(
        darkEntries.length,
        greaterThanOrEqualTo(4),
        reason: 'iOS 深色图标条目过少，系统不会按深色外观切换',
      );
    });

    test('桌面图标自带不透明的底，应用内版本保持透明', () async {
      // 桌面图标只读构建期写死的这一张，不会跟随系统明暗。透明图形放到深色
      // 桌面上会直接消失（实测达到可辨对比度的像素占比为 0），所以成品四角
      // 必须是不透明铺满的底。
      for (final path in const [
        'assets/app_icon.png',
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
        'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
      ]) {
        final corners = await _cornerAlphas(path);
        expect(
          corners,
          everyElement(greaterThan(240)),
          reason: '$path 的底没有铺满，四角仍是透明的',
        );
      }

      // 应用内展示用的是透明版：带上底就会在卡片里变成一块黑方块。
      for (final path in const [
        'assets/app_icon_light.png',
        'assets/app_icon_dark.png',
      ]) {
        final corners = await _cornerAlphas(path);
        expect(
          corners,
          everyElement(lessThan(15)),
          reason: '$path 应当是透明底，不能带底',
        );
      }

      // macOS 图标四周要留白，否则在程序坞里会比别的应用大一圈。
      final macosRatio = await _contentEdgeRatio(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
      );
      expect(macosRatio, lessThan(0.9), reason: 'macOS 图标没有留白，内容铺满了整张画布');
    });

    test('启动画面按深浅各配一版图形，且都是透明底', () async {
      // 启动画面属于程序内部：底色由系统按明暗给（白 / 黑），图形用透明版；
      // 两版必须指向不同的文件 —— 深色底上配浅色图形会直接看不见。
      final pubspec = _read('pubspec.yaml');
      expect(pubspec, contains('image: assets/start.png'));
      // 普通与 Android 12 两处 image_dark 都要指向深色版。Android 12 用的是
      // 带 android12 后缀的一套图，文件名不同但同为深色版，一并认。
      expect(
        RegExp(
          r'image_dark:\s*assets/start(_android12)?_dark\.png',
        ).allMatches(pubspec).length,
        2,
        reason: 'pubspec 的普通与 Android 12 两处 image_dark 都要指向深色版',
      );

      for (final path in const ['assets/start.png', 'assets/start_dark.png']) {
        expect(File(path).existsSync(), isTrue, reason: '缺少启动图：$path');
      }

      // 各平台产物：深浅两版都要有可见图形，且颜色必须真的不同。
      // 这两件事此前都悄悄坏过 —— 产物曾是空图，深浅也曾指向同一张。
      for (final pair in const [
        [
          'android/app/src/main/res/drawable-xxxhdpi/splash.png',
          'android/app/src/main/res/drawable-night-xxxhdpi/splash.png',
        ],
        [
          'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png',
          'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImageDark@3x.png',
        ],
      ]) {
        final light = await _averageVisibleColor(pair[0]);
        final dark = await _averageVisibleColor(pair[1]);
        expect(light, isNotNull, reason: '${pair[0]} 是空图，启动画面没有图形');
        expect(dark, isNotNull, reason: '${pair[1]} 是空图，启动画面没有图形');
        expect(
          _colorDistance(light!, dark!),
          greaterThan(30),
          reason: '${pair[1]} 与浅色版几乎同色，深浅没有各配一版',
        );
      }

      // 程序内部一律透明底：带上底会在启动画面上多出一个方块。
      for (final path in const ['assets/start.png', 'assets/start_dark.png']) {
        expect(
          await _cornerAlphas(path),
          everyElement(lessThan(15)),
          reason: '$path 应当是透明底，不能带底',
        );
      }
    });
  });
}

String _read(String path) => File(path).readAsStringSync();

/// 解码图片，取四个角的 alpha（顺序：左上、右上、左下、右下）。
Future<List<int>> _cornerAlphas(String path) async {
  final image = await _decode(path);
  final bytes = await _pixels(image);
  final width = image.width;
  final height = image.height;
  int alphaAt(int x, int y) => bytes[(y * width + x) * 4 + 3];
  return [
    alphaAt(2, 2),
    alphaAt(width - 3, 2),
    alphaAt(2, height - 3),
    alphaAt(width - 3, height - 3),
  ];
}

/// 可见内容的宽度占整张画布的比例，用来判断四周有没有留白。
Future<double> _contentEdgeRatio(String path) async {
  final image = await _decode(path);
  final bytes = await _pixels(image);
  final width = image.width;
  final height = image.height;
  var minX = width;
  var maxX = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (bytes[(y * width + x) * 4 + 3] >= 8) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }
  }
  expect(maxX, greaterThanOrEqualTo(0), reason: '$path 里没有任何可见内容');
  return (maxX - minX) / width;
}

/// 可见像素的平均色；整张图没有任何可见像素时返回 null。
Future<List<double>?> _averageVisibleColor(String path) async {
  final image = await _decode(path);
  final bytes = await _pixels(image);
  var red = 0.0, green = 0.0, blue = 0.0;
  var count = 0;
  for (var i = 0; i < image.width * image.height; i++) {
    if (bytes[i * 4 + 3] <= 128) continue;
    red += bytes[i * 4];
    green += bytes[i * 4 + 1];
    blue += bytes[i * 4 + 2];
    count++;
  }
  if (count == 0) return null;
  return [red / count, green / count, blue / count];
}

/// 两个 RGB 的欧氏距离，用来判断两版颜色是否真的不同。
double _colorDistance(List<double> a, List<double> b) {
  final dr = a[0] - b[0];
  final dg = a[1] - b[1];
  final db = a[2] - b[2];
  return math.sqrt(dr * dr + dg * dg + db * db);
}

Future<ui.Image> _decode(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<List<int>> _pixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

/// 读取 ICO 内含的各档尺寸；宽度字节为 0 表示 256。
List<int> _icoSizes(String path) {
  final bytes = File(path).readAsBytesSync();
  if (bytes.length < 6) return const [];
  final count = bytes[4] | (bytes[5] << 8);
  final sizes = <int>[];
  for (var i = 0; i < count; i++) {
    final offset = 6 + i * 16;
    if (offset >= bytes.length) break;
    final width = bytes[offset];
    sizes.add(width == 0 ? 256 : width);
  }
  return sizes;
}

/// 汇总所有可能引用图标资产的文件内容，用于查游离资产。
String _collectReferenceText() {
  const roots = <String>[
    'lib',
    'windows',
    'linux',
    'macos',
    'ios',
    'android/app',
    'web',
    'scripts',
    '.github',
  ];
  const rootFiles = <String>['pubspec.yaml', 'flutter_launcher_icons.yaml'];
  const skipDirs = <String>{
    '.git',
    'build',
    '.dart_tool',
    'node_modules',
    'ephemeral',
    'Pods',
    '.symlinks',
    '.gradle',
    'dependencies',
    '参考文件',
  };
  const textExtensions = <String>{
    '.dart',
    '.yaml',
    '.yml',
    '.json',
    '.cc',
    '.cpp',
    '.h',
    '.kts',
    '.gradle',
    '.xcconfig',
    '.plist',
    '.iss',
    '.ps1',
    '.xml',
    '.cmake',
    '.txt',
    '.html',
    '.sh',
    '.pbxproj',
    '.md',
  };

  final buffer = StringBuffer();
  void visit(Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is Directory) {
        if (skipDirs.contains(name)) continue;
        visit(entity);
      } else if (entity is File) {
        final dot = name.lastIndexOf('.');
        if (dot < 0 || !textExtensions.contains(name.substring(dot))) continue;
        try {
          buffer.writeln(entity.readAsStringSync());
        } on FileSystemException {
          // 二进制或读不到的文件直接跳过，不影响契约判断
        }
      }
    }
  }

  for (final file in rootFiles) {
    if (File(file).existsSync()) buffer.writeln(_read(file));
  }
  for (final root in roots) {
    final directory = Directory(root);
    if (directory.existsSync()) visit(directory);
  }
  return buffer.toString();
}
