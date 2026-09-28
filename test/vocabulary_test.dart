import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/screens/vocabulary_screen.dart';
import 'package:transreade/services/vocabulary_service.dart';

void main() {
  late SharedPreferences prefs;
  var now = DateTime(2026, 3, 1, 9);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime(2026, 3, 1, 9);
  });

  VocabularyService service() => VocabularyService(prefs, [], clock: () => now);

  test('a word is kept once per language, whatever its case', () async {
    final vocabulary = service();
    expect(
      await vocabulary.add(
        word: 'Serendipity',
        sourceLanguage: 'en',
        targetLanguage: 'ru',
        translation: 'счастливая случайность',
        sentence: 'It was pure serendipity.',
      ),
      isTrue,
    );
    expect(
      await vocabulary.add(
        word: ' serendipity ',
        sourceLanguage: 'en',
        targetLanguage: 'ru',
      ),
      isFalse,
    );
    expect(
      await vocabulary.add(
        word: 'serendipity',
        sourceLanguage: 'fr',
        targetLanguage: 'ru',
      ),
      isTrue,
    );
    expect(vocabulary.entries, hasLength(2));
  });

  test('remembering spaces a word out; forgetting starts it over', () async {
    final vocabulary = service();
    await vocabulary.add(
      word: 'cat',
      sourceLanguage: 'en',
      targetLanguage: 'ru',
    );
    final id = vocabulary.entries.single.id;
    expect(vocabulary.due, hasLength(1));

    await vocabulary.review(id, remembered: true);
    expect(vocabulary.due, isEmpty);
    now = now.add(const Duration(days: 1));
    expect(vocabulary.due, hasLength(1));

    await vocabulary.review(id, remembered: true);
    expect(vocabulary.entries.single.box, 2);
    now = now.add(const Duration(days: 2));
    expect(vocabulary.due, isEmpty);
    now = now.add(const Duration(days: 1));
    expect(vocabulary.due, hasLength(1));

    await vocabulary.review(id, remembered: false);
    expect(vocabulary.entries.single.box, 0);
    expect(vocabulary.due, hasLength(1));
  });

  test('the dictionary survives a restart', () async {
    await service().add(
      word: 'dog',
      sourceLanguage: 'en',
      targetLanguage: 'ru',
      translation: 'собака',
    );
    final reloaded = VocabularyService.load(prefs);
    expect(reloaded.entries.single.translation, 'собака');
  });

  test('CSV quotes every field the way Anki reads it', () async {
    final vocabulary = service();
    await vocabulary.add(
      word: 'say "hi"',
      sourceLanguage: 'en',
      targetLanguage: 'ru',
      translation: 'привет, мир',
      sentence: 'line one\nline two',
    );
    expect(
      vocabulary.toCsv(),
      '"say ""hi""","привет, мир","line one\nline two",""',
    );
  });

  Future<void> pumpScreen(WidgetTester tester, VocabularyService vocabulary) =>
      tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: vocabulary,
          child: const MaterialApp(
            locale: Locale('ru'),
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: VocabularyScreen(),
          ),
        ),
      );

  testWidgets('practice shows the word, then its translation', (tester) async {
    final vocabulary = service();
    await vocabulary.add(
      word: 'cat',
      sourceLanguage: 'en',
      targetLanguage: 'ru',
      translation: 'кошка',
      sentence: 'The cat sat.',
    );
    await pumpScreen(tester, vocabulary);
    expect(find.text('К повторению: 1'), findsOneWidget);

    await tester.tap(find.text('Тренировка'));
    await tester.pumpAndSettle();
    expect(find.text('cat'), findsOneWidget);
    expect(find.text('The cat sat.'), findsOneWidget);
    expect(find.text('кошка'), findsNothing);

    await tester.tap(find.text('Показать перевод'));
    await tester.pumpAndSettle();
    expect(find.text('кошка'), findsOneWidget);

    await tester.tap(find.text('Помню'));
    await tester.pumpAndSettle();
    expect(find.textContaining('На сегодня всё'), findsOneWidget);
    expect(vocabulary.entries.single.box, 1);
  });

  testWidgets('an empty dictionary says how to fill it', (tester) async {
    await pumpScreen(tester, service());
    expect(find.textContaining('Словарь пока пуст'), findsOneWidget);
  });
}
