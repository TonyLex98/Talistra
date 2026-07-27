// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get settingsTooltip => 'Настройки';

  @override
  String get emptyLibraryTitle => 'Ваша библиотека пуста';

  @override
  String get emptyLibrarySubtitle =>
      'Добавьте PDF или TXT, чтобы начать читать и переводить слова одним нажатием.';

  @override
  String get importingLabel => 'Добавление...';

  @override
  String get addPdfLabel => 'Добавить книгу';

  @override
  String pageProgress(int page, int total) {
    return 'Стр. $page из $total';
  }

  @override
  String get neverOpened => 'Ещё не открывалась';

  @override
  String get unpinTooltip => 'Открепить';

  @override
  String get pinTooltip => 'Закрепить наверху';

  @override
  String get removeFromLibrary => 'Удалить из библиотеки';

  @override
  String get deleteDocumentTitle => 'Удалить книгу?';

  @override
  String deleteDocumentBody(String title) {
    return '«$title» будет удалена из библиотеки вместе с прогрессом чтения.';
  }

  @override
  String get cancel => 'Отмена';

  @override
  String get delete => 'Удалить';

  @override
  String openFailed(String error) {
    return 'Не удалось открыть PDF: $error';
  }

  @override
  String get goToPageTitle => 'Перейти на страницу';

  @override
  String goToPageHint(int max) {
    return '1 – $max';
  }

  @override
  String get go => 'Перейти';

  @override
  String get smallerText => 'Меньше текст';

  @override
  String get largerText => 'Крупнее текст';

  @override
  String get originalPdf => 'Оригинал PDF';

  @override
  String get adaptToPhone => 'Адаптировать под телефон';

  @override
  String get translationLanguageTitle => 'Язык перевода';

  @override
  String get fromLanguage => 'С какого языка';

  @override
  String get fromLanguagePickerTitle => 'С какого языка переводить';

  @override
  String get toLanguage => 'На какой язык';

  @override
  String get toLanguagePickerTitle => 'На какой язык переводить';

  @override
  String get swapLanguagesTooltip => 'Поменять языки местами';

  @override
  String get settingsScreenTitle => 'Настройки';

  @override
  String get sectionTranslation => 'Перевод';

  @override
  String get sectionAppearance => 'Оформление';

  @override
  String get sectionAbout => 'О приложении';

  @override
  String get originalLanguage => 'Язык оригинала';

  @override
  String get translationLanguage => 'Язык перевода';

  @override
  String get translationOfflineNote =>
      'Перевод выполняется прямо на устройстве — офлайн-модели для выбранных языков скачиваются один раз и не требуют интернета при чтении.';

  @override
  String modelLabel(String language) {
    return 'Модель: $language';
  }

  @override
  String downloadingProgress(int seconds) {
    return 'Загрузка... $seconds с';
  }

  @override
  String get checkingModel => 'Проверка...';

  @override
  String get modelDownloaded => 'Скачана, доступна офлайн';

  @override
  String get modelNotDownloaded => 'Не скачана';

  @override
  String get download => 'Скачать';

  @override
  String get themeSystem => 'Системная';

  @override
  String get themeLight => 'Светлая';

  @override
  String get themeDark => 'Тёмная';

  @override
  String get readingThemeBackground => 'Фон страницы (PDF и адаптивный режим)';

  @override
  String get readingThemeWhite => 'Белая';

  @override
  String get readingThemeSepia => 'Сепия';

  @override
  String get readingThemeCream => 'Кремовая';

  @override
  String get readingThemeSage => 'Мятная';

  @override
  String get readingThemeNight => 'Ночная';

  @override
  String get readingThemeDark => 'Тёмная';

  @override
  String get appLanguageSection => 'Язык приложения';

  @override
  String get aboutText =>
      'TransRead — читалка PDF со встроенным переводом слов на устройстве. Нажмите на слово при чтении, чтобы увидеть перевод.';

  @override
  String get suggestDownloadTitle => 'Скачать словарь для перевода?';

  @override
  String downloadingNamed(String language, int seconds) {
    return 'Загружаем «$language»... $seconds с';
  }

  @override
  String suggestDownloadBody(String names) {
    return 'Языки: $names. Нужно скачать один раз, дальше перевод работает офлайн.';
  }

  @override
  String get searchLanguageHint => 'Поиск языка';

  @override
  String get translating => 'Переводим...';

  @override
  String get translationFailed => 'Не удалось перевести';

  @override
  String get retry => 'Повторить';

  @override
  String needsModelBody(String names) {
    return 'Нужна языковая модель: $names.\nОна скачивается один раз и работает офлайн.';
  }

  @override
  String get copyTranslationTooltip => 'Копировать перевод';

  @override
  String get sentenceTranslationLabel => 'Перевод предложения';

  @override
  String get noTextOnPage =>
      'На этой странице не нашлось текста для адаптации.';

  @override
  String get selectionCopy => 'Копировать';

  @override
  String get selectionTranslate => 'Перевести выделенное';

  @override
  String get selectionClose => 'Снять выделение';

  @override
  String wrongSourceLanguage(String language) {
    return 'Текст не похож на $language — перевод будет бессмысленным. Сменить язык оригинала?';
  }

  @override
  String get changeSourceLanguage => 'Сменить язык';

  @override
  String get readingTypographySection => 'Текст при чтении';

  @override
  String get readingFontLabel => 'Шрифт';

  @override
  String get readingWeightLabel => 'Насыщенность';

  @override
  String get readingContrastLabel => 'Контраст';

  @override
  String get readingPreviewTitle => 'Как это выглядит';

  @override
  String get readingPreviewText =>
      'Съешь ещё этих мягких французских булок, да выпей чаю. A quick brown fox jumps over the lazy dog.';

  @override
  String get readingTypographyNote =>
      'Применяется к адаптивному режиму и текстовым файлам. У PDF своя типографика, но контраст влияет и на него.';

  @override
  String get copiedLabel => 'Скопировано';

  @override
  String get translatorOnTooltip =>
      'Переводчик включён (нажмите, чтобы выключить)';

  @override
  String get translatorOffTooltip =>
      'Переводчик выключен (нажмите, чтобы включить)';

  @override
  String get translatorSectionTitle => 'Переводчик';

  @override
  String get translatorDisabledNote =>
      'Переводчик выключен — приложение работает как обычная читалка. Включить можно значком «文A» в шапке экрана.';

  @override
  String get statisticsTooltip => 'Статистика';

  @override
  String get statisticsScreenTitle => 'Статистика чтения';

  @override
  String get statisticsTotalTime => 'Всего времени за чтением';

  @override
  String get statisticsTotalPages => 'Страниц прочитано';

  @override
  String get statisticsByBook => 'По книгам';

  @override
  String get statisticsByDay => 'По дням';

  @override
  String get statisticsEmpty =>
      'Пока нет данных о чтении — статистика появится, как только вы начнёте читать.';

  @override
  String get statisticsNote =>
      'Быстрая перелистывание и пролистывание не засчитывается — считается только время, проведённое за реальным чтением страницы.';

  @override
  String get syncTranslationTooltip => 'Синхронный перевод (экспериментально)';

  @override
  String get syncTranslationSectionTitle => 'Синхронный перевод (эксперимент)';

  @override
  String get syncTranslationDescription =>
      'Экран делится пополам: сверху оригинал, снизу — перевод текста, который сейчас в фокусе. Пока экспериментальная функция — доступна только в адаптивном режиме.';

  @override
  String get syncTranslationTranslating => 'Переводим видимый текст...';

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '$hours ч $minutes мин';
  }

  @override
  String durationMinutes(int minutes) {
    return '$minutes мин';
  }

  @override
  String durationSeconds(int seconds) {
    return '$seconds с';
  }

  @override
  String statisticsPagesShort(int pages) {
    return '$pages стр.';
  }
}
