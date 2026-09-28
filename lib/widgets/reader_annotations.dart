import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/annotation_service.dart';
import 'annotations_sheet.dart';
import 'reader_copy_menu.dart';

/// The bookmark and notes entries of a reader's «Ещё» menu: bookmark this
/// page (or take the bookmark off it), and the list of everything left in
/// the book. The same two in every reader.
///
/// Call from a build: it watches the bookmarks, so the first entry's wording
/// follows the page as the reader turns it.
List<ReaderMenuAction> annotationMenuActions(
  BuildContext context, {
  required String documentId,
  required int currentPage,
  required void Function(int page) goTo,
}) {
  final l10n = AppLocalizations.of(context);
  final annotations = context.watch<AnnotationService>();
  final bookmarked = annotations.isBookmarked(documentId, currentPage);
  return [
    ReaderMenuAction(
      icon: bookmarked ? Icons.bookmark_remove_outlined : Icons.bookmark_add,
      label: bookmarked ? l10n.removeBookmarkAction : l10n.addBookmarkAction,
      onSelected: () async {
        final messenger = ScaffoldMessenger.of(context);
        final added = await annotations.toggleBookmark(documentId, currentPage);
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(added ? l10n.bookmarkAdded : l10n.bookmarkRemoved),
              duration: const Duration(seconds: 2),
            ),
          );
      },
    ),
    ReaderMenuAction(
      icon: Icons.bookmarks_outlined,
      label: l10n.bookmarksAction,
      onSelected: () async {
        final page = await showAnnotationsSheet(
          context,
          documentId: documentId,
        );
        if (page != null && context.mounted) goTo(page);
      },
    ),
  ];
}

/// Asks the reader what they make of [quote] and keeps it as a note on
/// [page].
Future<void> addNoteFromSelection(
  BuildContext context, {
  required String documentId,
  required int page,
  required String quote,
}) async {
  final annotations = context.read<AnnotationService>();
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  final note = await showNoteDialog(context, quote: quote);
  if (note == null) return;
  await annotations.addNote(
    documentId: documentId,
    page: page,
    quote: quote,
    note: note,
  );
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(l10n.noteSaved),
        duration: const Duration(seconds: 2),
      ),
    );
}
