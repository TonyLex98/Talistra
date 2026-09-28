// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsTooltip => 'Settings';

  @override
  String get emptyLibraryTitle => 'Your library is empty';

  @override
  String get emptyLibrarySubtitle =>
      'Add PDF, DjVu, EPUB, FB2, DOCX, RTF, TXT, MD, HTML, XML, XLSX or a picture — Talistra will open it in the right reading mode.';

  @override
  String get importingLabel => 'Adding...';

  @override
  String get addPdfLabel => 'Add book';

  @override
  String get archiveChooseBook => 'Choose a book from the archive';

  @override
  String get archiveNoBooks => 'No supported books were found in the archive.';

  @override
  String get unsupportedDocumentFormat =>
      'Talistra can’t recognise or open this file format.';

  @override
  String get unknownFormatTitle => 'Unrecognised format';

  @override
  String get unknownFormatAsText =>
      'Talistra found no reader for this file. Open it as plain text?';

  @override
  String get openAsPlainText => 'Open as plain text';

  @override
  String pageProgress(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get neverOpened => 'Not opened yet';

  @override
  String get unpinTooltip => 'Unpin';

  @override
  String get pinTooltip => 'Pin to top';

  @override
  String get removeFromLibrary => 'Remove from library';

  @override
  String get deleteDocumentTitle => 'Delete this book?';

  @override
  String deleteDocumentBody(String title) {
    return '\"$title\" will be removed from the library along with your reading progress.';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get renameBook => 'Rename';

  @override
  String get renameDocumentTitle => 'Rename book';

  @override
  String get renameDocumentHint => 'Book title';

  @override
  String get save => 'Save';

  @override
  String documentDetailsPageSize(int width, int height) {
    return '$width × $height mm';
  }

  @override
  String documentDetailsScanResolution(int width, int height, int dpi) {
    return '$width × $height px · $dpi DPI';
  }

  @override
  String openFailed(String error) {
    return 'Couldn\'t open the book: $error';
  }

  @override
  String get djvuOpening => 'Opening DjVu…';

  @override
  String get djvuInvalidDocument => 'This DjVu file is damaged or incomplete.';

  @override
  String get djvuTextLayer => 'Page text';

  @override
  String get djvuNoTextLayer =>
      'This scanned page has no embedded text layer. You can still read and zoom the original image.';

  @override
  String djvuPageFailed(String error) {
    return 'Couldn\'t render this DjVu page: $error';
  }

  @override
  String get searchTooltip => 'Search in book';

  @override
  String get searchHint => 'What to search for';

  @override
  String get searchSearching => 'Searching…';

  @override
  String searchResults(int count) {
    return '$count matches';
  }

  @override
  String get searchNoResults => 'Nothing found';

  @override
  String get searchResultsTitle => 'Matches';

  @override
  String get searchPrevious => 'Previous match';

  @override
  String get searchNext => 'Next match';

  @override
  String get goToPageTitle => 'Go to page';

  @override
  String goToPageHint(int max) {
    return '1 – $max';
  }

  @override
  String get go => 'Go';

  @override
  String get smallerText => 'Smaller text';

  @override
  String get largerText => 'Larger text';

  @override
  String get originalPdf => 'Original PDF';

  @override
  String get originalDocument => 'Original';

  @override
  String get originalSheet => 'Original sheet';

  @override
  String get zoomOut => 'Zoom out';

  @override
  String get zoomIn => 'Zoom in';

  @override
  String get adaptToPhone => 'Adapt for phone';

  @override
  String get translationLanguageTitle => 'Translation language';

  @override
  String get fromLanguage => 'From language';

  @override
  String get fromLanguagePickerTitle => 'Translate from which language';

  @override
  String get toLanguage => 'To language';

  @override
  String get toLanguagePickerTitle => 'Translate to which language';

  @override
  String get swapLanguagesTooltip => 'Swap languages';

  @override
  String get settingsScreenTitle => 'Settings';

  @override
  String get supportSectionTitle => 'Help and support';

  @override
  String get feedbackTitle => 'Feedback';

  @override
  String get feedbackTileSubtitle => 'Share an idea or report a problem';

  @override
  String get websiteTitle => 'Talistra website';

  @override
  String get feedbackIntro =>
      'Tell us what could work better. Your message goes directly to the Talistra team.';

  @override
  String get feedbackNameLabel => 'Your name';

  @override
  String get feedbackOptionalHint => 'Optional';

  @override
  String get feedbackContactLabel => 'Contact for a reply';

  @override
  String get feedbackContactHint => 'Email or Telegram, optional';

  @override
  String get feedbackMessageLabel => 'Your message';

  @override
  String get feedbackMessageHint =>
      'For example: please add bookmarks with notes…';

  @override
  String get feedbackMessageValidation => 'Please enter at least 10 characters';

  @override
  String get feedbackPrivacyNote =>
      'Your name and contact are optional. The message is sent only when you tap the button and is used to reply and improve Talistra.';

  @override
  String get feedbackSend => 'Send message';

  @override
  String get feedbackSending => 'Sending…';

  @override
  String get feedbackSent => 'Thank you! Your message has been sent.';

  @override
  String get feedbackNoConnection => 'Cannot connect to the Talistra server';

  @override
  String get feedbackSendError => 'Could not send the message';

  @override
  String get sectionTranslation => 'Translation';

  @override
  String get sectionAppearance => 'Appearance';

  @override
  String get sectionAbout => 'About';

  @override
  String get originalLanguage => 'Original language';

  @override
  String get translationLanguage => 'Translation language';

  @override
  String get translationOfflineNote =>
      'Translation runs right on the device — offline models for the chosen languages download once and don\'t need internet while reading.';

  @override
  String modelLabel(String language) {
    return 'Model: $language';
  }

  @override
  String downloadingProgress(int seconds) {
    return 'Downloading... ${seconds}s';
  }

  @override
  String get checkingModel => 'Checking...';

  @override
  String get modelDownloaded => 'Downloaded, available offline';

  @override
  String get modelNotDownloaded => 'Not downloaded';

  @override
  String get download => 'Download';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get readingThemeBackground =>
      'Page background (PDF and adaptive mode)';

  @override
  String get readingThemeWhite => 'White';

  @override
  String get readingThemeSepia => 'Sepia';

  @override
  String get readingThemeCream => 'Cream';

  @override
  String get readingThemeSage => 'Sage';

  @override
  String get readingThemeNight => 'Night';

  @override
  String get readingThemeDark => 'Dark';

  @override
  String get appLanguageSection => 'App language';

  @override
  String get aboutText =>
      'Talistra is a reader for PDF, DjVu and popular e-book formats with built-in on-device word translation.';

  @override
  String get suggestDownloadTitle => 'Download the translation dictionary?';

  @override
  String downloadingNamed(String language, int seconds) {
    return 'Downloading \"$language\"... ${seconds}s';
  }

  @override
  String suggestDownloadBody(String names) {
    return 'Languages: $names. Download once, then translation works offline.';
  }

  @override
  String get searchLanguageHint => 'Search language';

  @override
  String get translating => 'Translating...';

  @override
  String get translationFailed => 'Couldn\'t translate';

  @override
  String get retry => 'Retry';

  @override
  String needsModelBody(String names) {
    return 'Needs a language model: $names.\nIt downloads once and works offline.';
  }

  @override
  String get copyTranslationTooltip => 'Copy translation';

  @override
  String get sentenceTranslationLabel => 'Sentence translation';

  @override
  String get noTextOnPage => 'No text was found on this page to adapt.';

  @override
  String get spreadsheetEmpty => 'This workbook has no data on any sheet.';

  @override
  String get selectionCopy => 'Copy';

  @override
  String get selectionTranslate => 'Translate selection';

  @override
  String get selectionClose => 'Clear selection';

  @override
  String get selectionTranslateShort => 'Translate';

  @override
  String get selectionCopyAll => 'Copy all';

  @override
  String get selectionSelectAll => 'Select all';

  @override
  String get readerMoreTooltip => 'More';

  @override
  String get copyPageAction => 'Copy page';

  @override
  String get copyBookAction => 'Copy whole book';

  @override
  String get copyingBookText => 'Gathering the book\'s text…';

  @override
  String get nothingToCopy => 'There is no text here to copy';

  @override
  String wrongSourceLanguage(String language) {
    return 'This text doesn’t look like $language — the translation will be nonsense. Change the original language?';
  }

  @override
  String get changeSourceLanguage => 'Change language';

  @override
  String get readingTypographySection => 'Reading text';

  @override
  String get readingFontLabel => 'Font';

  @override
  String get readingWeightLabel => 'Weight';

  @override
  String get readingContrastLabel => 'Contrast';

  @override
  String get readingPreviewTitle => 'Preview';

  @override
  String get readingPreviewText =>
      'A quick brown fox jumps over the lazy dog. Съешь ещё этих мягких французских булок, да выпей чаю.';

  @override
  String get readingTypographyNote =>
      'Applies to adaptive mode and text files. A PDF page keeps its own type; contrast also affects it.';

  @override
  String get copiedLabel => 'Copied';

  @override
  String get translatorOnTooltip => 'Translator is on (tap to turn off)';

  @override
  String get translatorOffTooltip => 'Translator is off (tap to turn on)';

  @override
  String get translatorSectionTitle => 'Translator';

  @override
  String get translatorDisabledNote =>
      'The translator is off — the app works as a plain reader. Turn it back on with the \"文A\" icon in the top bar.';

  @override
  String get statisticsTooltip => 'Statistics';

  @override
  String get statisticsScreenTitle => 'Reading statistics';

  @override
  String get statisticsTotalTime => 'Total time spent reading';

  @override
  String get statisticsTotalPages => 'Pages read';

  @override
  String get statisticsByBook => 'By book';

  @override
  String get statisticsByDay => 'By day';

  @override
  String get statisticsEmpty =>
      'No reading data yet — statistics will show up once you start reading.';

  @override
  String get statisticsNote =>
      'Fast flipping through pages isn\'t counted — only time genuinely spent reading a page.';

  @override
  String get syncTranslationTooltip => 'Synced translation (experimental)';

  @override
  String get syncTranslationSectionTitle => 'Synced translation (experiment)';

  @override
  String get syncTranslationDescription =>
      'Splits the screen in half: original on top, translation of whatever\'s in focus on the bottom. Still experimental — only available in adaptive mode.';

  @override
  String get syncTranslationTranslating => 'Translating visible text...';

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '${hours}h ${minutes}m';
  }

  @override
  String durationMinutes(int minutes) {
    return '${minutes}m';
  }

  @override
  String durationSeconds(int seconds) {
    return '${seconds}s';
  }

  @override
  String statisticsPagesShort(int pages) {
    return '$pages pages';
  }

  @override
  String get readingDisplaySection => 'Reading display';

  @override
  String get readingBrightnessLabel => 'Brightness';

  @override
  String get readingBrightnessSystem => 'Use system brightness';

  @override
  String get readingBrightnessSystemValue => 'System';

  @override
  String get keepScreenOnTitle => 'Keep screen on while reading';

  @override
  String get keepScreenOnSubtitle =>
      'Below the battery reserve, the system timeout is used.';

  @override
  String keepScreenOnBatteryLabel(Object percent) {
    return 'Keep awake above $percent% battery';
  }

  @override
  String get contentsAction => 'Contents';

  @override
  String get contentsEmpty => 'This book has no table of contents';

  @override
  String get addBookmarkAction => 'Add bookmark';

  @override
  String get removeBookmarkAction => 'Remove bookmark';

  @override
  String get bookmarksAction => 'Bookmarks & notes';

  @override
  String get bookmarksEmpty =>
      'Bookmarks and notes appear here. Add a bookmark from the More menu, or mark text and choose Note.';

  @override
  String get bookmarkAdded => 'Bookmark added';

  @override
  String get bookmarkRemoved => 'Bookmark removed';

  @override
  String bookmarkPage(int page) {
    return 'Page $page';
  }

  @override
  String get selectionNote => 'Note';

  @override
  String get noteDialogTitle => 'Note on the passage';

  @override
  String get noteHint => 'Your thought (optional)';

  @override
  String get noteSaved => 'Note saved';

  @override
  String get editNote => 'Edit note';

  @override
  String get saveWordAction => 'Save word';

  @override
  String get wordSaved => 'Added to your vocabulary';

  @override
  String get wordAlreadySaved => 'Already in your vocabulary';

  @override
  String get vocabularyTooltip => 'My vocabulary';

  @override
  String get vocabularyTitle => 'My vocabulary';

  @override
  String get vocabularyEmpty =>
      'Your vocabulary is empty. Tap a word while reading, then Save word on its translation card.';

  @override
  String vocabularyDue(int count) {
    return 'Due for review: $count';
  }

  @override
  String get practiceAction => 'Practice';

  @override
  String get practiceShowAnswer => 'Show translation';

  @override
  String get practiceKnow => 'I knew it';

  @override
  String get practiceForgot => 'I forgot';

  @override
  String get practiceDone => 'All caught up for today. Come back tomorrow!';

  @override
  String get vocabularyExportAction => 'Export as CSV (Anki)';

  @override
  String get vocabularyExported => 'Vocabulary saved';

  @override
  String get vocabularyTranslationHint => 'Translation';

  @override
  String get readAloudAction => 'Read aloud';

  @override
  String get stopReadingAction => 'Stop reading';

  @override
  String get ttsUnavailable =>
      'Speech for this language isn\'t available on this device';

  @override
  String get backupSectionTitle => 'Backup';

  @override
  String get backupExport => 'Save a backup';

  @override
  String get backupExportSubtitle =>
      'Reading progress, bookmarks, notes, vocabulary, statistics and settings';

  @override
  String get backupImport => 'Restore from a backup';

  @override
  String get backupImportSubtitle =>
      'Books are matched by file: add them to the library again and their progress comes back';

  @override
  String get backupSaved => 'Backup saved';

  @override
  String get backupRestored => 'Data restored';

  @override
  String backupFailed(String error) {
    return 'That didn\'t work: $error';
  }

  @override
  String get pdfPasswordTitle => 'This PDF is password-protected';

  @override
  String get pdfPasswordHint => 'Password';

  @override
  String get pdfPasswordWrong => 'Wrong password';

  @override
  String get open => 'Open';

  @override
  String get feedbackAttachLog => 'Attach the error log';

  @override
  String get feedbackAttachLogSubtitle =>
      'Technical details of crashes, without any book content';

  @override
  String get shareAction => 'Share';

  @override
  String get shareFileAction => 'Send the book file';

  @override
  String get vocabularyHint =>
      'Words get here from the translation card: its Save word button. Practice reviews them.';

  @override
  String get ocrUnavailable =>
      'Text recognition isn\'t available on this device for the book\'s language — pages are shown as they are.';
}
