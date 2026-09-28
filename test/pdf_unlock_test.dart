import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:transreade/utils/pdf_unlock.dart';

Future<Uint8List> _pdf({String? user, String? owner}) async {
  final document = PdfDocument();
  document.pages.add().graphics.drawString(
    'Secret text',
    PdfStandardFont(PdfFontFamily.helvetica, 12),
  );
  if (user != null) document.security.userPassword = user;
  if (owner != null) document.security.ownerPassword = owner;
  final bytes = Uint8List.fromList(await document.save());
  document.dispose();
  return bytes;
}

String _textOf(Uint8List bytes) {
  final document = PdfDocument(inputBytes: bytes);
  try {
    return PdfTextExtractor(document).extractText().trim();
  } finally {
    document.dispose();
  }
}

void main() {
  test('a plain PDF needs nothing', () async {
    expect(pdfLockOf(await _pdf()), PdfLock.open);
  });

  test('a PDF that only restricts printing opens without a password', () async {
    expect(pdfLockOf(await _pdf(owner: 'owner')), PdfLock.open);
  });

  test('a PDF with a password is locked until it is given', () async {
    final locked = await _pdf(user: 'secret', owner: 'owner');
    expect(pdfLockOf(locked), PdfLock.locked);
    expect(unlockPdf(locked, 'wrong'), isNull);

    final unlocked = unlockPdf(locked, 'secret')!;
    expect(pdfLockOf(unlocked), PdfLock.open);
    expect(_textOf(unlocked), 'Secret text');
  });
}
