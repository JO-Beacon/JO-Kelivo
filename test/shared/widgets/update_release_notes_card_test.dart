import 'package:Kelivo/shared/widgets/update_release_notes_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tapping the release notes card invokes its callback', (
    tester,
  ) async {
    var tapCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateReleaseNotesCard(
            title: 'Update: 1.0.1',
            notes: 'Release notes',
            onTap: () => tapCount++,
            haptics: false,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Release notes'));
    await tester.pump();

    expect(tapCount, 1);
  });
}
