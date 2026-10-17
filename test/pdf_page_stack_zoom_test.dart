import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/utils/pdf_region_renderer.dart';
import 'package:transreade/widgets/pdf_page_stack_view.dart';

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
}

final _key = GlobalKey<PdfPageStackViewState>();

Future<List<double>> _pump(WidgetTester tester, {double zoom = 1.0}) async {
  final zooms = <double>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: PdfPageStackView(
            key: _key,
            document: PdfDocument(),
            renderer: _NoRenderer(),
            linesCache: {},
            pageSizes: const [
              Size(200, 280),
              Size(200, 280),
              Size(200, 280),
            ],
            initialPage: 1,
            initialZoom: zoom,
            initialScrollFraction: 0,
            initialScrollFractionX: 0,
            readingTheme: ReadingTheme.white,
            readingContrast: 0,
            readingWeight: 400,
            selectedPageIndex: null,
            selectedWordPdfBounds: null,
            selectedSentenceLineBoundsPdf: const [],
            highlightColor: Colors.yellow,
            onWordSelected: (_, _, _, _) {},
            onRangeSelected: (_, _, _) {},
            onTapEmpty: () {},
            onPageChanged: (_) {},
            onViewSettled: (zoom, _, _) => zooms.add(zoom),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return zooms;
}

Rect _page(WidgetTester tester, int i) =>
    tester.getRect(find.byKey(ValueKey('page-$i')));

void main() {
  testWidgets('zooming out shrinks the pages and keeps them in the middle', (
    tester,
  ) async {
    final zooms = await _pump(tester);
    expect(_page(tester, 0).width, 400);

    for (var i = 0; i < 6; i++) {
      _key.currentState!.zoomStep(zoomIn: false);
      await tester.pump();
    }

    // The far end of the range, not one step short of it.
    expect(zooms.last, 0.25);
    final page = _page(tester, 0);
    expect(page.width, closeTo(100, 0.01));
    // Narrower than the screen, and centred on it.
    expect(page.center.dx, closeTo(200, 0.01));
    // A page 100 wide is 140 tall, so a screen of 600 shows several at once.
    expect(find.byKey(const ValueKey('page-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pinch out goes below the fitted page and stays centred', (
    tester,
  ) async {
    final zooms = await _pump(tester);
    final centre = tester.getCenter(find.byType(PdfPageStackView));
    final one = await tester.startGesture(centre - const Offset(100, 0));
    final two = await tester.startGesture(centre + const Offset(100, 0));
    await tester.pump();
    await one.moveTo(centre - const Offset(40, 0));
    await two.moveTo(centre + const Offset(40, 0));
    await tester.pump();
    await one.up();
    await two.up();
    await tester.pump();

    expect(zooms.last, lessThan(1));
    final page = _page(tester, 0);
    expect(page.width, lessThan(400));
    expect(page.center.dx, closeTo(200, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('zooming back in from far out returns to the fitted page', (
    tester,
  ) async {
    final zooms = await _pump(tester, zoom: 0.25);
    expect(_page(tester, 0).center.dx, closeTo(200, 0.01));

    for (var i = 0; i < 4; i++) {
      _key.currentState!.zoomStep(zoomIn: true);
      await tester.pump();
    }
    expect(zooms.last, closeTo(0.25 * 1.5 * 1.5 * 1.5 * 1.5, 1e-9));

    _key.currentState!.jumpToPage(1);
    await tester.pump();
    expect(_page(tester, 0).left, closeTo(0, 0.01));
    expect(_page(tester, 0).width, closeTo(400, 0.01));
  });
}
