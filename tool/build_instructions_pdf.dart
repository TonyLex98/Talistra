// Regenerates the bundled first-run guide for Talistra.
// Run: dart run tool/build_instructions_pdf.dart

import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const _brand = PdfColor.fromInt(0xFF007C78);
const _ink = PdfColor.fromInt(0xFF1D2428);
const _muted = PdfColor.fromInt(0xFF5F686C);
const _paper = PdfColor.fromInt(0xFFFBF6EC);

class _Section {
  const _Section(this.title, this.body, {this.bullets = const [], this.image});

  final String title;
  final String body;
  final List<String> bullets;
  final String? image;
}

const _sections = <_Section>[
  _Section(
    'Библиотека и импорт',
    'Нажмите «Добавить книгу» и выберите файл. Talistra определяет формат по расширению и содержимому файла, добавляет книгу в библиотеку и запоминает место чтения.',
    bullets: [
      'Поддерживаются PDF, DjVu и DJV, EPUB, FB2, DOCX, RTF и TXT.',
      'ZIP-архив открывается как контейнер: Talistra предложит выбрать книгу внутри.',
      'Файлы можно открыть из проводника Android через «Открыть с помощью Talistra».',
      'Долгое нажатие на книгу позволяет закрепить ее сверху или удалить из библиотеки.',
    ],
  ),
  _Section(
    'Чтение PDF и DjVu',
    'В оригинальном режиме документы показаны непрерывной вертикальной лентой: страницы плавно прокручиваются одна за другой, как в PDF-ридере, без резких боковых перелистываний.',
    bullets: [
      'Нажмите номер страницы в шапке, чтобы перейти к нужной странице.',
      'Кнопки с лупами меняют масштаб. При увеличении можно свободно панорамировать страницу.',
      'Ползунок справа показывает текущую страницу и помогает быстро перемещаться по большому документу.',
      'DjVu использует такой же режим прокрутки, зума и оформления, как PDF.',
    ],
    image: 'reader_pdf_tecno',
  ),
  _Section(
    'Адаптивный режим',
    'Кнопка с книгой в шапке переключает оригинальную страницу в текст, подогнанный под ширину телефона. Это особенно удобно для чтения с небольшого экрана.',
    bullets: [
      'Размер текста меняют кнопки A- и A+ в шапке.',
      'Для EPUB, FB2, DOCX, RTF и TXT адаптивный режим является основным.',
      'У DjVu адаптивный текст строится из встроенного текстового слоя. Если его нет, оригинальную скан-страницу все равно можно читать и увеличивать.',
    ],
    image: 'reader_djvu_tecno',
  ),
  _Section(
    'Офлайн-перевод',
    'Переводчик работает прямо на устройстве. Нажмите слово, чтобы увидеть перевод и предложение; модели выбранных языков скачиваются один раз и затем не требуют интернета.',
    bullets: [
      'Языки можно поменять в настройках или быстро переключить в шапке читалки.',
      'В оригинальном PDF и DjVu кнопка перевода ведет в адаптивный текст той же страницы, где перевод удобен и точен.',
      'Переводчик можно выключить полностью, оставив чистую читалку.',
      'Экспериментальный синхронный перевод делит адаптивный экран на оригинал и перевод текущего фрагмента.',
    ],
    image: 'reader_translate_tecno',
  ),
  _Section(
    'Экран при чтении',
    'В настройках есть отдельный блок для комфортного чтения. Его параметры применяются только пока открыта книга и не меняют привычное поведение телефона в остальных приложениях.',
    bullets: [
      'Яркость: выключите «Использовать системную яркость» и выберите значение от 5% до 100%. После выхода из книги вернется системная яркость.',
      'Не гасить экран при чтении: Talistra удерживает экран включенным, пока заряд выше выбранного резерва.',
      'По умолчанию резерв равен 20%. Если заряд ниже порога, или функция выключена, работает обычный системный тайм-аут экрана.',
    ],
    image: 'settings_brightness_tecno',
  ),
  _Section(
    'Оформление и текст',
    'Настройки позволяют сделать страницу спокойной и читаемой именно для вас. Все изменения сохраняются.',
    bullets: [
      'Фон страницы: белый, кремовый, сепия, мятный, темный или ночной.',
      'Шрифты для адаптивного текста: Literata, Lora, Source Serif, EB Garamond, Noto Serif, Inter или системный.',
      'Настройте насыщенность и контраст. Контраст также помогает с бледными сканами PDF и DjVu.',
      'Прогресс, выбранный режим, размер текста и положение в книге сохраняются автоматически.',
    ],
    image: 'settings_tecno',
  ),
  _Section(
    'Статистика и приватность',
    'Кнопка статистики на главном экране показывает реальное время чтения и прочитанные страницы.',
    bullets: [
      'Смотрите итоги по книгам и по дням.',
      'Быстрое пролистывание не засчитывается: учитывается только время, проведенное на странице.',
      'Книги, прогресс, настройки и скачанные языковые модели остаются на устройстве.',
      'Эту инструкцию можно открыть как обычную книгу из библиотеки в любой момент.',
    ],
    image: 'statistics_tecno',
  ),
];

Future<void> main() async {
  final regularPath = Platform.isWindows
      ? r'C:\Windows\Fonts\arial.ttf'
      : throw StateError('Pass a Cyrillic-capable font on non-Windows hosts.');
  final boldPath = Platform.isWindows
      ? r'C:\Windows\Fonts\arialbd.ttf'
      : regularPath;
  final regular = pw.Font.ttf(
    File(regularPath).readAsBytesSync().buffer.asByteData(),
  );
  final bold = pw.Font.ttf(
    File(boldPath).readAsBytesSync().buffer.asByteData(),
  );
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );
  final shots = Directory('tool/instructions_screenshots');

  final logo = File('assets/branding/litra-launcher.png');
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(48),
      build: (_) => pw.Container(
        color: _paper,
        child: pw.Center(
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              if (logo.existsSync())
                pw.Container(
                  width: 160,
                  height: 160,
                  decoration: pw.BoxDecoration(
                    borderRadius: pw.BorderRadius.circular(30),
                  ),
                  child: pw.ClipRRect(
                    horizontalRadius: 30,
                    verticalRadius: 30,
                    child: pw.Image(pw.MemoryImage(logo.readAsBytesSync())),
                  ),
                ),
              pw.SizedBox(height: 28),
              pw.Text(
                'Talistra',
                style: pw.TextStyle(font: bold, fontSize: 42, color: _ink),
              ),
              pw.SizedBox(height: 10),
              pw.Text(
                'Читалка документов с адаптивным текстом и офлайн-переводом',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 16, color: _muted),
              ),
              pw.SizedBox(height: 54),
              pw.Text(
                'Полное руководство',
                style: pw.TextStyle(fontSize: 14, color: _brand, font: bold),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  for (var index = 0; index < _sections.length; index++) {
    final section = _sections[index];
    final file = section.image == null
        ? null
        : File('${shots.path}/${section.image}.png');
    final image = file != null && file.existsSync()
        ? pw.MemoryImage(file.readAsBytesSync())
        : null;
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(44, 44, 44, 36),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              children: [
                pw.Container(width: 36, height: 5, color: _brand),
                pw.SizedBox(width: 10),
                pw.Text(
                  'Talistra',
                  style: pw.TextStyle(color: _muted, fontSize: 10),
                ),
                pw.Spacer(),
                pw.Text(
                  '${index + 1}/${_sections.length}',
                  style: pw.TextStyle(color: _muted, fontSize: 10),
                ),
              ],
            ),
            pw.SizedBox(height: 16),
            pw.Text(
              section.title,
              style: pw.TextStyle(font: bold, fontSize: 24, color: _ink),
            ),
            pw.SizedBox(height: 12),
            pw.Text(
              section.body,
              style: pw.TextStyle(fontSize: 12.5, color: _ink, lineSpacing: 3),
            ),
            pw.SizedBox(height: 12),
            for (final item in section.bullets)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 6),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '• ',
                      style: pw.TextStyle(
                        font: bold,
                        color: _brand,
                        fontSize: 13,
                      ),
                    ),
                    pw.Expanded(
                      child: pw.Text(
                        item,
                        style: const pw.TextStyle(
                          fontSize: 11.5,
                          lineSpacing: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (image != null) ...[
              pw.SizedBox(height: 12),
              pw.Expanded(
                child: pw.Center(
                  child: pw.Container(
                    padding: const pw.EdgeInsets.all(6),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      border: pw.Border.all(color: PdfColors.grey300),
                      borderRadius: pw.BorderRadius.circular(16),
                    ),
                    child: pw.ClipRRect(
                      horizontalRadius: 11,
                      verticalRadius: 11,
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

  final output = File('assets/instructions/talistra_guide.pdf');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(await doc.save());
  stdout.writeln('Wrote ${output.path}');
}
