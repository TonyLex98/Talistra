import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';

/// The reader's «Ещё» menu: the one place a reader reaches for when dragging
/// selection handles across a page — or a whole book — is slower than just
/// taking all of it. Every reader shows the same two actions, so the bar ends
/// the same way in all of them; only where the text comes from differs, which
/// is what [pageText] and [bookText] are for.
class ReaderCopyMenu extends StatelessWidget {
  const ReaderCopyMenu({
    super.key,
    required this.pageText,
    required this.bookText,
  });

  /// The page on screen, already gathered, or null when there is none.
  final String? Function() pageText;

  /// The whole book's text, gathered on tap: for a scanned or PDF book that
  /// means reading every page, which is not something a build can afford.
  final FutureOr<String?> Function() bookText;

  void _open(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: Text(l10n.copyPageAction),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copy(context, pageText());
              },
            ),
            ListTile(
              leading: const Icon(Icons.library_books_outlined),
              title: Text(l10n.copyBookAction),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copyBook(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context, String? text) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    messenger.clearSnackBars();
    if (text == null || text.trim().isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.nothingToCopy),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.copiedLabel),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Gathering a whole book can take seconds, so the reader is told the app
  /// is working before the result replaces the notice.
  Future<void> _copyBook(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(l10n.copyingBookText)));
    final text = await bookText();
    // Reading a whole book takes long enough that the reader may have left.
    if (!context.mounted) return;
    messenger.removeCurrentSnackBar();
    await _copy(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 22,
      icon: const Icon(Icons.more_vert),
      tooltip: AppLocalizations.of(context).readerMoreTooltip,
      onPressed: () => _open(context),
    );
  }
}
