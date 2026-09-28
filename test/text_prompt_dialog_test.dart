import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/services/annotation_service.dart';
import 'package:transreade/widgets/reader_annotations.dart';
import 'package:transreade/widgets/text_prompt_dialog.dart';

late AnnotationService _notes;

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext) onGo,
) async {
  SharedPreferences.setMockInitialValues({});
  _notes = AnnotationService.load(await SharedPreferences.getInstance());
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: _notes,
      child: MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => onGo(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

Future<void> _addNote(BuildContext context) => addNoteFromSelection(
  context,
  documentId: 'book',
  page: 3,
  quote: 'passage',
);

void main() {
  testWidgets('a note is saved, and its dialog closes cleanly', (tester) async {
    await _open(tester, _addNote);
    await tester.enterText(find.byType(TextField), 'my thought');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_notes.forDocument('book').single.note, 'my thought');
  });

  testWidgets('«Назад» over the note dialog closes it — no red screen', (
    tester,
  ) async {
    await _open(tester, _addNote);
    await tester.enterText(find.byType(TextField), 'half a thought');
    // The system back gesture.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsNothing);
    expect(_notes.forDocument('book'), isEmpty);
  });

  testWidgets('cancelling keeps nothing and breaks nothing', (tester) async {
    await _open(tester, _addNote);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_notes.forDocument('book'), isEmpty);
  });

  testWidgets('go to page answers with a page in range, or nothing', (
    tester,
  ) async {
    final answers = <int?>[];
    Future<void> ask(BuildContext context) async => answers.add(
      await showGoToPageDialog(context, currentPage: 5, pageCount: 40),
    );
    await _open(tester, ask);
    await tester.enterText(find.byType(TextField), '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '400');
    await tester.tap(find.text('Перейти'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(answers, [12, null, null]);
  });
}
