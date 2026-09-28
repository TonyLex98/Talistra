# Talistra

An Android reader for books in a foreign language: open a book, tap a word
or mark a passage, and read its translation over the page — offline, with
Google ML Kit's on-device models. No account, no advertising.

## What it reads

| Format | Reader |
| --- | --- |
| PDF | the original pages (zoom, scroll, marked text across pages) or a reflowed, paginated text view; password-protected PDFs are unlocked once on import |
| DjVu | the scanned pages, or the text layer reflowed (read off the scan by OCR where the file has none) |
| FB2, FB2.ZIP, EPUB, DOCX, RTF, TXT, Markdown, HTML, XML | paginated text in the reader's own font, with the book's headings, emphasis, verse, quotes, lists, tables and pictures |
| JPEG, PNG, WebP, GIF, BMP | a book of one page: zoom, and its text read off it by OCR in the compact view |
| XLSX, XLS | the sheet grid, or a paginated compact view |
| ZIP | any of the above, picked from inside it |

A file in no format above that is still text can be opened as plain text.

## Reading features

- Tap a word for its translation and the translation of its sentence;
  long-press to mark any passage, then copy, translate or keep it as a note.
- Search the whole book, starting from the page being read.
- Contents (from the book's headings, or a PDF's outline), bookmarks and
  notes, «Копировать страницу» / «Копировать книгу».
- **Мой словарь**: words saved from the translation card with the sentence
  they were met in, reviewed as flashcards on a spaced schedule, exported as
  CSV for Anki.
- Reading aloud with the device's text-to-speech, following the voice
  sentence by sentence.
- Reading themes, variable-weight fonts, contrast and brightness; reading
  statistics.
- Backup and restore of progress, notes, vocabulary, statistics and
  settings (the books themselves are matched by file when added again).

## Development

Flutter 3.35 (Dart 3.9).

```sh
flutter pub get
flutter analyze
flutter test          # add -j 2 on a machine short of memory
flutter run
```

- `lib/screens/` — the library, one screen per reader, settings, vocabulary.
- `lib/services/` — state kept in SharedPreferences (library, settings,
  statistics, annotations, vocabulary), translation, backup, speech.
- `lib/utils/` — format detection and parsing (`ebook_text.dart`,
  `ebook_blocks.dart`, `markdown_blocks.dart`, the spreadsheet decoders),
  PDF text reflow, and the paginator (`reflow_paginator.dart`).
- `lib/widgets/` — the page views and the pieces shared between readers.
- `native/` — the DjVu engine (see `docs/DJVU_ENGINE.md`).
- `tool/instructions/` — the bundled user guide, built from HTML.

The text readers measure every page with exactly the style, emphasis and
insets it is painted with; `test/txt_page_fit_test.dart` turns through books
set in the real reading fonts to keep it that way.

Publishing to RuStore is described in `docs/PUBLISHING.md`, third-party
licences in `docs/THIRD_PARTY_LICENSES.md`.
