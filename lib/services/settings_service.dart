import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/app_language.dart';

/// The reading surface's page background/text colors, used by both the
/// reflow (adaptive) view and the real PDF page view. Kept independent of
/// the app's own light/dark theme — a reading surface defaults to plain
/// white regardless of how the rest of the app looks, since that's the
/// safest default for text-heavy documents; sepia and dark are offered
/// for readers who prefer them.
enum ReadingTheme { white, cream, sepia, sage, dark, nightBlue }

/// The typeface reflowed text is set in. Only the adaptive/compact view and
/// plain-text files can honour it — a real PDF page is a picture and keeps
/// its own typography no matter what.
///
/// All three bundled families are variable fonts covering Latin and
/// Cyrillic, so [SettingsService.readingWeight] can dial the weight
/// continuously rather than jumping between regular and bold.
enum ReadingFont {
  literata,
  lora,
  sourceSerif,
  ebGaramond,
  notoSerif,
  inter,
  system,
}

extension ReadingFontStyle on ReadingFont {
  /// The family name as declared in pubspec.yaml, or null for the
  /// platform's own default UI font.
  String? get family => switch (this) {
    ReadingFont.literata => 'Literata',
    ReadingFont.lora => 'Lora',
    ReadingFont.sourceSerif => 'SourceSerif',
    ReadingFont.ebGaramond => 'EBGaramond',
    ReadingFont.notoSerif => 'NotoSerif',
    ReadingFont.inter => 'Inter',
    ReadingFont.system => null,
  };

  String get label => switch (this) {
    ReadingFont.literata => 'Literata',
    ReadingFont.lora => 'Lora',
    ReadingFont.sourceSerif => 'Source Serif',
    ReadingFont.ebGaramond => 'EB Garamond',
    ReadingFont.notoSerif => 'Noto Serif',
    ReadingFont.inter => 'Inter',
    ReadingFont.system => 'System',
  };

  /// Whether the family has a variable weight axis this app can drive.
  bool get hasVariableWeight => this != ReadingFont.system;
}

extension ReadingThemeStyle on ReadingTheme {
  /// The paper colour. Beyond plain white and a night mode, these are the
  /// papers that are actually restful to read on for hours: a warm cream
  /// (paper white without the glare), classic sepia, a soft sage green
  /// (the lowest-strain tint at the same luminance), and a deep blue night
  /// that reads softer than black-on-black.
  Color get background => switch (this) {
    ReadingTheme.white => const Color(0xFFFFFFFF),
    ReadingTheme.cream => const Color(0xFFFBF6EC),
    ReadingTheme.sepia => const Color(0xFFF4ECD8),
    ReadingTheme.sage => const Color(0xFFE9F0E7),
    ReadingTheme.dark => const Color(0xFF121212),
    ReadingTheme.nightBlue => const Color(0xFF0F1620),
  };

  Color get onBackground => switch (this) {
    // Pure black on white — matching a typical PDF's own embedded text
    // color rather than a softened dark grey, for maximum contrast.
    ReadingTheme.white => const Color(0xFF000000),
    ReadingTheme.cream => const Color(0xFF241E14),
    ReadingTheme.sepia => const Color(0xFF3B2F1E),
    ReadingTheme.sage => const Color(0xFF1C2A1E),
    ReadingTheme.dark => const Color(0xFFE4E4E4),
    ReadingTheme.nightBlue => const Color(0xFFCBD8E6),
  };

  /// Highlight accent for the tapped word — fixed per reading theme
  /// (rather than following the app's own light/dark scheme) so it stays
  /// legible against whichever reading background is active.
  Color get accent => switch (this) {
    ReadingTheme.white => const Color(0xFF1565C0),
    ReadingTheme.cream => const Color(0xFF9A5B12),
    ReadingTheme.sepia => const Color(0xFF8B4A0F),
    ReadingTheme.sage => const Color(0xFF2E6B45),
    ReadingTheme.dark => const Color(0xFF64B5F6),
    ReadingTheme.nightBlue => const Color(0xFF7FB2E5),
  };

  /// The second reading surface — the sync-translation pane under the
  /// page. Kept in the reading theme's own family (a shade off the page
  /// colour) rather than the app theme's: a cream page above a near-black
  /// panel below read as two unrelated screens stitched together.
  Color get secondaryBackground => switch (this) {
    ReadingTheme.white => const Color(0xFFF1F1F3),
    ReadingTheme.cream => const Color(0xFFF2EADB),
    ReadingTheme.sepia => const Color(0xFFEADFC2),
    ReadingTheme.sage => const Color(0xFFDDE7DA),
    ReadingTheme.dark => const Color(0xFF1C1C1E),
    ReadingTheme.nightBlue => const Color(0xFF17212E),
  };

  /// The hairline between the two reading surfaces.
  Color get readingDivider => switch (this) {
    ReadingTheme.white => const Color(0xFFD9D9DE),
    ReadingTheme.cream => const Color(0xFFE0D5C0),
    ReadingTheme.sepia => const Color(0xFFD3C4A0),
    ReadingTheme.sage => const Color(0xFFC9D8C6),
    ReadingTheme.dark => const Color(0xFF31313A),
    ReadingTheme.nightBlue => const Color(0xFF27364A),
  };

  /// How a highlight is blended into the page underneath it.
  ///
  /// A PDF page is a picture, so a highlight can only be painted *over*
  /// the text — and a plain translucent rectangle strong enough to be
  /// clearly visible also washes the letters out, which is why the old
  /// highlights had to stay so faint. Blending like a real marker pen
  /// fixes both ends at once: multiply keeps every dark pixel dark (the
  /// text stays black) while tinting the paper hard, and on an inverted
  /// dark page the same job is done by screen, which keeps the light text
  /// light while lifting the paper.
  BlendMode get highlightBlendMode =>
      isDarkPaper ? BlendMode.screen : BlendMode.multiply;

  /// Whether the paper is dark, i.e. the page image has to be inverted and
  /// highlights have to lighten rather than darken.
  bool get isDarkPaper =>
      this == ReadingTheme.dark || this == ReadingTheme.nightBlue;

  /// The marker colour for a tapped word — the strongest of the three.
  Color get wordHighlight => switch (this) {
    ReadingTheme.white => const Color(0xFFFFC02E),
    ReadingTheme.cream => const Color(0xFFFFC55C),
    ReadingTheme.sepia => const Color(0xFFF5B04A),
    ReadingTheme.sage => const Color(0xFFE9DC7A),
    ReadingTheme.dark => const Color(0xFF3E5C86),
    ReadingTheme.nightBlue => const Color(0xFF35507A),
  };

  /// The marker colour for a dragged-out text selection.
  Color get rangeHighlight => switch (this) {
    ReadingTheme.white => const Color(0xFF8FD0FF),
    ReadingTheme.cream => const Color(0xFFE3D3AE),
    ReadingTheme.sepia => const Color(0xFFD9C48F),
    ReadingTheme.sage => const Color(0xFFC7DFC0),
    ReadingTheme.dark => const Color(0xFF2E4869),
    ReadingTheme.nightBlue => const Color(0xFF26405F),
  };

  /// The faint wash marking the whole sentence a translation came from —
  /// deliberately much lighter than the word inside it.
  Color get sentenceHighlight => switch (this) {
    ReadingTheme.white => const Color(0xFFDDEFFF),
    ReadingTheme.cream => const Color(0xFFF3E8D2),
    ReadingTheme.sepia => const Color(0xFFF0E4C8),
    ReadingTheme.sage => const Color(0xFFDEEAD9),
    ReadingTheme.dark => const Color(0xFF1B2A3D),
    ReadingTheme.nightBlue => const Color(0xFF182534),
  };

  /// The ink colour at a given [contrast] (0 = the theme's own default,
  /// 1 = pushed to the extreme the background allows). Reflowed text is
  /// real text, so contrast here is simply how dark (or on a dark page,
  /// how light) the letters are.
  Color inkAt(double contrast) {
    final t = contrast.clamp(0.0, 1.0);
    final target = isDarkPaper
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
    return Color.lerp(onBackground, target, t)!;
  }

  /// The page-image filter for the current reading settings.
  ///
  /// A PDF page is a picture, so the paper colour, the contrast and the ink
  /// weight can only be applied by remapping its pixels. The mapping is a
  /// straight line per channel, *pinned at the paper*: white paper in the
  /// file always lands exactly on [background], and only the slope changes.
  /// That pinning matters — an earlier version raised the slope without it,
  /// so at full contrast sepia paper was pushed past white and the page
  /// came out plain white on a sepia-coloured app.
  ///
  /// [contrast] steepens the line (mid-greys go darker, faint scans and
  /// thin type gain body). [weight] does the same thing more gently: on a
  /// page we can't re-set in a heavier font, "bolder" means denser ink, so
  /// the reading weight adds a little extra slope.
  ColorFilter pageImageFilter({double contrast = 0, int weight = 400}) {
    final c = contrast.clamp(0.0, 1.0);
    final w = ((weight - 400) / 400).clamp(0.0, 1.0);
    // Base slope maps the file's black ink onto this paper's ink; contrast
    // and weight then steepen it.
    final gain = _baseGain + 0.45 * c + 0.25 * w;
    final paper = background;
    if (isDarkPaper) {
      // Inverted: paper stays put, ink is lifted towards white.
      return _channelMatrix(
        gain: -gain,
        offsets: [
          paper.r * 255 + 255 * gain,
          paper.g * 255 + 255 * gain,
          paper.b * 255 + 255 * gain,
        ],
      );
    }
    return _channelMatrix(
      gain: gain,
      offsets: [
        paper.r * 255 - 255 * gain,
        paper.g * 255 - 255 * gain,
        paper.b * 255 - 255 * gain,
      ],
    );
  }

  /// Slope that lands the file's black ink on this paper's ink colour.
  double get _baseGain {
    final paperLuma = _luma(background);
    final inkLuma = _luma(onBackground);
    final span = (paperLuma - inkLuma).abs();
    // Guard against a degenerate palette; 0.85 is the typical value.
    return span < 0.05 ? 0.9 : span;
  }

  static double _luma(Color c) => c.r * 0.299 + c.g * 0.587 + c.b * 0.114;

  static ColorFilter _channelMatrix({
    required double gain,
    required List<double> offsets,
  }) {
    return ColorFilter.matrix(<double>[
      gain,
      0,
      0,
      0,
      offsets[0],
      0,
      gain,
      0,
      0,
      offsets[1],
      0,
      0,
      gain,
      0,
      offsets[2],
      0,
      0,
      0,
      1,
      0,
    ]);
  }

  String label(AppLocalizations l10n) => switch (this) {
    ReadingTheme.white => l10n.readingThemeWhite,
    ReadingTheme.cream => l10n.readingThemeCream,
    ReadingTheme.sepia => l10n.readingThemeSepia,
    ReadingTheme.sage => l10n.readingThemeSage,
    ReadingTheme.dark => l10n.readingThemeDark,
    ReadingTheme.nightBlue => l10n.readingThemeNight,
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
    this._lastDocumentId,
    this._appLocale,
    this._translatorEnabled,
    this._syncTranslationExperimental,
    this._instructionsSeeded,
    this._readingFont,
    this._readingWeight,
    this._readingContrast,
    this._readingBrightness,
    this._keepScreenOnWhileReading,
    this._keepScreenOnAboveBattery,
  );

  static const _sourceKey = 'source_language';
  static const _targetKey = 'target_language';
  static const _themeKey = 'theme_mode';
  static const _readingThemeKey = 'reading_theme';
  static const _lastDocumentKey = 'last_document_id';
  static const _appLocaleKey = 'app_locale';
  static const _translatorEnabledKey = 'translator_enabled';
  static const _syncTranslationKey = 'sync_translation_experimental';
  static const _instructionsSeededKey = 'instructions_seeded_v4';
  static const _readingFontKey = 'reading_font';
  static const _readingWeightKey = 'reading_weight';
  static const _readingContrastKey = 'reading_contrast';
  static const _readingBrightnessKey = 'reading_brightness';
  static const _keepScreenOnKey = 'keep_screen_on_while_reading';
  static const _keepScreenOnBatteryKey = 'keep_screen_on_above_battery';

  final SharedPreferences _prefs;
  TranslateLanguage _sourceLanguage;
  TranslateLanguage _targetLanguage;
  ThemeMode _themeMode;
  ReadingTheme _readingTheme;
  String? _lastDocumentId;
  Locale _appLocale;
  bool _translatorEnabled;
  bool _syncTranslationExperimental;
  bool _instructionsSeeded;
  ReadingFont _readingFont;
  int _readingWeight;
  double _readingContrast;
  double? _readingBrightness;
  bool _keepScreenOnWhileReading;
  int _keepScreenOnAboveBattery;

  /// Reading typography, applied wherever the app sets the text itself
  /// (compact mode, plain text) and, for contrast, to the PDF page image.
  ReadingFont get readingFont => _readingFont;

  /// 300..800 — how heavy the reading typeface is set.
  int get readingWeight => _readingWeight;

  /// 0..1 — extra contrast on top of the reading theme's defaults.
  double get readingContrast => _readingContrast;

  /// Per-reader window brightness. Null means to use the system setting.
  double? get readingBrightness => _readingBrightness;

  /// Keeps the display awake only while reading and only above the chosen
  /// battery reserve; below it Android's normal screen timeout takes over.
  bool get keepScreenOnWhileReading => _keepScreenOnWhileReading;
  int get keepScreenOnAboveBattery => _keepScreenOnAboveBattery;

  TranslateLanguage get sourceLanguage => _sourceLanguage;
  TranslateLanguage get targetLanguage => _targetLanguage;
  ThemeMode get themeMode => _themeMode;
  ReadingTheme get readingTheme => _readingTheme;

  /// Master switch for the whole translation feature — flags, model
  /// downloads, tap-to-translate, everything. Defaults on; turning it
  /// off leaves a plain PDF/text reader with no translation UI at all.
  bool get translatorEnabled => _translatorEnabled;

  /// Experimental opt-in: reflow splits into two panes, the bottom one
  /// showing a live translation of whatever's in focus up top.
  bool get syncTranslationExperimental => _syncTranslationExperimental;

  /// Whether the bundled instructions PDF has already been seeded into the
  /// library once. Set the very first time the app ever launches and never
  /// cleared again — so a later app *update* (as opposed to a fresh
  /// install) never re-adds it, even if the reader deleted it.
  bool get instructionsSeeded => _instructionsSeeded;

  /// The app's own interface language — independent of the source/target
  /// translation languages above. Defaults to Russian.
  Locale get appLocale => _appLocale;

  /// The document the reader was last inside, so a cold app launch can
  /// resume straight into it instead of always landing on the library.
  String? get lastDocumentId => _lastDocumentId;

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
        orElse: () => ThemeMode.light,
      ),
      ReadingTheme.values.firstWhere(
        (t) => t.name == readingThemeName,
        orElse: () => ReadingTheme.white,
      ),
      prefs.getString(_lastDocumentKey),
      Locale(prefs.getString(_appLocaleKey) ?? 'ru'),
      prefs.getBool(_translatorEnabledKey) ?? true,
      prefs.getBool(_syncTranslationKey) ?? false,
      prefs.getBool(_instructionsSeededKey) ?? false,
      ReadingFont.values.firstWhere(
        (f) => f.name == prefs.getString(_readingFontKey),
        orElse: () => ReadingFont.literata,
      ),
      prefs.getInt(_readingWeightKey) ?? 550,
      prefs.getDouble(_readingContrastKey) ?? 1.0,
      prefs.getDouble(_readingBrightnessKey) ?? 0.65,
      prefs.getBool(_keepScreenOnKey) ?? false,
      prefs.getInt(_keepScreenOnBatteryKey) ?? 20,
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

  Future<void> setReadingFont(ReadingFont font) async {
    if (font == _readingFont) return;
    _readingFont = font;
    await _prefs.setString(_readingFontKey, font.name);
    notifyListeners();
  }

  Future<void> setReadingWeight(int weight) async {
    final clamped = weight.clamp(300, 800);
    if (clamped == _readingWeight) return;
    _readingWeight = clamped;
    await _prefs.setInt(_readingWeightKey, clamped);
    notifyListeners();
  }

  Future<void> setReadingContrast(double contrast) async {
    final clamped = contrast.clamp(0.0, 1.0);
    if (clamped == _readingContrast) return;
    _readingContrast = clamped;
    await _prefs.setDouble(_readingContrastKey, clamped);
    notifyListeners();
  }

  Future<void> setReadingBrightness(double? brightness) async {
    final clamped = brightness?.clamp(0.05, 1.0).toDouble();
    if (clamped == _readingBrightness) return;
    _readingBrightness = clamped;
    if (clamped == null) {
      await _prefs.remove(_readingBrightnessKey);
    } else {
      await _prefs.setDouble(_readingBrightnessKey, clamped);
    }
    notifyListeners();
  }

  Future<void> setKeepScreenOnWhileReading(bool enabled) async {
    if (enabled == _keepScreenOnWhileReading) return;
    _keepScreenOnWhileReading = enabled;
    await _prefs.setBool(_keepScreenOnKey, enabled);
    notifyListeners();
  }

  Future<void> setKeepScreenOnAboveBattery(int percent) async {
    final clamped = percent.clamp(1, 100).toInt();
    if (clamped == _keepScreenOnAboveBattery) return;
    _keepScreenOnAboveBattery = clamped;
    await _prefs.setInt(_keepScreenOnBatteryKey, clamped);
    notifyListeners();
  }

  Future<void> setLastDocumentId(String? id) async {
    _lastDocumentId = id;
    if (id == null) {
      await _prefs.remove(_lastDocumentKey);
    } else {
      await _prefs.setString(_lastDocumentKey, id);
    }
  }

  Future<void> setAppLocale(Locale locale) async {
    if (locale == _appLocale) return;
    _appLocale = locale;
    await _prefs.setString(_appLocaleKey, locale.languageCode);
    notifyListeners();
  }

  Future<void> setTranslatorEnabled(bool enabled) async {
    if (enabled == _translatorEnabled) return;
    _translatorEnabled = enabled;
    await _prefs.setBool(_translatorEnabledKey, enabled);
    notifyListeners();
  }

  Future<void> setSyncTranslationExperimental(bool enabled) async {
    if (enabled == _syncTranslationExperimental) return;
    _syncTranslationExperimental = enabled;
    await _prefs.setBool(_syncTranslationKey, enabled);
    notifyListeners();
  }

  /// Marks the instructions PDF as seeded — called once, right after it's
  /// been added to the library on a fresh install. Deliberately has no
  /// matching "unset" — this must never fire a second time for the same
  /// install.
  Future<void> markInstructionsSeeded() async {
    if (_instructionsSeeded) return;
    _instructionsSeeded = true;
    await _prefs.setBool(_instructionsSeededKey, true);
  }
}
