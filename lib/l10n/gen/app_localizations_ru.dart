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
      'Добавьте PDF, DjVu, EPUB, FB2, DOCX, RTF, TXT, MD, HTML, XML, XLSX или картинку — Talistra сама выберет подходящий режим чтения.';

  @override
  String get importingLabel => 'Добавление...';

  @override
  String get addPdfLabel => 'Добавить книгу';

  @override
  String get archiveChooseBook => 'Выберите книгу из архива';

  @override
  String get archiveNoBooks => 'В архиве не нашлось поддерживаемых книг.';

  @override
  String get unsupportedDocumentFormat =>
      'Talistra не смогла распознать или открыть формат этого файла.';

  @override
  String get unknownFormatTitle => 'Неизвестный формат';

  @override
  String get unknownFormatAsText =>
      'Talistra не нашла для этого файла читалку. Открыть его как обычный текст?';

  @override
  String get openAsPlainText => 'Открыть как текст';

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
  String get renameBook => 'Переименовать';

  @override
  String get renameDocumentTitle => 'Переименовать книгу';

  @override
  String get renameDocumentHint => 'Название книги';

  @override
  String get save => 'Сохранить';

  @override
  String documentDetailsPageSize(int width, int height) {
    return '$width × $height мм';
  }

  @override
  String documentDetailsScanResolution(int width, int height, int dpi) {
    return '$width × $height px · $dpi DPI';
  }

  @override
  String openFailed(String error) {
    return 'Не удалось открыть книгу: $error';
  }

  @override
  String get djvuOpening => 'Открываем DjVu…';

  @override
  String get djvuInvalidDocument =>
      'Файл DjVu повреждён или скачан не полностью.';

  @override
  String get djvuTextLayer => 'Текст страницы';

  @override
  String get djvuNoTextLayer =>
      'В этой сканированной странице нет встроенного текстового слоя. Оригинал всё равно можно читать и увеличивать.';

  @override
  String djvuPageFailed(String error) {
    return 'Не удалось отрисовать страницу DjVu: $error';
  }

  @override
  String get searchTooltip => 'Поиск в книге';

  @override
  String get searchHint => 'Что искать';

  @override
  String get searchSearching => 'Ищем…';

  @override
  String searchResults(int count) {
    return 'Совпадений: $count';
  }

  @override
  String get searchNoResults => 'Ничего не найдено';

  @override
  String get searchResultsTitle => 'Совпадения';

  @override
  String get searchPrevious => 'Предыдущее';

  @override
  String get searchNext => 'Следующее';

  @override
  String get goToPageTitle => 'Перейти на страницу';

  @override
  String goToPageHint(int max) {
    return '1 – $max';
  }

  @override
  String get go => 'Перейти';

  @override
  String get smallerText => 'Уменьшить текст';

  @override
  String get largerText => 'Увеличить текст';

  @override
  String get originalPdf => 'Оригинал PDF';

  @override
  String get originalDocument => 'Оригинал';

  @override
  String get originalSheet => 'Оригинал таблицы';

  @override
  String get zoomOut => 'Уменьшить';

  @override
  String get zoomIn => 'Увеличить';

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
  String get supportSectionTitle => 'Связь и поддержка';

  @override
  String get feedbackTitle => 'Обратная связь';

  @override
  String get feedbackTileSubtitle =>
      'Предложить идею или рассказать о проблеме';

  @override
  String get websiteTitle => 'Сайт Talistra';

  @override
  String get feedbackIntro =>
      'Расскажите, что можно сделать удобнее. Сообщение попадёт напрямую команде Talistra.';

  @override
  String get feedbackNameLabel => 'Как к вам обращаться';

  @override
  String get feedbackOptionalHint => 'Необязательно';

  @override
  String get feedbackContactLabel => 'Контакт для ответа';

  @override
  String get feedbackContactHint => 'Email или Telegram, необязательно';

  @override
  String get feedbackMessageLabel => 'Ваше сообщение';

  @override
  String get feedbackMessageHint => 'Например: добавьте закладки с заметками…';

  @override
  String get feedbackMessageValidation => 'Напишите хотя бы 10 символов';

  @override
  String get feedbackPrivacyNote =>
      'Имя и контакт необязательны. Сообщение отправляется только после нажатия кнопки и используется для ответа и развития Talistra.';

  @override
  String get feedbackSend => 'Отправить сообщение';

  @override
  String get feedbackSending => 'Отправляем…';

  @override
  String get feedbackSent => 'Спасибо! Сообщение отправлено.';

  @override
  String get feedbackNoConnection => 'Нет соединения с сервером Talistra';

  @override
  String get feedbackSendError => 'Не удалось отправить сообщение';

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
      'Talistra — читалка PDF, DjVu и популярных электронных форматов со встроенным переводом слов на устройстве.';

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
  String get spreadsheetEmpty => 'В этой книге нет данных ни на одном листе.';

  @override
  String get selectionCopy => 'Копировать';

  @override
  String get selectionTranslate => 'Перевести выделенное';

  @override
  String get selectionClose => 'Снять выделение';

  @override
  String get selectionTranslateShort => 'Перевести';

  @override
  String get selectionCopyAll => 'Копировать всё';

  @override
  String get selectionSelectAll => 'Выбрать всё';

  @override
  String get readerMoreTooltip => 'Ещё';

  @override
  String get copyPageAction => 'Копировать страницу';

  @override
  String get copyBookAction => 'Копировать всю книгу';

  @override
  String get copyingBookText => 'Собираю текст книги…';

  @override
  String get nothingToCopy => 'Здесь нет текста, который можно скопировать';

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

  @override
  String get readingDisplaySection => 'Экран при чтении';

  @override
  String get readingBrightnessLabel => 'Яркость';

  @override
  String get readingBrightnessSystem => 'Использовать системную яркость';

  @override
  String get readingBrightnessSystemValue => 'Системная';

  @override
  String get keepScreenOnTitle => 'Не гасить экран при чтении';

  @override
  String get keepScreenOnSubtitle =>
      'Ниже запаса заряда используется системный тайм-аут.';

  @override
  String keepScreenOnBatteryLabel(Object percent) {
    return 'Не гасить экран выше $percent% заряда';
  }

  @override
  String get contentsAction => 'Оглавление';

  @override
  String get contentsEmpty => 'В этой книге нет оглавления';

  @override
  String get addBookmarkAction => 'Добавить закладку';

  @override
  String get removeBookmarkAction => 'Убрать закладку';

  @override
  String get bookmarksAction => 'Закладки и заметки';

  @override
  String get bookmarksEmpty =>
      'Здесь появятся закладки и заметки. Добавьте закладку в меню «Ещё» или выделите текст и выберите «Заметка».';

  @override
  String get bookmarkAdded => 'Закладка добавлена';

  @override
  String get bookmarkRemoved => 'Закладка убрана';

  @override
  String bookmarkPage(int page) {
    return 'Стр. $page';
  }

  @override
  String get selectionNote => 'Заметка';

  @override
  String get noteDialogTitle => 'Заметка к отрывку';

  @override
  String get noteHint => 'Ваша мысль (необязательно)';

  @override
  String get noteSaved => 'Заметка сохранена';

  @override
  String get editNote => 'Изменить заметку';

  @override
  String get saveWordAction => 'В словарь';

  @override
  String get wordSaved => 'Добавлено в словарь';

  @override
  String get wordAlreadySaved => 'Уже в словаре';

  @override
  String get vocabularyTooltip => 'Мой словарь';

  @override
  String get vocabularyTitle => 'Мой словарь';

  @override
  String get vocabularyEmpty =>
      'Словарь пока пуст. Нажмите на слово в книге и затем «В словарь» в карточке перевода.';

  @override
  String vocabularyDue(int count) {
    return 'К повторению: $count';
  }

  @override
  String get practiceAction => 'Тренировка';

  @override
  String get practiceShowAnswer => 'Показать перевод';

  @override
  String get practiceKnow => 'Помню';

  @override
  String get practiceForgot => 'Не помню';

  @override
  String get practiceDone => 'На сегодня всё повторено. Возвращайтесь завтра!';

  @override
  String get vocabularyExportAction => 'Экспорт в CSV (Anki)';

  @override
  String get vocabularyExported => 'Словарь сохранён';

  @override
  String get vocabularyTranslationHint => 'Перевод';

  @override
  String get readAloudAction => 'Читать вслух';

  @override
  String get stopReadingAction => 'Остановить чтение';

  @override
  String get ttsUnavailable =>
      'Синтез речи для этого языка недоступен на устройстве';

  @override
  String get backupSectionTitle => 'Резервная копия';

  @override
  String get backupExport => 'Сохранить резервную копию';

  @override
  String get backupExportSubtitle =>
      'Прогресс чтения, закладки, заметки, словарь, статистика и настройки';

  @override
  String get backupImport => 'Восстановить из копии';

  @override
  String get backupImportSubtitle =>
      'Книги сопоставляются по файлу: добавьте их в библиотеку заново, и прогресс вернётся';

  @override
  String get backupSaved => 'Резервная копия сохранена';

  @override
  String get backupRestored => 'Данные восстановлены';

  @override
  String backupFailed(String error) {
    return 'Не получилось: $error';
  }

  @override
  String get pdfPasswordTitle => 'PDF защищён паролем';

  @override
  String get pdfPasswordHint => 'Пароль';

  @override
  String get pdfPasswordWrong => 'Неверный пароль';

  @override
  String get open => 'Открыть';

  @override
  String get feedbackAttachLog => 'Приложить журнал ошибок';

  @override
  String get feedbackAttachLogSubtitle =>
      'Технические сведения о сбоях, без содержимого книг';

  @override
  String get shareAction => 'Поделиться';

  @override
  String get shareFileAction => 'Отправить файл книги';

  @override
  String get vocabularyHint =>
      'Слова попадают сюда из карточки перевода: кнопка «В словарь». «Тренировка» — повторить их.';

  @override
  String get ocrUnavailable =>
      'Распознавание текста для этого языка книги недоступно на устройстве — страницы показаны как есть.';
}
