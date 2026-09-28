import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/app_language.dart';
import '../services/model_download_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../services/vocabulary_service.dart';
import '../utils/script_check.dart';
import '../utils/sentence_finder.dart';
import 'language_picker_sheet.dart';

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

enum _Status { loading, needsDownload, ready, error }

class _TranslationPanelState extends State<TranslationPanel> {
  _Status _status = _Status.loading;
  String? _wordTranslation;
  String? _sentenceTranslation;
  List<TranslateLanguage> _missing = const [];
  ModelDownloadService? _downloadService;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<ModelDownloadService>();
    if (_downloadService != service) {
      _downloadService?.removeListener(_onDownloadServiceChanged);
      _downloadService = service..addListener(_onDownloadServiceChanged);
    }
  }

  @override
  void dispose() {
    _downloadService?.removeListener(_onDownloadServiceChanged);
    super.dispose();
  }

  // If a download that this panel is waiting on finishes (whether started
  // from here, Settings, or the home screen suggestion), retry the
  // translation automatically instead of leaving the user stuck.
  void _onDownloadServiceChanged() {
    if (_status == _Status.needsDownload &&
        _downloadService?.isDownloading == false &&
        mounted) {
      _load();
    }
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
    final downloadService = context.read<ModelDownloadService>();
    for (final lang in _missing) {
      await downloadService.download(lang);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A compact floating card anchored near the selection (see callers'
    // Positioned wrapper), rather than a full-width bottom sheet — a big
    // bar covering a third of the screen for one word felt heavy-handed.
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 10,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 320,
          maxHeight: MediaQuery.sizeOf(context).height * 0.45,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      widget.word,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_canKeep) _buildSaveButton(context),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              if (_wrongLanguage) _buildWrongLanguageNotice(context, scheme),
              _buildBody(context, scheme),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether what is being translated is a word or a phrase worth a card —
  /// not a whole marked paragraph.
  bool get _canKeep =>
      widget.word.trim().split(RegExp(r'\s+')).length <= 6 &&
      widget.word.length <= 80;

  Widget _buildSaveButton(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final saved = context.watch<VocabularyService>().contains(
      widget.word,
      widget.source.bcpCode,
    );
    return IconButton(
      icon: Icon(
        saved ? Icons.bookmark_added : Icons.bookmark_add_outlined,
        size: 20,
      ),
      visualDensity: VisualDensity.compact,
      tooltip: saved ? l10n.wordAlreadySaved : l10n.saveWordAction,
      onPressed: saved || _status == _Status.loading ? null : _saveWord,
    );
  }

  /// Keeps the word in the reader's dictionary with the sentence it was met
  /// in, and both translations as far as they have come in.
  Future<void> _saveWord() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final added = await context.read<VocabularyService>().add(
      word: widget.word,
      sourceLanguage: widget.source.bcpCode,
      targetLanguage: widget.target.bcpCode,
      translation: _wordTranslation,
      sentence: widget.sentenceMatch?.sentence,
      sentenceTranslation: _sentenceTranslation,
    );
    messenger
      ?..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(added ? l10n.wordSaved : l10n.wordAlreadySaved),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// True when the text being translated clearly isn't in the language the
  /// reader picked as the original — the difference between "the translator
  /// is broken" and "the translator is pointed at the wrong language".
  bool get _wrongLanguage {
    final sample = widget.sentenceMatch?.sentence ?? widget.word;
    return looksLikeWrongSourceLanguage(sample, widget.source);
  }

  Widget _buildWrongLanguageNotice(BuildContext context, ColorScheme scheme) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8, right: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.wrongSourceLanguage(
              AppLanguage.byLanguage(widget.source).displayName,
            ),
            style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _pickSourceLanguage(l10n),
              child: Text(l10n.changeSourceLanguage),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSourceLanguage(AppLocalizations l10n) async {
    final settings = context.read<SettingsService>();
    final picked = await showLanguagePicker(
      context: context,
      current: widget.source,
      title: l10n.fromLanguagePickerTitle,
    );
    if (picked != null) await settings.setSourceLanguage(picked);
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme) {
    final l10n = AppLocalizations.of(context);
    switch (_status) {
      case _Status.loading:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(l10n.translating),
            ],
          ),
        );
      case _Status.needsDownload:
        return _buildNeedsDownload(context, scheme);
      case _Status.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: scheme.error),
              const SizedBox(width: 6),
              Expanded(child: Text(l10n.translationFailed)),
              TextButton(onPressed: _load, child: Text(l10n.retry)),
            ],
          ),
        );
      case _Status.ready:
        return _buildReady(context, scheme);
    }
  }

  Widget _buildNeedsDownload(BuildContext context, ColorScheme scheme) {
    final l10n = AppLocalizations.of(context);
    final names = _missing
        .map((l) => AppLanguage.byLanguage(l).displayName)
        .join(', ');
    final downloadService = context.watch<ModelDownloadService>();
    final relevantDownload = _missing.contains(downloadService.activeLanguage);

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.needsModelBody(names),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          if (relevantDownload)
            Row(
              children: [
                const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(l10n.downloadingProgress(downloadService.elapsedSeconds)),
              ],
            )
          else
            FilledButton.tonalIcon(
              onPressed: downloadService.isDownloading
                  ? null
                  : _downloadMissing,
              icon: const Icon(Icons.download, size: 18),
              label: Text(l10n.download),
            ),
        ],
      ),
    );
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
              tooltip: AppLocalizations.of(context).copyTranslationTooltip,
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
            AppLocalizations.of(context).sentenceTranslationLabel,
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
    if (word == null || word.trim().isEmpty) {
      return TextSpan(text: sentence, style: base);
    }
    final match = findFuzzyWordMatch(sentence, word);
    if (match == null) return TextSpan(text: sentence, style: base);
    return _highlightedSpan(sentence, match.start, match.end, base, highlight);
  }
}
