import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_language.dart';

/// The reflow (adaptive) view's page background/text colors. Kept
/// independent of the app's own light/dark theme — a reading surface
/// defaults to plain white regardless of how the rest of the app looks,
/// since that's the safest default for text-heavy documents; sepia and
/// dark are offered for readers who prefer them.
enum ReadingTheme { white, sepia, dark }

extension ReadingThemeStyle on ReadingTheme {
  Color get background => switch (this) {
    ReadingTheme.white => const Color(0xFFFFFFFF),
    ReadingTheme.sepia => const Color(0xFFF4ECD8),
    ReadingTheme.dark => const Color(0xFF121212),
  };

  Color get onBackground => switch (this) {
    ReadingTheme.white => const Color(0xFF1A1A1A),
    ReadingTheme.sepia => const Color(0xFF3B2F1E),
    ReadingTheme.dark => const Color(0xFFE4E4E4),
  };

  /// Highlight accent for the tapped word — fixed per reading theme
  /// (rather than following the app's own light/dark scheme) so it stays
  /// legible against whichever reading background is active.
  Color get accent => switch (this) {
    ReadingTheme.white => const Color(0xFF1565C0),
    ReadingTheme.sepia => const Color(0xFF8B4A0F),
    ReadingTheme.dark => const Color(0xFF64B5F6),
  };

  String get label => switch (this) {
    ReadingTheme.white => 'Белая',
    ReadingTheme.sepia => 'Сепия',
    ReadingTheme.dark => 'Тёмная',
  };
}

/// Persisted user preferences: the translation language pair, the app's
/// light/dark theme, and the reflow view's reading theme. Defaults to
/// English -> Russian and a white reading background, as requested.
class SettingsService extends ChangeNotifier {
  SettingsService._(
    this._prefs,
    this._sourceLanguage,
    this._targetLanguage,
    this._themeMode,
    this._readingTheme,
  );

  static const _sourceKey = 'source_language';
  static const _targetKey = 'target_language';
  static const _themeKey = 'theme_mode';
  static const _readingThemeKey = 'reading_theme';

  final SharedPreferences _prefs;
  TranslateLanguage _sourceLanguage;
  TranslateLanguage _targetLanguage;
  ThemeMode _themeMode;
  ReadingTheme _readingTheme;

  TranslateLanguage get sourceLanguage => _sourceLanguage;
  TranslateLanguage get targetLanguage => _targetLanguage;
  ThemeMode get themeMode => _themeMode;
  ReadingTheme get readingTheme => _readingTheme;

  AppLanguage get sourceAppLanguage => AppLanguage.byLanguage(_sourceLanguage);
  AppLanguage get targetAppLanguage => AppLanguage.byLanguage(_targetLanguage);

  factory SettingsService.load(SharedPreferences prefs) {
    final sourceName = prefs.getString(_sourceKey);
    final targetName = prefs.getString(_targetKey);
    final themeName = prefs.getString(_themeKey);
    final readingThemeName = prefs.getString(_readingThemeKey);
    return SettingsService._(
      prefs,
      sourceName != null ? _fromName(sourceName) : TranslateLanguage.english,
      targetName != null ? _fromName(targetName) : TranslateLanguage.russian,
      ThemeMode.values.firstWhere(
        (m) => m.name == themeName,
        orElse: () => ThemeMode.system,
      ),
      ReadingTheme.values.firstWhere(
        (t) => t.name == readingThemeName,
        orElse: () => ReadingTheme.white,
      ),
    );
  }

  static TranslateLanguage _fromName(String name) {
    return TranslateLanguage.values.firstWhere(
      (l) => l.name == name,
      orElse: () => TranslateLanguage.english,
    );
  }

  Future<void> setSourceLanguage(TranslateLanguage language) async {
    if (language == _sourceLanguage) return;
    _sourceLanguage = language;
    await _prefs.setString(_sourceKey, language.name);
    notifyListeners();
  }

  Future<void> setTargetLanguage(TranslateLanguage language) async {
    if (language == _targetLanguage) return;
    _targetLanguage = language;
    await _prefs.setString(_targetKey, language.name);
    notifyListeners();
  }

  Future<void> swapLanguages() async {
    final oldSource = _sourceLanguage;
    _sourceLanguage = _targetLanguage;
    _targetLanguage = oldSource;
    await _prefs.setString(_sourceKey, _sourceLanguage.name);
    await _prefs.setString(_targetKey, _targetLanguage.name);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    await _prefs.setString(_themeKey, mode.name);
    notifyListeners();
  }

  Future<void> setReadingTheme(ReadingTheme theme) async {
    if (theme == _readingTheme) return;
    _readingTheme = theme;
    await _prefs.setString(_readingThemeKey, theme.name);
    notifyListeners();
  }
}
