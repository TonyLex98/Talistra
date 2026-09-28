import 'dart:typed_data';

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Password-protected PDFs.
///
/// The page renderer on Android can't open a PDF that needs a password at all
/// (its password parameter works on the web only), so such a book is unlocked
/// once, as it is added, and the library keeps the unlocked copy: after that
/// every part of the reader — pages, text, search, thumbnails — opens it like
/// any other PDF, and nobody asks for the password again.

/// What unlocking [unlockPdf] came to.
enum PdfLock { open, locked }

/// Whether [bytes] need a password to be opened at all. A PDF that only
/// restricts printing or copying (an owner password) opens without one and
/// reads as [PdfLock.open].
PdfLock pdfLockOf(Uint8List bytes) {
  // Only an encrypted file has an /Encrypt entry, and looking for it is far
  // cheaper than parsing the whole document to find out.
  if (!_contains(bytes, _encryptMarker)) return PdfLock.open;
  try {
    PdfDocument(inputBytes: bytes).dispose();
    return PdfLock.open;
  } on ArgumentError catch (error) {
    if (error.name == 'password') return PdfLock.locked;
    rethrow;
  }
}

/// [bytes] with their password taken off, or null when [password] is wrong.
Uint8List? unlockPdf(Uint8List bytes, String password) {
  final PdfDocument document;
  try {
    document = PdfDocument(inputBytes: bytes, password: password);
  } on ArgumentError catch (error) {
    if (error.name == 'password') return null;
    rethrow;
  }
  try {
    document.security
      ..userPassword = ''
      ..ownerPassword = '';
    return Uint8List.fromList(document.saveSync());
  } finally {
    document.dispose();
  }
}

final List<int> _encryptMarker = '/Encrypt'.codeUnits;

bool _contains(Uint8List haystack, List<int> needle) {
  final first = needle.first;
  final last = haystack.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    if (haystack[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
