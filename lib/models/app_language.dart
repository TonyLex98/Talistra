import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Wraps [TranslateLanguage] with a human-friendly Russian display name,
/// so language pickers can show something nicer than an enum name.
class AppLanguage {
  const AppLanguage(this.language, this.displayName, this.flag);

  final TranslateLanguage language;
  final String displayName;
  final String flag;

  String get code => language.bcpCode;

  static const AppLanguage english = AppLanguage(
    TranslateLanguage.english,
    'Английский',
    '🇬🇧',
  );

  static const AppLanguage russian = AppLanguage(
    TranslateLanguage.russian,
    'Русский',
    '🇷🇺',
  );

  /// All languages supported by ML Kit on-device translation, sorted
  /// alphabetically by their Russian name for a friendlier picker.
  static final List<AppLanguage> all = List.of(_buildAll())
    ..sort((a, b) => a.displayName.compareTo(b.displayName));

  static AppLanguage byLanguage(TranslateLanguage language) {
    return all.firstWhere(
      (l) => l.language == language,
      orElse: () => AppLanguage(language, language.name, '🌐'),
    );
  }

  static List<AppLanguage> _buildAll() => const [
    AppLanguage(TranslateLanguage.afrikaans, 'Африкаанс', '🇿🇦'),
    AppLanguage(TranslateLanguage.albanian, 'Албанский', '🇦🇱'),
    AppLanguage(TranslateLanguage.arabic, 'Арабский', '🇸🇦'),
    AppLanguage(TranslateLanguage.belarusian, 'Белорусский', '🇧🇾'),
    AppLanguage(TranslateLanguage.bengali, 'Бенгальский', '🇧🇩'),
    AppLanguage(TranslateLanguage.bulgarian, 'Болгарский', '🇧🇬'),
    AppLanguage(TranslateLanguage.catalan, 'Каталанский', '🌐'),
    AppLanguage(TranslateLanguage.chinese, 'Китайский', '🇨🇳'),
    AppLanguage(TranslateLanguage.croatian, 'Хорватский', '🇭🇷'),
    AppLanguage(TranslateLanguage.czech, 'Чешский', '🇨🇿'),
    AppLanguage(TranslateLanguage.danish, 'Датский', '🇩🇰'),
    AppLanguage(TranslateLanguage.dutch, 'Нидерландский', '🇳🇱'),
    english,
    AppLanguage(TranslateLanguage.esperanto, 'Эсперанто', '🌐'),
    AppLanguage(TranslateLanguage.estonian, 'Эстонский', '🇪🇪'),
    AppLanguage(TranslateLanguage.finnish, 'Финский', '🇫🇮'),
    AppLanguage(TranslateLanguage.french, 'Французский', '🇫🇷'),
    AppLanguage(TranslateLanguage.galician, 'Галисийский', '🌐'),
    AppLanguage(TranslateLanguage.georgian, 'Грузинский', '🇬🇪'),
    AppLanguage(TranslateLanguage.german, 'Немецкий', '🇩🇪'),
    AppLanguage(TranslateLanguage.greek, 'Греческий', '🇬🇷'),
    AppLanguage(TranslateLanguage.gujarati, 'Гуджарати', '🇮🇳'),
    AppLanguage(TranslateLanguage.haitian, 'Гаитянский креольский', '🇭🇹'),
    AppLanguage(TranslateLanguage.hebrew, 'Иврит', '🇮🇱'),
    AppLanguage(TranslateLanguage.hindi, 'Хинди', '🇮🇳'),
    AppLanguage(TranslateLanguage.hungarian, 'Венгерский', '🇭🇺'),
    AppLanguage(TranslateLanguage.icelandic, 'Исландский', '🇮🇸'),
    AppLanguage(TranslateLanguage.indonesian, 'Индонезийский', '🇮🇩'),
    AppLanguage(TranslateLanguage.irish, 'Ирландский', '🇮🇪'),
    AppLanguage(TranslateLanguage.italian, 'Итальянский', '🇮🇹'),
    AppLanguage(TranslateLanguage.japanese, 'Японский', '🇯🇵'),
    AppLanguage(TranslateLanguage.kannada, 'Каннада', '🇮🇳'),
    AppLanguage(TranslateLanguage.korean, 'Корейский', '🇰🇷'),
    AppLanguage(TranslateLanguage.latvian, 'Латышский', '🇱🇻'),
    AppLanguage(TranslateLanguage.lithuanian, 'Литовский', '🇱🇹'),
    AppLanguage(TranslateLanguage.macedonian, 'Македонский', '🇲🇰'),
    AppLanguage(TranslateLanguage.malay, 'Малайский', '🇲🇾'),
    AppLanguage(TranslateLanguage.maltese, 'Мальтийский', '🇲🇹'),
    AppLanguage(TranslateLanguage.marathi, 'Маратхи', '🇮🇳'),
    AppLanguage(TranslateLanguage.norwegian, 'Норвежский', '🇳🇴'),
    AppLanguage(TranslateLanguage.persian, 'Персидский', '🇮🇷'),
    AppLanguage(TranslateLanguage.polish, 'Польский', '🇵🇱'),
    AppLanguage(TranslateLanguage.portuguese, 'Португальский', '🇵🇹'),
    AppLanguage(TranslateLanguage.romanian, 'Румынский', '🇷🇴'),
    russian,
    AppLanguage(TranslateLanguage.slovak, 'Словацкий', '🇸🇰'),
    AppLanguage(TranslateLanguage.slovenian, 'Словенский', '🇸🇮'),
    AppLanguage(TranslateLanguage.spanish, 'Испанский', '🇪🇸'),
    AppLanguage(TranslateLanguage.swahili, 'Суахили', '🌍'),
    AppLanguage(TranslateLanguage.swedish, 'Шведский', '🇸🇪'),
    AppLanguage(TranslateLanguage.tagalog, 'Тагальский', '🇵🇭'),
    AppLanguage(TranslateLanguage.tamil, 'Тамильский', '🇮🇳'),
    AppLanguage(TranslateLanguage.telugu, 'Телугу', '🇮🇳'),
    AppLanguage(TranslateLanguage.thai, 'Тайский', '🇹🇭'),
    AppLanguage(TranslateLanguage.turkish, 'Турецкий', '🇹🇷'),
    AppLanguage(TranslateLanguage.ukrainian, 'Украинский', '🇺🇦'),
    AppLanguage(TranslateLanguage.urdu, 'Урду', '🇵🇰'),
    AppLanguage(TranslateLanguage.vietnamese, 'Вьетнамский', '🇻🇳'),
    AppLanguage(TranslateLanguage.welsh, 'Валлийский', '🏴'),
  ];
}
