import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/vocabulary_service.dart';
import '../widgets/text_prompt_dialog.dart';

/// The reader's dictionary: every word they kept while reading, with the
/// sentence they met it in — reviewed as flashcards, exported for Anki.
class VocabularyScreen extends StatelessWidget {
  const VocabularyScreen({super.key});

  Future<void> _export(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final csv = context.read<VocabularyService>().toCsv();
    try {
      // With a byte-order mark, so Excel reads the Cyrillic as Cyrillic.
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
      final path = await FilePicker.saveFile(
        fileName: 'talistra_vocabulary.csv',
        bytes: bytes,
      );
      if (path == null) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.vocabularyExported)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.backupFailed('$error'))),
      );
    }
  }

  Future<void> _editTranslation(
    BuildContext context,
    VocabularyEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context);
    final text = await showTextPrompt(
      context,
      title: entry.word,
      confirmLabel: l10n.save,
      initial: entry.translation ?? '',
      hint: l10n.vocabularyTranslationHint,
    );
    if (text == null || !context.mounted) return;
    await context.read<VocabularyService>().updateTranslation(entry.id, text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final vocabulary = context.watch<VocabularyService>();
    final entries = vocabulary.entries;
    final due = vocabulary.due.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.vocabularyTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: l10n.vocabularyExportAction,
            onPressed: entries.isEmpty ? null : () => _export(context),
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.vocabularyEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          : ListView.builder(
              itemCount: entries.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Card(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.vocabularyHint,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  l10n.vocabularyDue(due),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              FilledButton.icon(
                                icon: const Icon(Icons.style_outlined),
                                label: Text(l10n.practiceAction),
                                onPressed: due == 0
                                    ? null
                                    : () => Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              const PracticeScreen(),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final entry = entries[index - 1];
                return Dismissible(
                  key: ValueKey(entry.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    color: scheme.errorContainer,
                    child: Icon(Icons.delete_outline, color: scheme.error),
                  ),
                  onDismissed: (_) => vocabulary.remove(entry.id),
                  child: ListTile(
                    title: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: entry.word,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          if (entry.translation?.isNotEmpty ?? false)
                            TextSpan(text: ' — ${entry.translation}'),
                        ],
                      ),
                    ),
                    subtitle: entry.sentence == null
                        ? null
                        : Text(
                            entry.sentence!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontStyle: FontStyle.italic),
                          ),
                    trailing: _BoxMeter(box: entry.box),
                    onTap: () => _editTranslation(context, entry),
                  ),
                );
              },
            ),
    );
  }
}

/// How far along a word is, as a row of dots — one per box it has climbed.
class _BoxMeter extends StatelessWidget {
  const _BoxMeter({required this.box});

  final int box;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final boxes = VocabularyService.intervals.length - 1;
    return Semantics(
      label: '$box / $boxes',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < boxes; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(left: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < box ? scheme.primary : scheme.outlineVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// Flashcards over the words due now: the word and where it was met first,
/// the translation on request, and the reader's own verdict deciding when
/// the word comes back.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  late final List<VocabularyEntry> _queue = [
    ...context.read<VocabularyService>().due,
  ];
  bool _revealed = false;

  Future<void> _answer(bool remembered) async {
    final entry = _queue.removeAt(0);
    await context.read<VocabularyService>().review(
      entry.id,
      remembered: remembered,
    );
    if (!mounted) return;
    setState(() {
      // A forgotten word comes round again at the end of this session.
      if (!remembered) _queue.add(entry);
      _revealed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.practiceAction),
        actions: [
          if (_queue.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('${_queue.length}'),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _queue.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    l10n.practiceDone,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Card(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _buildCard(_queue.first, theme, scheme),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!_revealed)
                      FilledButton(
                        onPressed: () => setState(() => _revealed = true),
                        child: Text(l10n.practiceShowAnswer),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _answer(false),
                              child: Text(l10n.practiceForgot),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _answer(true),
                              child: Text(l10n.practiceKnow),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildCard(
    VocabularyEntry entry,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final sentence = entry.sentence;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.word,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (sentence != null) ...[
          const SizedBox(height: 16),
          Text(
            sentence,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
        if (_revealed) ...[
          const Divider(height: 40),
          Text(
            entry.translation?.isNotEmpty ?? false ? entry.translation! : '—',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: scheme.primary,
            ),
          ),
          if (entry.sentenceTranslation != null) ...[
            const SizedBox(height: 12),
            Text(
              entry.sentenceTranslation!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ],
    );
  }
}
