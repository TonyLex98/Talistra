import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/models/library_document.dart';
import 'package:transreade/services/sharing.dart';

LibraryDocument _doc(String title, String format) => LibraryDocument(
  id: '1727000000_42',
  title: title,
  filePath: '/data/pdfs/1727000000_42.$format',
  addedAt: DateTime.utc(2026),
  sourceFingerprint: 'x',
  format: format,
);

void main() {
  test('a shared book goes out under its title, not its storage id', () {
    expect(
      sharedFileName(_doc('Мастер и Маргарита', 'fb2')),
      'Мастер и Маргарита.fb2',
    );
  });

  test('characters no file system takes are dropped from the name', () {
    expect(sharedFileName(_doc('Q: "What/why?"', 'pdf')), 'Q What why.pdf');
    expect(sharedFileName(_doc('  ', 'epub')), 'book.epub');
    expect(sharedFileName(_doc('x' * 300, 'txt')).length, 104);
  });
}
