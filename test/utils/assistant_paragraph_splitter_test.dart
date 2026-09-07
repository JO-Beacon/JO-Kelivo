import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/features/chat/utils/assistant_paragraph_splitter.dart';

void main() {
  test('splits on blank lines and collapses repeated separators', () {
    expect(splitAssistantParagraphs('one\n\n\n\ntwo\n\nthree'), [
      'one',
      'two',
      'three',
    ]);
  });

  test('keeps text unchanged when there is nothing to split', () {
    expect(splitAssistantParagraphs('one\ntwo'), ['one\ntwo']);
    expect(splitAssistantParagraphs('  hi  '), ['  hi  ']);
    expect(splitAssistantParagraphs(''), ['']);
  });

  test('keeps blank lines inside fenced code blocks', () {
    const text = 'intro\n\n```dart\nvoid a() {}\n\nvoid b() {}\n```\n\nend';
    expect(splitAssistantParagraphs(text), [
      'intro',
      '```dart\nvoid a() {}\n\nvoid b() {}\n```',
      'end',
    ]);
  });

  test('keeps unterminated streaming fences intact', () {
    const text = 'intro\n\n```dart\nvoid a() {}\n\nvoid b';
    expect(splitAssistantParagraphs(text), [
      'intro',
      '```dart\nvoid a() {}\n\nvoid b',
    ]);
  });

  test('keeps blank lines inside display math', () {
    const text = 'before\n\n\$\$\na = b\n\nc = d\n\$\$\n\nafter';
    expect(splitAssistantParagraphs(text), [
      'before',
      '\$\$\na = b\n\nc = d\n\$\$',
      'after',
    ]);
  });

  test('keeps list items in one bubble', () {
    const text = 'Steps:\n\n1. first\n\n2. second\n\n3. third';
    expect(splitAssistantParagraphs(text), [
      'Steps:',
      '1. first\n\n2. second\n\n3. third',
    ]);
  });

  test('keeps a heading with the paragraph it introduces', () {
    expect(splitAssistantParagraphs('## Title\n\nbody\n\ntail'), [
      '## Title\n\nbody',
      'tail',
    ]);
  });

  test('keeps indented continuations and details blocks intact', () {
    const indented = 'code:\n\n    line a\n\n    line b\n\nend';
    expect(splitAssistantParagraphs(indented), [
      'code:\n\n    line a\n\n    line b',
      'end',
    ]);

    const details =
        'intro\n\n<details>\n<summary>more</summary>\n\nbody one\n\nbody two\n'
        '</details>\n\nend';
    expect(splitAssistantParagraphs(details), [
      'intro',
      '<details>\n<summary>more</summary>\n\nbody one\n\nbody two\n</details>',
      'end',
    ]);
  });
}
