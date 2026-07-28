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
      'Add PDF, DjVu, EPUB, FB2, DOCX, RTF or TXT — Litra will open it in the right reading mode.';

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
      'Litra can’t recognise or open this file format.';

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
      'Litra is a reader for PDF, DjVu and popular e-book formats with built-in on-device word translation.';

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
  String get selectionCopy => 'Copy';

  @override
  String get selectionTranslate => 'Translate selection';

  @override
  String get selectionClose => 'Clear selection';

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
}
