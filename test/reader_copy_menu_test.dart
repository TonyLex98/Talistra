import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/widgets/reader_copy_menu.dart';

/// Text the menu handed to the platform.
final List<String> _copied = [];

String? _pageText() => 'page text';

String? _bookText() => 'book text';

Future<void> _open(
  WidgetTester tester, {
  String? Function() pageText = _pageText,
  FutureOr<String?> Function() bookText = _bookText,
}) async {
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
      home: Scaffold(
        body: ReaderCopyMenu(pageText: pageText, bookText: bookText),
      ),
    ),
  );
}

Future<void> _pick(WidgetTester tester, String action) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the menu offers the page and the whole book', (tester) async {
    await _open(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('Копировать страницу'), findsOne);
    expect(find.text('Копировать всю книгу'), findsOne);
  });

  testWidgets('copying the page takes exactly the page', (tester) async {
    await _open(tester);
    await _pick(tester, 'Копировать страницу');

    expect(_copied, ['page text']);
    expect(find.text('Скопировано'), findsOne);
  });

  testWidgets('copying the book waits for the text and says so', (
    tester,
  ) async {
    final wait = Completer<String>();
    await _open(tester, bookText: () => wait.future);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Копировать всю книгу'));
    await tester.pump();

    expect(find.text('Собираю текст книги…'), findsOne);
    expect(_copied, isEmpty);

    wait.complete('book text');
    await tester.pumpAndSettle();

    expect(_copied, ['book text']);
    expect(find.text('Скопировано'), findsOne);
  });

  testWidgets('a page with no text says there is nothing to copy', (
    tester,
  ) async {
    await _open(tester, pageText: () => '   ');
    await _pick(tester, 'Копировать страницу');

    expect(_copied, isEmpty);
    expect(find.text('Здесь нет текста, который можно скопировать'), findsOne);
  });

  testWidgets('a book that yields no text says the same', (tester) async {
    await _open(tester, bookText: () => null);
    await _pick(tester, 'Копировать всю книгу');

    expect(_copied, isEmpty);
    expect(find.text('Здесь нет текста, который можно скопировать'), findsOne);
  });

  testWidgets('an action that keeps the menu open can be tapped again', (
    tester,
  ) async {
    var larger = 0;
    var contents = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ReaderCopyMenu(
            pageText: _pageText,
            bookText: _bookText,
            actions: [
              ReaderMenuAction(
                icon: Icons.text_increase,
                label: 'Крупнее',
                onSelected: () => larger++,
                keepOpen: true,
              ),
              ReaderMenuAction(
                icon: Icons.toc,
                label: 'Содержание',
                onSelected: () => contents++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Крупнее'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Крупнее'));
    await tester.pumpAndSettle();
    expect(larger, 2);
    expect(find.text('Копировать страницу'), findsOne);

    await tester.tap(find.text('Содержание'));
    await tester.pumpAndSettle();
    expect(contents, 1);
    expect(find.text('Копировать страницу'), findsNothing);
  });

  testWidgets('the bar is crowded only with the translator on a phone', (
    tester,
  ) async {
    late BuildContext context;
    Future<void> at(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
    }

    addTearDown(tester.view.reset);
    await at(const Size(360, 800));
    expect(readerBarIsCrowded(context, translatorOn: true), isTrue);
    expect(readerBarIsCrowded(context, translatorOn: false), isFalse);
    await at(const Size(411, 900));
    expect(readerBarIsCrowded(context, translatorOn: true), isTrue);
    await at(const Size(800, 1280));
    expect(readerBarIsCrowded(context, translatorOn: true), isFalse);
  });
}
