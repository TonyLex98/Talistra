import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/widgets/paged_reflow_view.dart';
import 'package:transreade/widgets/reflow_source.dart';

late SettingsService settings;
final _key = GlobalKey<PagedReflowViewState>();

String _paragraph(int n) =>
    'Paragraph$n begins here. ${'Words that fill the line up and wrap. ' * 6}'
    'Paragraph$n ends here.';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: PagedReflowView(
            key: _key,
            source: TextBookSource([
              [
                for (var n = 1; n <= 12; n++)
                  ReflowBlock.paragraph(_paragraph(n)),
              ],
            ]),
            initialPage: 1,
            sourceLanguage: TranslateLanguage.english,
            targetLanguage: TranslateLanguage.russian,
            translationService: TranslationService(),
            fontSize: 18,
            readingTheme: settings.readingTheme,
            settings: settings,
            translatorEnabled: false,
            onPageChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _footer(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .firstWhere((t) => RegExp(r'^\d+ · \d+/\d+$').hasMatch(t));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService.load(await SharedPreferences.getInstance());
  });

  testWidgets('a mark dragged to the edge of the page turns it and goes on', (
    tester,
  ) async {
    await _pump(tester);
    expect(_footer(tester), startsWith('1 · 1/'));
    final view = tester.getRect(find.byType(PagedReflowView));

    // Press and hold the first word, then drag to the bottom corner.
    final gesture = await tester.startGesture(
      tester.getTopLeft(
            find.textContaining('Paragraph1 begins', findRichText: true),
          ) +
          const Offset(12, 10),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var step = 1; step <= 10; step++) {
      await gesture.moveTo(
        Offset.lerp(
          view.topLeft + const Offset(40, 30),
          view.bottomRight - const Offset(8, 20),
          step / 10,
        )!,
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Resting there turns the page.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.pump();
    expect(_footer(tester), startsWith('1 · 2/'));

    // The mark goes on over the new page, to wherever the finger goes.
    await gesture.moveTo(view.center);
    await tester.pump();
    final text = _key.currentState!.carriedSelectionText;
    expect(text, isNotNull);
    expect(text, startsWith('Paragraph1'));
    // Everything the first page showed is in it, whole.
    expect(text, contains(_paragraph(1)));
    // ...and it runs on into the page turned to.
    expect(text, contains('Paragraph2 begins'));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_key.currentState!.carriedSelectionText, text);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mark that never reaches the edge stays on its page', (
    tester,
  ) async {
    await _pump(tester);
    final gesture = await tester.startGesture(
      tester.getTopLeft(
            find.textContaining('Paragraph1 begins', findRichText: true),
          ) +
          const Offset(12, 10),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(find.byType(PagedReflowView)));
    await tester.pump(const Duration(seconds: 2));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 1/'));
    expect(_key.currentState!.carriedSelectionText, isNull);
  });
}
