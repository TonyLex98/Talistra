import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Result of translating a single word or short phrase.
class TranslationResult {
  const TranslationResult({
    required this.original,
    required this.translated,
    required this.source,
    required this.target,
  });

  final String original;
  final String translated;
  final TranslateLanguage source;
  final TranslateLanguage target;
}

/// Thrown when a translation was requested but one of the two on-device
/// language models isn't downloaded yet.
class ModelsNotReadyException implements Exception {
  ModelsNotReadyException(this.missing);
  final List<TranslateLanguage> missing;
}

/// Wraps ML Kit's on-device translator. Translation happens fully on the
/// device (no server round-trip) once the small language models are
/// downloaded, which keeps word lookups instant and working offline.
class TranslationService {
  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();

  OnDeviceTranslator? _translator;
  TranslateLanguage? _cachedSource;
  TranslateLanguage? _cachedTarget;

  Future<bool> isModelDownloaded(TranslateLanguage language) {
    return _modelManager.isModelDownloaded(language.bcpCode);
  }

  Future<bool> downloadModel(TranslateLanguage language) {
    return _modelManager.downloadModel(language.bcpCode, isWifiRequired: false);
  }

  Future<bool> deleteModel(TranslateLanguage language) {
    return _modelManager.deleteModel(language.bcpCode);
  }

  Future<List<TranslateLanguage>> missingModels(
    TranslateLanguage source,
    TranslateLanguage target,
  ) async {
    final missing = <TranslateLanguage>[];
    for (final lang in {source, target}) {
      if (!await isModelDownloaded(lang)) missing.add(lang);
    }
    return missing;
  }

  OnDeviceTranslator _translatorFor(
    TranslateLanguage source,
    TranslateLanguage target,
  ) {
    if (_translator != null &&
        _cachedSource == source &&
        _cachedTarget == target) {
      return _translator!;
    }
    _translator?.close();
    _translator = OnDeviceTranslator(sourceLanguage: source, targetLanguage: target);
    _cachedSource = source;
    _cachedTarget = target;
    return _translator!;
  }

  /// Translates [text] from [source] to [target]. Throws
  /// [ModelsNotReadyException] if either language model still needs to be
  /// downloaded, so callers can prompt the user instead of silently
  /// triggering a large download mid-read.
  Future<TranslationResult> translate({
    required String text,
    required TranslateLanguage source,
    required TranslateLanguage target,
  }) async {
    final missing = await missingModels(source, target);
    if (missing.isNotEmpty) {
      throw ModelsNotReadyException(missing);
    }
    final translator = _translatorFor(source, target);
    final translated = await translator.translateText(text);
    return TranslationResult(
      original: text,
      translated: translated,
      source: source,
      target: target,
    );
  }

  void dispose() {
    _translator?.close();
  }
}
