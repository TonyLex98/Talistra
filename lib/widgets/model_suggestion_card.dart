import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/app_language.dart';
import '../services/model_download_service.dart';

/// A dismissible suggestion (not an automatic download) offering to fetch
/// the on-device translation models the reader currently needs. Progress
/// comes from the shared [ModelDownloadService], so this shows the exact
/// same state as the Settings screen or the reader's translation panel if
/// a download is already running from there.
class ModelSuggestionCard extends StatefulWidget {
  const ModelSuggestionCard({
    super.key,
    required this.languages,
    required this.onDone,
  });

  final List<TranslateLanguage> languages;
  final VoidCallback onDone;

  @override
  State<ModelSuggestionCard> createState() => _ModelSuggestionCardState();
}

class _ModelSuggestionCardState extends State<ModelSuggestionCard> {
  bool _dismissed = false;
  bool _requestedByMe = false;

  Future<void> _download() async {
    final downloadService = context.read<ModelDownloadService>();
    setState(() => _requestedByMe = true);
    for (final lang in widget.languages) {
      await downloadService.download(lang);
    }
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final names = widget.languages.map((l) => AppLanguage.byLanguage(l).displayName).join(', ');
    final downloadService = context.watch<ModelDownloadService>();
    final isDownloading = _requestedByMe && downloadService.isDownloading;

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
                    l10n.suggestDownloadTitle,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isDownloading
                        ? l10n.downloadingNamed(
                            AppLanguage.byLanguage(downloadService.activeLanguage!).displayName,
                            downloadService.elapsedSeconds,
                          )
                        : l10n.suggestDownloadBody(names),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (isDownloading)
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
                      onPressed: downloadService.isDownloading ? null : _download,
                      child: Text(l10n.download),
                    ),
                ],
              ),
            ),
            if (!isDownloading)
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
