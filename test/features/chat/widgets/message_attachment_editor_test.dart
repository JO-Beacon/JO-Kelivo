import '../../../support/business_test_harness.dart';

import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/chat/widgets/message_attachment_editor.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  Widget harness({
    required List<MessagePart> parts,
    required ValueChanged<List<MessagePart>> onChanged,
    required MessageAttachmentPicker picker,
  }) {
    return ChangeNotifierProvider(
      create: (_) => SettingsProvider(createBusinessTestPreferences()),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageAttachmentEditor(
            parts: parts,
            onChanged: onChanged,
            picker: picker,
          ),
        ),
      ),
    );
  }

  testWidgets('remove keeps opaque parts and reports complete part list', (
    tester,
  ) async {
    const opaque = UnknownPart(rawKind: 'future', payload: '{"v":1}');
    List<MessagePart>? changed;
    await tester.pumpWidget(
      harness(
        parts: const <MessagePart>[
          TextPart('body'),
          ImagePart(uri: 'a.png'),
          opaque,
          FilePart(uri: 'b.pdf', name: 'b.pdf'),
        ],
        onChanged: (parts) => changed = parts,
        picker: (_, {required imagesOnly, required single}) async =>
            const <MessagePart>[],
      ),
    );

    await tester.tap(find.byIcon(Lucide.X).first);
    await tester.pump();

    expect(changed, isNotNull);
    expect(changed!.map((part) => part.kind), <String>[
      'text',
      'future',
      'file',
    ]);
    expect(identical(changed![1], opaque), isTrue);
  });

  testWidgets('replace and add use structured picker results', (tester) async {
    final requests = <({bool imagesOnly, bool single})>[];
    var call = 0;
    List<MessagePart>? changed;
    await tester.pumpWidget(
      harness(
        parts: const <MessagePart>[
          TextPart('body'),
          ImagePart(uri: 'old.png'),
        ],
        onChanged: (parts) => changed = parts,
        picker: (_, {required imagesOnly, required single}) async {
          requests.add((imagesOnly: imagesOnly, single: single));
          call++;
          return call == 1
              ? const <MessagePart>[
                  ImagePart(uri: 'new.png', mime: 'image/png'),
                ]
              : const <MessagePart>[FilePart(uri: 'new.pdf', name: 'new.pdf')];
        },
      ),
    );

    await tester.tap(find.byIcon(Lucide.RefreshCw));
    await tester.pump();
    expect((changed![1] as ImagePart).uri, 'new.png');

    await tester.tap(find.text('Add file'));
    await tester.pump();
    expect(changed!.map((part) => part.kind), <String>[
      'text',
      'image',
      'file',
    ]);
    expect(requests, <({bool imagesOnly, bool single})>[
      (imagesOnly: true, single: true),
      (imagesOnly: false, single: false),
    ]);
  });

  testWidgets('cancelled picker does not report a change', (tester) async {
    var changeCount = 0;
    await tester.pumpWidget(
      harness(
        parts: const <MessagePart>[TextPart('body')],
        onChanged: (_) => changeCount++,
        picker: (_, {required imagesOnly, required single}) async =>
            const <MessagePart>[],
      ),
    );

    await tester.tap(find.text('Add image'));
    await tester.pump();

    expect(changeCount, 0);
    expect(find.text('No attachments'), findsOneWidget);
  });
}
