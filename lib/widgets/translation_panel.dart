import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../models/app_language.dart';
import '../services/translation_service.dart';
import '../utils/sentence_finder.dart';

/// Bottom panel shown when the reader selects a word: translates the word
/// itself and, if it was found inside a sentence on the page, the whole
/// sentence too — with the matching word highlighted on both sides.
class TranslationPanel extends StatefulWidget {
  const TranslationPanel({
    super.key,
    required this.word,
    required this.sentenceMatch,
    required this.source,
    required this.target,
    required this.translationService,
    required this.onClose,
  });

  final String word;
  final SentenceMatch? sentenceMatch;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final VoidCallback onClose;

  @override
  State<TranslationPanel> createState() => _TranslationPanelState();
}

enum _Status { loading, needsDownload, downloading, ready, error }

class _TranslationPanelState extends State<TranslationPanel> {
  _Status _status = _Status.loading;
  String? _wordTranslation;
  String? _sentenceTranslation;
  List<TranslateLanguage> _missing = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = _Status.loading);
    try {
      final sentence = widget.sentenceMatch?.sentence;
      final results = await Future.wait([
        widget.translationService.translate(
          text: widget.word,
          source: widget.source,
          target: widget.target,
        ),
        if (sentence != null)
          widget.translationService.translate(
            text: sentence,
            source: widget.source,
            target: widget.target,
          ),
      ]);
      if (!mounted) return;
      setState(() {
        _wordTranslation = results[0].translated;
        _sentenceTranslation = sentence != null ? results[1].translated : null;
        _status = _Status.ready;
      });
    } on ModelsNotReadyException catch (e) {
      if (!mounted) return;
      setState(() {
        _missing = e.missing;
        _status = _Status.needsDownload;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = _Status.error);
    }
  }

  Future<void> _downloadMissing() async {
    setState(() => _status = _Status.downloading);
    try {
      for (final lang in _missing) {
        await widget.translationService.downloadModel(lang);
      }
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = _Status.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 10,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 10, 12, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        widget.word,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
                _buildBody(context, scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme) {
    switch (_status) {
      case _Status.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Переводим...'),
            ],
          ),
        );
      case _Status.needsDownload:
        final names = _missing.map((l) => AppLanguage.byLanguage(l).displayName).join(', ');
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Нужна языковая модель: $names.\nОна скачивается один раз и работает офлайн.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _downloadMissing,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Скачать'),
              ),
            ],
          ),
        );
      case _Status.downloading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Загрузка модели...'),
            ],
          ),
        );
      case _Status.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: scheme.error),
              const SizedBox(width: 6),
              const Expanded(child: Text('Не удалось перевести')),
              TextButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        );
      case _Status.ready:
        return _buildReady(context, scheme);
    }
  }

  Widget _buildReady(BuildContext context, ColorScheme scheme) {
    final wordStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w700,
    );
    final bodyStyle = Theme.of(context).textTheme.bodyLarge;
    final highlightStyle = bodyStyle?.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.primary,
      backgroundColor: scheme.primaryContainer.withValues(alpha: 0.5),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.arrow_downward, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(_wordTranslation ?? '', style: wordStyle)),
            IconButton(
              icon: const Icon(Icons.copy_outlined, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: 'Копировать перевод',
              onPressed: () {
                if (_wordTranslation == null) return;
                Clipboard.setData(ClipboardData(text: _wordTranslation!));
              },
            ),
          ],
        ),
        if (widget.sentenceMatch != null && _sentenceTranslation != null) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          Text(
            'Перевод предложения',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text.rich(
            _highlightTranslatedSentence(
              _sentenceTranslation!,
              _wordTranslation,
              bodyStyle,
              highlightStyle,
            ),
          ),
        ],
      ],
    );
  }

  TextSpan _highlightedSpan(
    String text,
    int start,
    int end,
    TextStyle? base,
    TextStyle? highlight,
  ) {
    if (start < 0 || end > text.length || start >= end) {
      return TextSpan(text: text, style: base);
    }
    return TextSpan(
      style: base,
      children: [
        TextSpan(text: text.substring(0, start)),
        TextSpan(text: text.substring(start, end), style: highlight),
        TextSpan(text: text.substring(end)),
      ],
    );
  }

  TextSpan _highlightTranslatedSentence(
    String sentence,
    String? word,
    TextStyle? base,
    TextStyle? highlight,
  ) {
    if (word == null || word.trim().isEmpty) return TextSpan(text: sentence, style: base);
    final match = findFuzzyWordMatch(sentence, word);
    if (match == null) return TextSpan(text: sentence, style: base);
    return _highlightedSpan(sentence, match.start, match.end, base, highlight);
  }
}
