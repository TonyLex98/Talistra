import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'translation_service.dart';

/// Tracks the single in-flight model download (ML Kit only downloads one
/// model at a time in practice) so every screen — the home suggestion
/// card, settings, and the reader's translation panel — shows the exact
/// same progress instead of each kicking off its own independent
/// download and timer.
class ModelDownloadService extends ChangeNotifier {
  ModelDownloadService(this._translationService);

  final TranslationService _translationService;

  TranslateLanguage? _activeLanguage;
  int _elapsedSeconds = 0;
  Timer? _ticker;
  DateTime? _startedAt;

  TranslateLanguage? get activeLanguage => _activeLanguage;
  int get elapsedSeconds => _elapsedSeconds;
  bool get isDownloading => _activeLanguage != null;

  bool isDownloadingLanguage(TranslateLanguage language) => _activeLanguage == language;

  /// Downloads [language]'s model, unless a download is already running (in
  /// which case callers should just watch this service instead of starting
  /// a second one). Returns true on success.
  Future<bool> download(TranslateLanguage language) async {
    if (isDownloading) return false;
    _activeLanguage = language;
    _elapsedSeconds = 0;
    _startedAt = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds = DateTime.now().difference(_startedAt!).inSeconds;
      notifyListeners();
    });
    notifyListeners();

    var success = true;
    try {
      await _translationService.downloadModel(language);
    } catch (_) {
      success = false;
    } finally {
      _ticker?.cancel();
      _activeLanguage = null;
      notifyListeners();
    }
    return success;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
