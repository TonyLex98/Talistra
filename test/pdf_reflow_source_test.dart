import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:transreade/services/pdf_page_worker.dart';
import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/pdf_region_renderer.dart';
import 'package:transreade/widgets/paged_reflow_view.dart';
import 'package:transreade/widgets/pdf_reflow_source.dart';

/// A renderer that draws nothing: these tests are about the text.
class _NoRenderer extends PdfRegionRenderer {
  _NoRenderer() : super.forTesting();

  @override
  Future<Uint8List?> renderRegion({
    required int pageIndex,
    required ui.Rect pdfBounds,
    double scale = 2.0,
    int priority = PdfRegionRenderer.priorityVisible,
    int Function()? livePriority,
    bool Function()? isStale,
  }) async => null;

  @override
  Future<({Uint8List bytes, ui.Rect pdfBounds})?> renderTrimmedRegion({
    required int pageIndex,
    required ui.Rect pdfBounds,
    double scale = 2.5,
    double probeTargetWidth = 320,
    int priority = PdfRegionRenderer.priorityVisible,
    int Function()? livePriority,
    bool Function()? isStale,
  }) async => null;
}

late Directory _dir;
late String _path;
late PdfDocument _document;
late SettingsService _settings;

void main() {
  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('pdf_source');
    final document = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.timesRoman, 11);
    for (var p = 0; p < 12; p++) {
      final page = document.pages.add();
      page.graphics.drawString(
        [
          for (var n = 0; n < 4; n++)
            'Page $p paragraph $n. ${'Some words to fill the line. ' * 8}\n',
        ].join('\n'),
        font,
        bounds: ui.Rect.fromLTWH(
          40,
          40,
          page.getClientSize().width - 80,
          page.getClientSize().height - 80,
        ),
      );
    }
    _path = '${_dir.path}/book.pdf';
    File(_path).writeAsBytesSync(document.saveSync());
    document.dispose();
    _document = PdfDocument(inputBytes: File(_path).readAsBytesSync());
  });

  tearDownAll(() {
    _document.dispose();
    _dir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _settings = SettingsService.load(await SharedPreferences.getInstance());
  });

  PdfReflowSource source() => PdfReflowSource(
    document: _document,
    renderer: _NoRenderer(),
    linesCache: {},
  );

  test('without a worker a page is read where it is asked for', () {
    final s = source();
    expect(s.isLoading(3), isFalse);
    expect(s.blocksFor(3).any((b) => b.text.startsWith('Page 3 ')), isTrue);
    s.dispose();
  });

  test('with a worker a page is empty and loading until it arrives', () async {
    final s = source();
    final worker = (await PdfPageWorker.spawn(_path))!;
    s.attachWorker(worker);
    final arrived = <int>[];
    s.onPageChanged = arrived.add;

    expect(s.blocksFor(2), isEmpty);
    expect(s.isLoading(2), isTrue);
    // The worker answers, and the source says which page came in.
    await _until(() => arrived.contains(2));
    expect(s.isLoading(2), isFalse);
    expect(s.blocksFor(2).any((b) => b.text.startsWith('Page 2 ')), isTrue);
    s.dispose();
  });

  test(
    'the pages around the reader are read before they are asked for',
    () async {
      final s = source();
      s.attachWorker((await PdfPageWorker.spawn(_path))!);
      s.onPageChanged = (_) {};
      s.focusOn(5);
      // Ahead four, behind two — and none of them was ever asked for.
      await _until(() => [3, 4, 5, 6, 7, 8, 9].every((p) => !s.isLoading(p)));
      expect(s.isLoading(1), isTrue);
      expect(s.isLoading(11), isTrue);
      // Turning on finds the next page already in.
      expect(s.blocksFor(6).any((b) => b.text.startsWith('Page 6 ')), isTrue);
      // ...and moving the focus moves what is read.
      s.focusOn(9);
      await _until(() => !s.isLoading(11));
      s.dispose();
    },
  );

  test(
    'a page far from the reader that the view asks for is still read',
    () async {
      final s = source();
      s.attachWorker((await PdfPageWorker.spawn(_path))!);
      final arrived = <int>[];
      s.onPageChanged = arrived.add;
      s.focusOn(0);
      expect(s.blocksFor(10), isEmpty);
      await _until(() => arrived.contains(10));
      expect(s.isLoading(10), isFalse);
      s.dispose();
    },
  );

  test('a worker that dies leaves the source reading on its own', () async {
    final s = source();
    final worker = (await PdfPageWorker.spawn(_path))!;
    s.attachWorker(worker);
    worker.close();
    expect(s.isLoading(4), isFalse);
    expect(s.blocksFor(4).any((b) => b.text.startsWith('Page 4 ')), isTrue);
    s.dispose();
  });

  testWidgets('the view shows a page as loading, then as itself', (
    tester,
  ) async {
    late PdfReflowSource s;
    late PdfPageWorker worker;
    await tester.runAsync(() async {
      s = source();
      worker = (await PdfPageWorker.spawn(_path))!;
      s.attachWorker(worker);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: PagedReflowView(
              source: s,
              initialPage: 3,
              initialFraction: 0.5,
              sourceLanguage: TranslateLanguage.english,
              targetLanguage: TranslateLanguage.russian,
              translationService: TranslationService(),
              fontSize: 18,
              readingTheme: _settings.readingTheme,
              settings: _settings,
              translatorEnabled: false,
              onPageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.textContaining('Page 2 paragraph', findRichText: true),
      findsNothing,
    );

    await tester.runAsync(() => _until(() => !s.isLoading(3)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.textContaining('Page 2 paragraph', findRichText: true),
      findsWidgets,
    );
    // The half-way place asked for while it was loading was kept for when it
    // arrived, not spent on the empty page.
    final footer = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((t) => RegExp(r'^\d+ · \d+/\d+$').hasMatch(t));
    // Half-way down a page whose text ends above the middle is the last of its parts.
    expect(footer, matches(RegExp(r'^3 · (\d)/\1$')));
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 400; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out');
}
