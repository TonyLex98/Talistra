import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../models/app_language.dart';
import '../services/translation_service.dart';

/// A dismissible suggestion (not an automatic download) offering to fetch
/// the on-device translation models the reader currently needs, with a
/// live elapsed-time indicator while downloading. ML Kit's Android SDK
/// doesn't expose byte-level download progress, so this is the most
/// honest signal available — real elapsed seconds, not a fabricated
/// percentage.
class ModelSuggestionCard extends StatefulWidget {
  const ModelSuggestionCard({
    super.key,
    required this.languages,
    required this.translationService,
    required this.onDone,
  });

  final List<TranslateLanguage> languages;
  final TranslationService translationService;
  final VoidCallback onDone;

  @override
  State<ModelSuggestionCard> createState() => _ModelSuggestionCardState();
}

class _ModelSuggestionCardState extends State<ModelSuggestionCard> {
  bool _dismissed = false;
  bool _downloading = false;
  TranslateLanguage? _currentlyDownloading;
  int _elapsedSeconds = 0;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    for (final lang in widget.languages) {
      setState(() {
        _currentlyDownloading = lang;
        _elapsedSeconds = 0;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds++);
      });
      try {
        await widget.translationService.downloadModel(lang);
      } catch (_) {
        // Move on to the next language; the card will resurface for any
        // language that's still missing next time this screen loads.
      }
      _ticker?.cancel();
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final names = widget.languages.map((l) => AppLanguage.byLanguage(l).displayName).join(', ');

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.translate, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Скачать словарь для перевода?',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _downloading
                        ? 'Загружаем «${AppLanguage.byLanguage(_currentlyDownloading!).displayName}»... $_elapsedSeconds с'
                        : 'Языки: $names. Нужно скачать один раз, дальше перевод работает офлайн.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_downloading)
                    SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onSecondaryContainer,
                      ),
                    )
                  else
                    FilledButton.tonal(
                      onPressed: _download,
                      child: const Text('Скачать'),
                    ),
                ],
              ),
            ),
            if (!_downloading)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                color: scheme.onSecondaryContainer,
                onPressed: () => setState(() => _dismissed = true),
              ),
          ],
        ),
      ),
    );
  }
}
