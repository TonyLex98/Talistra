// Regenerates assets/instructions/transread_guide.pdf — the bundled user
// guide that's automatically added to the library on a fresh install (see
// lib/main.dart's `_seedInstructionsPdf`).
//
// Run from the repo root:
//   dart run tool/build_instructions_pdf.dart
//
// Screenshots: drop PNGs into tool/instructions_screenshots/ named after
// the `_Section.imageName` values below (e.g. library.png, reader_pdf.png).
// Any section whose image file is missing is rendered as text-only, so
// this script always produces a valid PDF even before screenshots exist.
//
// Font: needs a Cyrillic-capable TTF. Defaults to Windows' bundled Arial
// (present on any stock Windows install, never committed to the repo —
// only a subset gets embedded into the generated PDF, which is standard
// practice and within Arial's embedding permissions). On another OS, or
// to use a different typeface, point FONT_REGULAR / FONT_BOLD at any TTF
// file you have rights to embed:
//   dart run tool/build_instructions_pdf.dart --font-regular=/path/to.ttf --font-bold=/path/to-bold.ttf

import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const _brand = PdfColor.fromInt(0xFF1565C0);
const _ink = PdfColor.fromInt(0xFF1A1A1A);
const _muted = PdfColor.fromInt(0xFF5F6368);

class _Section {
  const _Section({required this.title, required this.body, this.imageName, this.bullets = const []});
  final String title;
  final String body;
  final String? imageName;
  final List<String> bullets;
}

const _sections = [
  _Section(
    title: 'Быстрый старт',
    body:
        'TransRead — читалка PDF со встроенным переводом слов и предложений, '
        'который работает прямо на телефоне, без интернета (после первой '
        'загрузки языковых моделей).',
    bullets: [
      'Нажмите «+» на главном экране и выберите PDF-файл.',
      'Книга откроется автоматически и появится в библиотеке.',
      'Нажмите на любое слово — появится перевод.',
      'Выделите текст протяжкой — переведётся всё предложение.',
    ],
  ),
  _Section(
    title: 'Библиотека',
    imageName: 'library',
    body:
        'Все открытые книги остаются здесь. Долгое нажатие на обложку — '
        'закрепить сверху (звёздочка) или удалить. Список можно '
        'перетаскивать вручную, порядок запоминается.',
  ),
  _Section(
    title: 'Режимы чтения',
    imageName: 'reader_pdf',
    body:
        'У каждой книги два режима, переключаются кнопкой в правом верхнем '
        'углу читалки:',
    bullets: [
      'Оригинал PDF — точная копия страницы, как в файле.',
      'Адаптивный режим — текст автоматически подстраивается под ширину '
          'экрана, крупнее и удобнее для чтения с телефона.',
      'Лупы (+/–) рядом с номером страницы меняют размер шрифта в '
          'адаптивном режиме.',
    ],
  ),
  _Section(
    title: 'Перевод слов и предложений',
    imageName: 'reader_translate',
    body:
        'Короткое нажатие на слово или протяжка по тексту (выделение) '
        'сразу показывает перевод рядом с выбранным местом — без '
        'перехода на другой экран.',
    bullets: [
      'Долгое нажатие — обычное выделение текста для копирования.',
      'Языки перевода (откуда → куда) видны и меняются прямо в шапке '
          'читалки.',
    ],
  ),
  _Section(
    title: 'Включение и выключение переводчика',
    body:
        'Значок переводчика в верхней панели (главный экран и внутри '
        'книги) полностью включает или выключает всю функцию перевода: '
        'флаги языков, подсказку скачать модель, перевод по нажатию — всё '
        'разом. При выключенном переводчике TransRead — просто чистая '
        'читалка.',
    bullets: [
      'По умолчанию переводчик включён.',
      'Настройку можно также найти в Настройках → «Переводчик».',
    ],
  ),
  _Section(
    title: 'Синхронный перевод (эксперимент)',
    body:
        'В адаптивном режиме можно включить экспериментальный режим: '
        'экран делится на две половины — сверху оригинал, снизу — '
        'перевод того абзаца, который сейчас в фокусе сверху. Включается '
        'значком с разделённым экраном рядом с переключателем режима, '
        'либо в Настройках. Функция помечена как экспериментальная — '
        'мнения о её удобстве могут быть разными, поэтому она не включена '
        'по умолчанию.',
  ),
  _Section(
    title: 'Статистика чтения',
    imageName: 'statistics',
    body:
        'Незаметная кнопка со значком графика на главном экране открывает '
        'статистику: сколько времени и сколько страниц вы прочитали, '
        'всего и по каждой книге. Быстрое пролистывание в счёт не идёт — '
        'считается только время, когда страница действительно '
        'просматривалась.',
  ),
  _Section(
    title: 'Настройки',
    imageName: 'settings',
    body: 'В Настройках собрано всё остальное:',
    bullets: [
      'Языки перевода и управление скачанными языковыми моделями.',
      'Тема приложения (светлая / тёмная / системная).',
      'Фон страницы при чтении: белый, сепия или тёмный.',
      'Язык интерфейса приложения.',
    ],
  ),
  _Section(
    title: 'Форматы файлов',
    body:
        'Основной формат — PDF, ему уделено больше всего внимания: точный '
        'рендер страниц, адаптивный режим, перевод. Поддержка других '
        'популярных форматов для книг добавляется постепенно.',
  ),
  _Section(
    title: 'Всё сохраняется само',
    body:
        'Страница, масштаб, режим чтения, размер шрифта — всё '
        'запоминается для каждой книги отдельно и восстанавливается '
        'точно так же, даже если полностью закрыть приложение и открыть '
        'его заново.',
  ),
  _Section(
    title: 'Эта инструкция',
    body:
        'Этот файл — обычная книга в вашей библиотеке, добавленная один '
        'раз при первой установке. Прочитали — можно спокойно удалить её '
        'долгим нажатием, как любую другую книгу; она не появится снова.',
  ),
];

Future<void> main(List<String> args) async {
  String? fontRegularPath;
  String? fontBoldPath;
  for (final arg in args) {
    if (arg.startsWith('--font-regular=')) fontRegularPath = arg.substring(15);
    if (arg.startsWith('--font-bold=')) fontBoldPath = arg.substring(12);
  }
  fontRegularPath ??= Platform.isWindows ? r'C:\Windows\Fonts\arial.ttf' : null;
  fontBoldPath ??= Platform.isWindows ? r'C:\Windows\Fonts\arialbd.ttf' : null;

  if (fontRegularPath == null || !File(fontRegularPath).existsSync()) {
    stderr.writeln('No Cyrillic TTF found. Pass --font-regular=/path/to.ttf (and --font-bold=...).');
    exit(1);
  }

  final regularFont = pw.Font.ttf(File(fontRegularPath).readAsBytesSync().buffer.asByteData());
  final boldFont = (fontBoldPath != null && File(fontBoldPath).existsSync())
      ? pw.Font.ttf(File(fontBoldPath).readAsBytesSync().buffer.asByteData())
      : regularFont;

  final theme = pw.ThemeData.withFont(base: regularFont, bold: boldFont);
  final doc = pw.Document(theme: theme);

  final screenshotsDir = Directory('tool/instructions_screenshots');

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (context) => pw.Center(
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Container(
              width: 96,
              height: 96,
              decoration: pw.BoxDecoration(color: _brand, borderRadius: pw.BorderRadius.circular(24)),
              alignment: pw.Alignment.center,
              child: pw.Text('T', style: pw.TextStyle(color: PdfColors.white, fontSize: 48, font: boldFont)),
            ),
            pw.SizedBox(height: 24),
            pw.Text('TransRead', style: pw.TextStyle(fontSize: 34, font: boldFont, color: _ink)),
            pw.SizedBox(height: 8),
            pw.Text(
              'Читайте PDF и переводите слова прямо на устройстве',
              style: pw.TextStyle(fontSize: 15, color: _muted),
              textAlign: pw.TextAlign.center,
            ),
            pw.SizedBox(height: 40),
            pw.Text('Краткое руководство', style: pw.TextStyle(fontSize: 13, color: _muted)),
          ],
        ),
      ),
    ),
  );

  for (final section in _sections) {
    File? imageFile;
    if (section.imageName != null) {
      final candidate = File('${screenshotsDir.path}/${section.imageName}.png');
      if (candidate.existsSync()) imageFile = candidate;
    }
    final image = imageFile != null ? pw.MemoryImage(imageFile.readAsBytesSync()) : null;

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(40, 56, 40, 40),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(width: 40, height: 4, color: _brand),
            pw.SizedBox(height: 12),
            pw.Text(section.title, style: pw.TextStyle(fontSize: 22, font: boldFont, color: _ink)),
            pw.SizedBox(height: 12),
            pw.Text(section.body, style: pw.TextStyle(fontSize: 12.5, color: _ink, lineSpacing: 3)),
            if (section.bullets.isNotEmpty) ...[
              pw.SizedBox(height: 10),
              for (final bullet in section.bullets)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 6),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Container(
                        margin: const pw.EdgeInsets.only(top: 5, right: 8),
                        width: 5,
                        height: 5,
                        decoration: const pw.BoxDecoration(color: _brand, shape: pw.BoxShape.circle),
                      ),
                      pw.Expanded(child: pw.Text(bullet, style: pw.TextStyle(fontSize: 12, color: _ink, lineSpacing: 2))),
                    ],
                  ),
                ),
            ],
            if (image != null) ...[
              pw.SizedBox(height: 16),
              pw.Expanded(
                child: pw.Center(
                  child: pw.Container(
                    padding: const pw.EdgeInsets.all(8),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey300, width: 1),
                      borderRadius: pw.BorderRadius.circular(18),
                    ),
                    child: pw.ClipRRect(
                      horizontalRadius: 12,
                      verticalRadius: 12,
                      child: pw.Image(image, fit: pw.BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  final outFile = File('assets/instructions/transread_guide.pdf');
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(await doc.save());
  stdout.writeln('Wrote ${outFile.path} (${_sections.length + 1} pages)');
}
