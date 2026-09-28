import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/annotation_service.dart';

/// A book's bookmarks and notes as a sheet, in page order. Resolves to the
/// page the reader picked, or null when they closed it.
Future<int?> showAnnotationsSheet(
  BuildContext context, {
  required String documentId,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AnnotationsSheet(documentId: documentId),
  );
}

/// Asks what the reader wants to say about [quote]. Resolves to their words
/// (possibly empty — marking a passage is a note of its own), or null when
/// they cancelled.
Future<String?> showNoteDialog(
  BuildContext context, {
  required String quote,
  String? initial,
}) {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(initial == null ? l10n.noteDialogTitle : l10n.editNote),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Quote(text: quote, maxLines: 6),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: l10n.noteHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(l10n.save),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

class _AnnotationsSheet extends StatelessWidget {
  const _AnnotationsSheet({required this.documentId});

  final String documentId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final service = context.watch<AnnotationService>();
    final annotations = service.forDocument(documentId);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              l10n.bookmarksAction,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (annotations.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.bookmarksEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final annotation in annotations)
            _AnnotationTile(annotation: annotation),
        ],
      ),
    );
  }
}

class _AnnotationTile extends StatelessWidget {
  const _AnnotationTile({required this.annotation});

  final Annotation annotation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final service = context.read<AnnotationService>();
    final note = annotation.note;
    return ListTile(
      leading: Icon(
        annotation.isBookmark ? Icons.bookmark : Icons.format_quote,
        color: scheme.primary,
      ),
      title: Text(
        l10n.bookmarkPage(annotation.page),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: annotation.isBookmark
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                _Quote(text: annotation.quote!, maxLines: 3),
                if (note != null && note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(note, style: TextStyle(color: scheme.onSurface)),
                ],
              ],
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!annotation.isBookmark)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.editNote,
              onPressed: () async {
                final text = await showNoteDialog(
                  context,
                  quote: annotation.quote!,
                  initial: note ?? '',
                );
                if (text != null) await service.updateNote(annotation.id, text);
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.delete,
            onPressed: () => service.remove(annotation.id),
          ),
        ],
      ),
      onTap: () => Navigator.of(context).pop(annotation.page),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote({required this.text, required this.maxLines});

  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontStyle: FontStyle.italic,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
