import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_language.dart';

/// Persisted user preferences: the translation language pair and the
/// app's light/dark theme. Defaults to English -> Russian, as requested.
class SettingsService extends ChangeNotifier {
  SettingsService._(this._prefs, this._sourceLanguage, this._targetLanguage, this._themeMode);

  static const _sourceKey = 'source_language';
  static const _targetKey = 'target_language';
  static const _themeKey = 'theme_mode';

  final SharedPreferences _prefs;
  TranslateLanguage _sourceLanguage;
  TranslateLanguage _targetLanguage;
  ThemeMode _themeMode;

  TranslateLanguage get sourceLanguage => _sourceLanguage;
  TranslateLanguage get targetLanguage => _targetLanguage;
  ThemeMode get themeMode => _themeMode;

  AppLanguage get sourceAppLanguage => AppLanguage.byLanguage(_sourceLanguage);
  AppLanguage get targetAppLanguage => AppLanguage.byLanguage(_targetLanguage);

  factory SettingsService.load(SharedPreferences prefs) {
    final sourceName = prefs.getString(_sourceKey);
    final targetName = prefs.getString(_targetKey);
    final themeName = prefs.getString(_themeKey);
    return SettingsService._(
      prefs,
      sourceName != null ? _fromName(sourceName) : TranslateLanguage.english,
      targetName != null ? _fromName(targetName) : TranslateLanguage.russian,
      ThemeMode.values.firstWhere(
        (m) => m.name == themeName,
        orElse: () => ThemeMode.system,
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
}
