import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @settingsTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Настройки'**
  String get settingsTooltip;

  /// No description provided for @emptyLibraryTitle.
  ///
  /// In ru, this message translates to:
  /// **'Ваша библиотека пуста'**
  String get emptyLibraryTitle;

  /// No description provided for @emptyLibrarySubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Добавьте PDF, DjVu, EPUB, FB2, DOCX, RTF или TXT — Litra сама выберет подходящий режим чтения.'**
  String get emptyLibrarySubtitle;

  /// No description provided for @importingLabel.
  ///
  /// In ru, this message translates to:
  /// **'Добавление...'**
  String get importingLabel;

  /// No description provided for @addPdfLabel.
  ///
  /// In ru, this message translates to:
  /// **'Добавить книгу'**
  String get addPdfLabel;

  /// No description provided for @archiveChooseBook.
  ///
  /// In ru, this message translates to:
  /// **'Выберите книгу из архива'**
  String get archiveChooseBook;

  /// No description provided for @archiveNoBooks.
  ///
  /// In ru, this message translates to:
  /// **'В архиве не нашлось поддерживаемых книг.'**
  String get archiveNoBooks;

  /// No description provided for @unsupportedDocumentFormat.
  ///
  /// In ru, this message translates to:
  /// **'Litra не смогла распознать или открыть формат этого файла.'**
  String get unsupportedDocumentFormat;

  /// No description provided for @pageProgress.
  ///
  /// In ru, this message translates to:
  /// **'Стр. {page} из {total}'**
  String pageProgress(int page, int total);

  /// No description provided for @neverOpened.
  ///
  /// In ru, this message translates to:
  /// **'Ещё не открывалась'**
  String get neverOpened;

  /// No description provided for @unpinTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Открепить'**
  String get unpinTooltip;

  /// No description provided for @pinTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Закрепить наверху'**
  String get pinTooltip;

  /// No description provided for @removeFromLibrary.
  ///
  /// In ru, this message translates to:
  /// **'Удалить из библиотеки'**
  String get removeFromLibrary;

  /// No description provided for @deleteDocumentTitle.
  ///
  /// In ru, this message translates to:
  /// **'Удалить книгу?'**
  String get deleteDocumentTitle;

  /// No description provided for @deleteDocumentBody.
  ///
  /// In ru, this message translates to:
  /// **'«{title}» будет удалена из библиотеки вместе с прогрессом чтения.'**
  String deleteDocumentBody(String title);

  /// No description provided for @cancel.
  ///
  /// In ru, this message translates to:
  /// **'Отмена'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In ru, this message translates to:
  /// **'Удалить'**
  String get delete;

  /// No description provided for @openFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось открыть книгу: {error}'**
  String openFailed(String error);

  /// No description provided for @djvuOpening.
  ///
  /// In ru, this message translates to:
  /// **'Открываем DjVu…'**
  String get djvuOpening;

  /// No description provided for @djvuInvalidDocument.
  ///
  /// In ru, this message translates to:
  /// **'Файл DjVu повреждён или скачан не полностью.'**
  String get djvuInvalidDocument;

  /// No description provided for @djvuTextLayer.
  ///
  /// In ru, this message translates to:
  /// **'Текст страницы'**
  String get djvuTextLayer;

  /// No description provided for @djvuNoTextLayer.
  ///
  /// In ru, this message translates to:
  /// **'В этой сканированной странице нет встроенного текстового слоя. Оригинал всё равно можно читать и увеличивать.'**
  String get djvuNoTextLayer;

  /// No description provided for @djvuPageFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось отрисовать страницу DjVu: {error}'**
  String djvuPageFailed(String error);

  /// No description provided for @goToPageTitle.
  ///
  /// In ru, this message translates to:
  /// **'Перейти на страницу'**
  String get goToPageTitle;

  /// No description provided for @goToPageHint.
  ///
  /// In ru, this message translates to:
  /// **'1 – {max}'**
  String goToPageHint(int max);

  /// No description provided for @go.
  ///
  /// In ru, this message translates to:
  /// **'Перейти'**
  String get go;

  /// No description provided for @smallerText.
  ///
  /// In ru, this message translates to:
  /// **'Меньше текст'**
  String get smallerText;

  /// No description provided for @largerText.
  ///
  /// In ru, this message translates to:
  /// **'Крупнее текст'**
  String get largerText;

  /// No description provided for @originalPdf.
  ///
  /// In ru, this message translates to:
  /// **'Оригинал PDF'**
  String get originalPdf;

  /// No description provided for @originalDocument.
  ///
  /// In ru, this message translates to:
  /// **'Оригинал'**
  String get originalDocument;

  /// No description provided for @zoomOut.
  ///
  /// In ru, this message translates to:
  /// **'Уменьшить'**
  String get zoomOut;

  /// No description provided for @zoomIn.
  ///
  /// In ru, this message translates to:
  /// **'Увеличить'**
  String get zoomIn;

  /// No description provided for @adaptToPhone.
  ///
  /// In ru, this message translates to:
  /// **'Адаптировать под телефон'**
  String get adaptToPhone;

  /// No description provided for @translationLanguageTitle.
  ///
  /// In ru, this message translates to:
  /// **'Язык перевода'**
  String get translationLanguageTitle;

  /// No description provided for @fromLanguage.
  ///
  /// In ru, this message translates to:
  /// **'С какого языка'**
  String get fromLanguage;

  /// No description provided for @fromLanguagePickerTitle.
  ///
  /// In ru, this message translates to:
  /// **'С какого языка переводить'**
  String get fromLanguagePickerTitle;

  /// No description provided for @toLanguage.
  ///
  /// In ru, this message translates to:
  /// **'На какой язык'**
  String get toLanguage;

  /// No description provided for @toLanguagePickerTitle.
  ///
  /// In ru, this message translates to:
  /// **'На какой язык переводить'**
  String get toLanguagePickerTitle;

  /// No description provided for @swapLanguagesTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Поменять языки местами'**
  String get swapLanguagesTooltip;

  /// No description provided for @settingsScreenTitle.
  ///
  /// In ru, this message translates to:
  /// **'Настройки'**
  String get settingsScreenTitle;

  /// No description provided for @sectionTranslation.
  ///
  /// In ru, this message translates to:
  /// **'Перевод'**
  String get sectionTranslation;

  /// No description provided for @sectionAppearance.
  ///
  /// In ru, this message translates to:
  /// **'Оформление'**
  String get sectionAppearance;

  /// No description provided for @sectionAbout.
  ///
  /// In ru, this message translates to:
  /// **'О приложении'**
  String get sectionAbout;

  /// No description provided for @originalLanguage.
  ///
  /// In ru, this message translates to:
  /// **'Язык оригинала'**
  String get originalLanguage;

  /// No description provided for @translationLanguage.
  ///
  /// In ru, this message translates to:
  /// **'Язык перевода'**
  String get translationLanguage;

  /// No description provided for @translationOfflineNote.
  ///
  /// In ru, this message translates to:
  /// **'Перевод выполняется прямо на устройстве — офлайн-модели для выбранных языков скачиваются один раз и не требуют интернета при чтении.'**
  String get translationOfflineNote;

  /// No description provided for @modelLabel.
  ///
  /// In ru, this message translates to:
  /// **'Модель: {language}'**
  String modelLabel(String language);

  /// No description provided for @downloadingProgress.
  ///
  /// In ru, this message translates to:
  /// **'Загрузка... {seconds} с'**
  String downloadingProgress(int seconds);

  /// No description provided for @checkingModel.
  ///
  /// In ru, this message translates to:
  /// **'Проверка...'**
  String get checkingModel;

  /// No description provided for @modelDownloaded.
  ///
  /// In ru, this message translates to:
  /// **'Скачана, доступна офлайн'**
  String get modelDownloaded;

  /// No description provided for @modelNotDownloaded.
  ///
  /// In ru, this message translates to:
  /// **'Не скачана'**
  String get modelNotDownloaded;

  /// No description provided for @download.
  ///
  /// In ru, this message translates to:
  /// **'Скачать'**
  String get download;

  /// No description provided for @themeSystem.
  ///
  /// In ru, this message translates to:
  /// **'Системная'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In ru, this message translates to:
  /// **'Светлая'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In ru, this message translates to:
  /// **'Тёмная'**
  String get themeDark;

  /// No description provided for @readingThemeBackground.
  ///
  /// In ru, this message translates to:
  /// **'Фон страницы (PDF и адаптивный режим)'**
  String get readingThemeBackground;

  /// No description provided for @readingThemeWhite.
  ///
  /// In ru, this message translates to:
  /// **'Белая'**
  String get readingThemeWhite;

  /// No description provided for @readingThemeSepia.
  ///
  /// In ru, this message translates to:
  /// **'Сепия'**
  String get readingThemeSepia;

  /// No description provided for @readingThemeCream.
  ///
  /// In ru, this message translates to:
  /// **'Кремовая'**
  String get readingThemeCream;

  /// No description provided for @readingThemeSage.
  ///
  /// In ru, this message translates to:
  /// **'Мятная'**
  String get readingThemeSage;

  /// No description provided for @readingThemeNight.
  ///
  /// In ru, this message translates to:
  /// **'Ночная'**
  String get readingThemeNight;

  /// No description provided for @readingThemeDark.
  ///
  /// In ru, this message translates to:
  /// **'Тёмная'**
  String get readingThemeDark;

  /// No description provided for @appLanguageSection.
  ///
  /// In ru, this message translates to:
  /// **'Язык приложения'**
  String get appLanguageSection;

  /// No description provided for @aboutText.
  ///
  /// In ru, this message translates to:
  /// **'Litra — читалка PDF, DjVu и популярных электронных форматов со встроенным переводом слов на устройстве.'**
  String get aboutText;

  /// No description provided for @suggestDownloadTitle.
  ///
  /// In ru, this message translates to:
  /// **'Скачать словарь для перевода?'**
  String get suggestDownloadTitle;

  /// No description provided for @downloadingNamed.
  ///
  /// In ru, this message translates to:
  /// **'Загружаем «{language}»... {seconds} с'**
  String downloadingNamed(String language, int seconds);

  /// No description provided for @suggestDownloadBody.
  ///
  /// In ru, this message translates to:
  /// **'Языки: {names}. Нужно скачать один раз, дальше перевод работает офлайн.'**
  String suggestDownloadBody(String names);

  /// No description provided for @searchLanguageHint.
  ///
  /// In ru, this message translates to:
  /// **'Поиск языка'**
  String get searchLanguageHint;

  /// No description provided for @translating.
  ///
  /// In ru, this message translates to:
  /// **'Переводим...'**
  String get translating;

  /// No description provided for @translationFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось перевести'**
  String get translationFailed;

  /// No description provided for @retry.
  ///
  /// In ru, this message translates to:
  /// **'Повторить'**
  String get retry;

  /// No description provided for @needsModelBody.
  ///
  /// In ru, this message translates to:
  /// **'Нужна языковая модель: {names}.\nОна скачивается один раз и работает офлайн.'**
  String needsModelBody(String names);

  /// No description provided for @copyTranslationTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Копировать перевод'**
  String get copyTranslationTooltip;

  /// No description provided for @sentenceTranslationLabel.
  ///
  /// In ru, this message translates to:
  /// **'Перевод предложения'**
  String get sentenceTranslationLabel;

  /// No description provided for @noTextOnPage.
  ///
  /// In ru, this message translates to:
  /// **'На этой странице не нашлось текста для адаптации.'**
  String get noTextOnPage;

  /// No description provided for @selectionCopy.
  ///
  /// In ru, this message translates to:
  /// **'Копировать'**
  String get selectionCopy;

  /// No description provided for @selectionTranslate.
  ///
  /// In ru, this message translates to:
  /// **'Перевести выделенное'**
  String get selectionTranslate;

  /// No description provided for @selectionClose.
  ///
  /// In ru, this message translates to:
  /// **'Снять выделение'**
  String get selectionClose;

  /// No description provided for @wrongSourceLanguage.
  ///
  /// In ru, this message translates to:
  /// **'Текст не похож на {language} — перевод будет бессмысленным. Сменить язык оригинала?'**
  String wrongSourceLanguage(String language);

  /// No description provided for @changeSourceLanguage.
  ///
  /// In ru, this message translates to:
  /// **'Сменить язык'**
  String get changeSourceLanguage;

  /// No description provided for @readingTypographySection.
  ///
  /// In ru, this message translates to:
  /// **'Текст при чтении'**
  String get readingTypographySection;

  /// No description provided for @readingFontLabel.
  ///
  /// In ru, this message translates to:
  /// **'Шрифт'**
  String get readingFontLabel;

  /// No description provided for @readingWeightLabel.
  ///
  /// In ru, this message translates to:
  /// **'Насыщенность'**
  String get readingWeightLabel;

  /// No description provided for @readingContrastLabel.
  ///
  /// In ru, this message translates to:
  /// **'Контраст'**
  String get readingContrastLabel;

  /// No description provided for @readingPreviewTitle.
  ///
  /// In ru, this message translates to:
  /// **'Как это выглядит'**
  String get readingPreviewTitle;

  /// No description provided for @readingPreviewText.
  ///
  /// In ru, this message translates to:
  /// **'Съешь ещё этих мягких французских булок, да выпей чаю. A quick brown fox jumps over the lazy dog.'**
  String get readingPreviewText;

  /// No description provided for @readingTypographyNote.
  ///
  /// In ru, this message translates to:
  /// **'Применяется к адаптивному режиму и текстовым файлам. У PDF своя типографика, но контраст влияет и на него.'**
  String get readingTypographyNote;

  /// No description provided for @copiedLabel.
  ///
  /// In ru, this message translates to:
  /// **'Скопировано'**
  String get copiedLabel;

  /// No description provided for @translatorOnTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Переводчик включён (нажмите, чтобы выключить)'**
  String get translatorOnTooltip;

  /// No description provided for @translatorOffTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Переводчик выключен (нажмите, чтобы включить)'**
  String get translatorOffTooltip;

  /// No description provided for @translatorSectionTitle.
  ///
  /// In ru, this message translates to:
  /// **'Переводчик'**
  String get translatorSectionTitle;

  /// No description provided for @translatorDisabledNote.
  ///
  /// In ru, this message translates to:
  /// **'Переводчик выключен — приложение работает как обычная читалка. Включить можно значком «文A» в шапке экрана.'**
  String get translatorDisabledNote;

  /// No description provided for @statisticsTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Статистика'**
  String get statisticsTooltip;

  /// No description provided for @statisticsScreenTitle.
  ///
  /// In ru, this message translates to:
  /// **'Статистика чтения'**
  String get statisticsScreenTitle;

  /// No description provided for @statisticsTotalTime.
  ///
  /// In ru, this message translates to:
  /// **'Всего времени за чтением'**
  String get statisticsTotalTime;

  /// No description provided for @statisticsTotalPages.
  ///
  /// In ru, this message translates to:
  /// **'Страниц прочитано'**
  String get statisticsTotalPages;

  /// No description provided for @statisticsByBook.
  ///
  /// In ru, this message translates to:
  /// **'По книгам'**
  String get statisticsByBook;

  /// No description provided for @statisticsByDay.
  ///
  /// In ru, this message translates to:
  /// **'По дням'**
  String get statisticsByDay;

  /// No description provided for @statisticsEmpty.
  ///
  /// In ru, this message translates to:
  /// **'Пока нет данных о чтении — статистика появится, как только вы начнёте читать.'**
  String get statisticsEmpty;

  /// No description provided for @statisticsNote.
  ///
  /// In ru, this message translates to:
  /// **'Быстрая перелистывание и пролистывание не засчитывается — считается только время, проведённое за реальным чтением страницы.'**
  String get statisticsNote;

  /// No description provided for @syncTranslationTooltip.
  ///
  /// In ru, this message translates to:
  /// **'Синхронный перевод (экспериментально)'**
  String get syncTranslationTooltip;

  /// No description provided for @syncTranslationSectionTitle.
  ///
  /// In ru, this message translates to:
  /// **'Синхронный перевод (эксперимент)'**
  String get syncTranslationSectionTitle;

  /// No description provided for @syncTranslationDescription.
  ///
  /// In ru, this message translates to:
  /// **'Экран делится пополам: сверху оригинал, снизу — перевод текста, который сейчас в фокусе. Пока экспериментальная функция — доступна только в адаптивном режиме.'**
  String get syncTranslationDescription;

  /// No description provided for @syncTranslationTranslating.
  ///
  /// In ru, this message translates to:
  /// **'Переводим видимый текст...'**
  String get syncTranslationTranslating;

  /// No description provided for @durationHoursMinutes.
  ///
  /// In ru, this message translates to:
  /// **'{hours} ч {minutes} мин'**
  String durationHoursMinutes(int hours, int minutes);

  /// No description provided for @durationMinutes.
  ///
  /// In ru, this message translates to:
  /// **'{minutes} мин'**
  String durationMinutes(int minutes);

  /// No description provided for @durationSeconds.
  ///
  /// In ru, this message translates to:
  /// **'{seconds} с'**
  String durationSeconds(int seconds);

  /// No description provided for @statisticsPagesShort.
  ///
  /// In ru, this message translates to:
  /// **'{pages} стр.'**
  String statisticsPagesShort(int pages);

  /// No description provided for @readingDisplaySection.
  ///
  /// In ru, this message translates to:
  /// **'Экран при чтении'**
  String get readingDisplaySection;

  /// No description provided for @readingBrightnessLabel.
  ///
  /// In ru, this message translates to:
  /// **'Яркость'**
  String get readingBrightnessLabel;

  /// No description provided for @readingBrightnessSystem.
  ///
  /// In ru, this message translates to:
  /// **'Использовать системную яркость'**
  String get readingBrightnessSystem;

  /// No description provided for @readingBrightnessSystemValue.
  ///
  /// In ru, this message translates to:
  /// **'Системная'**
  String get readingBrightnessSystemValue;

  /// No description provided for @keepScreenOnTitle.
  ///
  /// In ru, this message translates to:
  /// **'Не гасить экран при чтении'**
  String get keepScreenOnTitle;

  /// No description provided for @keepScreenOnSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Ниже запаса заряда используется системный тайм-аут.'**
  String get keepScreenOnSubtitle;

  /// No description provided for @keepScreenOnBatteryLabel.
  ///
  /// In ru, this message translates to:
  /// **'Не гасить экран выше {percent}% заряда'**
  String keepScreenOnBatteryLabel(Object percent);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
