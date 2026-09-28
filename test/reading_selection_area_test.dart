import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/widgets/reading_selection_area.dart';

/// Text the reader menu asked the platform to put on the clipboard.
final List<String> _copied = [];

/// Pumps [child] the way a reader does: Russian strings, and the Android text
/// selection the handles and the toolbar are drawn for.
Future<void> _open(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

/// Runs a widget test with the platform the readers' selection is written
/// against, and hands the override back before the framework checks it.
void selectionTest(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// Records clipboard writes instead of letting them reach the OS.
void _interceptClipboard(WidgetTester tester) {
  _copied.clear();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        _copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
}

/// Marks [word] the way a reader does: press and hold the word itself.
Future<void> _mark(WidgetTester tester, String word) async {
  await tester.longPress(find.text(word));
  await tester.pumpAndSettle();
}

/// Holds down inside a line of text, [fraction] of the way across it — the
/// point a thumb lands on when it means a word rather than the space after it.
Future<void> _markLine(
  WidgetTester tester,
  String line,
  double fraction,
) async {
  final box = tester.getRect(find.text(line));
  await tester.longPressAt(
    Offset(box.left + box.width * fraction, box.center.dy),
  );
  await tester.pumpAndSettle();
}

void main() {
  selectionTest('a long press offers copy, copy all, select all, translate', (
    tester,
  ) async {
    String? translated;
    await _open(
      tester,
      ReadingSelectionArea(
        translatorEnabled: true,
        onTranslateSelection: (text) => translated = text,
        child: const Center(child: Text('the quick brown fox')),
      ),
    );

    await _markLine(tester, 'the quick brown fox', 0.9);

    expect(find.text('Копировать'), findsOne);
    expect(find.text('Копировать всё'), findsOne);
    expect(find.text('Выбрать всё'), findsOne);
    expect(find.text('Перевести'), findsOne);
    expect(translated, isNull);
  });

  selectionTest('every action stays on the screen at phone width', (
    tester,
  ) async {
    // Four Russian labels never fit one row of a small phone. The platform
    // toolbar answered that by hiding what was left behind an overflow button;
    // the reader's menu wraps them onto a second row instead.
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _open(
      tester,
      ReadingSelectionArea(
        translatorEnabled: true,
        onTranslateSelection: (_) {},
        child: const Center(child: Text('the quick brown fox')),
      ),
    );

    await _markLine(tester, 'the quick brown fox', 0.9);

    for (final label in const [
      'Копировать',
      'Копировать всё',
      'Выбрать всё',
      'Перевести',
    ]) {
      final button = tester.getRect(find.text(label));
      expect(button.left, greaterThanOrEqualTo(0), reason: '$label off left');
      expect(button.right, lessThanOrEqualTo(320), reason: '$label off right');
      expect(
        button.bottom,
        lessThanOrEqualTo(640),
        reason: '$label off bottom',
      );
    }
    // Two rows of buttons is what keeps them inside a 320-point screen.
    expect(tester.getSize(find.byType(Wrap).last).height, greaterThan(44));
  });

  selectionTest('pressing the gap between words offers nothing to act on', (
    tester,
  ) async {
    await _open(
      tester,
      ReadingSelectionArea(
        translatorEnabled: true,
        onTranslateSelection: (_) {},
        child: const Center(child: Text('the quick brown fox')),
      ),
    );

    // Halfway across the line is the space between 'quick' and 'brown'; the
    // only thing marked is that space, and a menu for it would be a lie.
    await _markLine(tester, 'the quick brown fox', 0.5);

    expect(find.byType(ReadingSelectionMenu), findsNothing);
  });

  selectionTest(
    'copying puts the marked word on the clipboard and closes the menu',
    (tester) async {
      await _open(
        tester,
        ReadingSelectionArea(
          translatorEnabled: true,
          onTranslateSelection: (_) {},
          child: const Center(child: Text('quick')),
        ),
      );

      await _mark(tester, 'quick');
      _interceptClipboard(tester);
      await tester.tap(find.text('Копировать'));
      await tester.pumpAndSettle();

      expect(_copied, ['quick']);
      expect(find.text('Скопировано'), findsOne);
      expect(find.byType(ReadingSelectionMenu), findsNothing);
    },
  );

  selectionTest(
    'copy all takes the page as the reader laid it out, not the marked word',
    (tester) async {
      await _open(
        tester,
        ReadingSelectionArea(
          translatorEnabled: true,
          onTranslateSelection: (_) {},
          allText: () => 'first line\n\nsecond line',
          child: const Column(
            children: [Text('first line'), Text('second line')],
          ),
        ),
      );

      await _mark(tester, 'first line');
      _interceptClipboard(tester);
      await tester.tap(find.text('Копировать всё'));
      await tester.pumpAndSettle();

      expect(_copied, ['first line\n\nsecond line']);
      expect(find.byType(ReadingSelectionMenu), findsNothing);
    },
  );

  selectionTest(
    'select all widens the mark to the whole page and keeps the menu up',
    (tester) async {
      await _open(
        tester,
        ReadingSelectionArea(
          translatorEnabled: true,
          onTranslateSelection: (_) {},
          child: const Column(
            children: [Text('first line'), Text('second line')],
          ),
        ),
      );

      await _mark(tester, 'first line');
      _interceptClipboard(tester);
      await tester.tap(find.text('Выбрать всё'));
      await tester.pumpAndSettle();
      expect(find.byType(ReadingSelectionMenu), findsOne);

      await tester.tap(find.text('Копировать'));
      await tester.pumpAndSettle();

      expect(_copied.single, contains('first line'));
      expect(_copied.single, contains('second line'));
    },
  );

  selectionTest(
    'translate hands the marked word to the reader and closes the menu',
    (tester) async {
      String? translated;
      await _open(
        tester,
        ReadingSelectionArea(
          translatorEnabled: true,
          onTranslateSelection: (text) => translated = text,
          child: const Center(child: Text('quick')),
        ),
      );

      await _mark(tester, 'quick');
      await tester.tap(find.text('Перевести'));
      await tester.pumpAndSettle();

      expect(translated, 'quick');
      expect(find.byType(ReadingSelectionMenu), findsNothing);
    },
  );

  selectionTest('the translate entry only exists with the translator on', (
    tester,
  ) async {
    await _open(
      tester,
      ReadingSelectionArea(
        translatorEnabled: false,
        onTranslateSelection: (_) {},
        child: const Center(child: Text('quick')),
      ),
    );

    await _mark(tester, 'quick');

    expect(find.text('Копировать'), findsOne);
    expect(find.text('Перевести'), findsNothing);
  });

  selectionTest(
    'a horizontal swipe still turns the page the selection is drawn on',
    (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      await _open(
        tester,
        ReadingSelectionArea(
          translatorEnabled: true,
          onTranslateSelection: (_) {},
          child: PageView(
            controller: controller,
            children: const [
              Center(child: Text('quick')),
              Center(child: Text('brown')),
            ],
          ),
        ),
      );

      await tester.fling(
        find.text('quick'),
        const Offset(-300, 0),
        1200,
        deviceKind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(controller.page, 1.0);
    },
  );

  selectionTest('a tap still names the word it landed on', (tester) async {
    var tapped = 0;
    final recognizer = TapGestureRecognizer()..onTap = () => tapped++;
    addTearDown(recognizer.dispose);
    await _open(
      tester,
      ReadingSelectionArea(
        translatorEnabled: true,
        onTranslateSelection: (_) {},
        child: Center(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'quick ', recognizer: recognizer),
                const TextSpan(text: 'brown'),
              ],
            ),
            textScaler: TextScaler.linear(4),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getTopLeft(find.byType(Text)) + const Offset(20, 40),
    );
    await tester.pumpAndSettle();

    expect(tapped, 1);
  });

  selectionTest('a mark can be kept as a note', (tester) async {
    String? noted;
    await _open(
      tester,
      ReadingSelectionArea(
        translatorEnabled: false,
        onTranslateSelection: (_) {},
        onNoteSelection: (text) => noted = text,
        child: const Center(child: Text('the quick brown fox')),
      ),
    );

    await _markLine(tester, 'the quick brown fox', 0.9);
    await tester.tap(find.text('Заметка'));
    await tester.pumpAndSettle();
    expect(noted, 'fox');
    // The mark is spent once it has been kept.
    expect(find.text('Заметка'), findsNothing);
  });
}
