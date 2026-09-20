import 'dart:io';

import 'package:Kelivo/core/models/chat_input_data.dart';
import 'package:Kelivo/features/home/services/file_upload_service.dart';
import 'package:Kelivo/features/home/widgets/chat_input_bar.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:Kelivo/utils/image_compressor.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _StaticPathPicker extends FilePicker {
  _StaticPathPicker(this.paths);
  final List<String> paths;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    for (final path in paths)
      PlatformFile(name: File(path).uri.pathSegments.last, path: path, size: 0),
  ]);
}

class _MediaController extends ChatInputBarController {
  final queued = <String>[];

  @override
  void enqueueImages(
    List<String> paths,
    ImageCompressConfig config, {
    bool deleteSourcesAfterProcessing = false,
  }) => queued.addAll(paths);
}

void main() {
  const channel = MethodChannel('plugins.hunghd.vn/image_cropper');

  for (final scenario in ['success', 'disabled', 'cancel', 'error', 'mixed']) {
    testWidgets('image cropping: $scenario', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final directory = Directory.systemTemp.createTempSync('crop_test_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final source = File('${directory.path}/source.png')..writeAsBytesSync([]);
      final second = File('${directory.path}/second.png')..writeAsBytesSync([]);
      final cropped = '${directory.path}/cropped.png';
      FilePicker.platform = _StaticPathPicker([
        source.path,
        if (scenario == 'mixed') second.path,
      ]);
      var cropCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        cropCalls++;
        if (scenario == 'error' || (scenario == 'mixed' && cropCalls == 1)) {
          throw PlatformException(
            code: 'crop_failed',
            message: 'Cannot decode',
          );
        }
        return scenario == 'cancel' ? null : cropped;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      final media = _MediaController();
      final service = FileUploadService(
        getContext: () => context,
        mediaController: media,
        isImageCropperEnabled: () => scenario != 'disabled',
        getImageCompressConfig: () => const ImageCompressConfig(
          enabled: false,
          quality: 100,
          maxLongEdge: 0,
          includeTransparent: false,
        ),
      );

      await tester.runAsync(service.onPickPhotos);
      await tester.pump();
      final notifications = AppSnackBarManager().activeToasts;
      // 清理通知计时器，即使后续断言失败也不留下未完成的动画。
      AppSnackBarManager().dismissAll();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect(
        cropCalls,
        scenario == 'disabled' ? 0 : (scenario == 'mixed' ? 2 : 1),
      );
      expect(media.queued, switch (scenario) {
        'disabled' => [source.path],
        'success' || 'mixed' => [cropped],
        _ => isEmpty,
      });
      if (scenario == 'error' || scenario == 'mixed') {
        expect(notifications, hasLength(1));
        expect(notifications.single.notification.type, NotificationType.error);
        expect(
          notifications.single.notification.message,
          contains('source.png'),
        );
        expect(
          notifications.single.notification.message,
          contains('Cannot decode'),
        );
      } else {
        expect(notifications, isEmpty);
      }
    });
  }
  // ---- 以下两个用例来自上游 P5（fe8cb760 新增的 file_upload_service_test）----
  // 它们测的是「工作区模式下文件选择器的参数透传」，与本文件上半部分的
  // 「选图片裁剪流程」互补，故两份并存。

  test(
    'picker follows workspace binding without enabling byte buffering',
    () async {
      final picker = _RecordingPicker();
      FilePicker.platform = picker;
      var bound = false;
      final service = FileUploadService(
        getContext: () => throw StateError('Cancelled picker needs no UI'),
        mediaController: ChatInputBarController(),
        isImageCropperEnabled: () => false,
        getImageCompressConfig: () => throw StateError('No images selected'),
        hasWorkspace: () => bound,
      );
      await service.onPickFiles();
      expect(picker.type, FileType.custom);
      expect(picker.extensions, containsAll(['pdf', 'docx', 'txt']));
      expect(picker.extensions, isNot(contains('apk')));
      bound = true;
      await service.onPickFiles();
      expect(picker.type, FileType.any);
      expect(picker.extensions, isNull);
      expect(picker.buffered, isFalse);
      expect(
        service.inferMimeByExtension('Dockerfile'),
        'application/octet-stream',
      );
    },
  );

  test(
    'archives need a workspace; media and cloud-sandbox data keep existing routes',
    () {
      DocumentAttachment file(String name, String mime) =>
          DocumentAttachment(path: '/upload/$name', fileName: name, mime: mime);
      expect(
        FileUploadService.supportsWithoutWorkspace(
          file('app.apk', 'application/octet-stream'),
        ),
        isFalse,
      );
      expect(
        FileUploadService.supportsWithoutWorkspace(
          file('notes.pdf', 'application/pdf'),
        ),
        isTrue,
      );
      expect(
        FileUploadService.supportsWithoutWorkspace(
          file('song.m4a', 'audio/mp4'),
        ),
        isTrue,
      );
      expect(
        FileUploadService.supportsWithoutWorkspace(
          file('data.xlsx', 'application/octet-stream'),
        ),
        isTrue,
      );
    },
  );
}

/// 记录一次调用收到的参数（上游 P5 测试用）。
class _RecordingPicker extends FilePicker {
  FileType? type;
  List<String>? extensions;
  bool? buffered;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    this.type = type;
    extensions = allowedExtensions;
    buffered = withData;
    return null;
  }
}
