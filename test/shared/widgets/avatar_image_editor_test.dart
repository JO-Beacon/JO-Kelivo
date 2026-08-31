import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/models/avatar_transform.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/assistant_list_item.dart';
import 'package:Kelivo/features/home/widgets/assistant_avatar.dart';
import 'package:Kelivo/shared/widgets/avatar_image_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

Future<void> _pumpEditor(WidgetTester tester, String path) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAvatarImageEditor(context, path),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late Directory tempDir;
  late String imagePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('avatar_editor_test');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
      'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    imagePath = '${tempDir.path}${Platform.pathSeparator}avatar.png';
    File(imagePath).writeAsBytesSync(png);
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    tempDir.deleteSync(recursive: true);
  });

  testWidgets('keeps the complete source visible without an explicit crop', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AvatarImage(path: 'missing-avatar.png', size: 64),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('keeps the complete source visible for a default edit result', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AvatarImage(
          path: 'missing-avatar.png',
          size: 64,
          transform: AvatarTransform(),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('preserves the source ratio after an explicit crop', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AvatarImage(
          path: 'missing-avatar.png',
          size: 64,
          transform: AvatarTransform(width: 0.5, height: 0.5),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('list avatars preserve the stored transform', (tester) async {
    final item = AssistantListItem(
      id: 'assistant',
      name: 'Assistant',
      avatar: imagePath,
      avatarTransform: const AvatarTransform(),
      promptPreview: '',
      sortOrder: 0,
    );
    await tester.pumpWidget(
      MaterialApp(home: AssistantAvatar.fromListItem(item: item, size: 64)),
    );

    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
  });

  testWidgets('selection avatars preserve an explicit crop transform', (
    tester,
  ) async {
    final assistant = Assistant(
      id: 'assistant',
      name: 'Assistant',
      avatar: imagePath,
      avatarTransform: const AvatarTransform(width: 0.5, height: 0.5),
    );
    await tester.pumpWidget(
      MaterialApp(home: AssistantAvatar(assistant: assistant, size: 64)),
    );

    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
  });

  testWidgets('shows only the desktop crop hint on desktop platforms', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _pumpEditor(tester, 'missing-avatar.png');

      final l10n = AppLocalizations.of(tester.element(find.text('open')))!;
      expect(find.text(l10n.avatarEditorCropHintDesktop), findsOneWidget);
      expect(find.text(l10n.avatarEditorCropHintMobile), findsNothing);
      Navigator.of(
        tester.element(find.text(l10n.avatarEditorCropHintDesktop)),
      ).pop();
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shows only the mobile crop hint on mobile platforms', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await _pumpEditor(tester, 'missing-avatar.png');

      final l10n = AppLocalizations.of(tester.element(find.text('open')))!;
      expect(find.text(l10n.avatarEditorCropHintMobile), findsOneWidget);
      expect(find.text(l10n.avatarEditorCropHintDesktop), findsNothing);
      Navigator.of(
        tester.element(find.text(l10n.avatarEditorCropHintMobile)),
      ).pop();
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
