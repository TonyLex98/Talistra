import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../utils/table_of_contents.dart';

/// The book's table of contents as a sheet: every chapter with the page it
/// starts on, the one being read marked and scrolled into view. Resolves to
/// the page the reader picked, or null when they closed it.
Future<int?> showContentsSheet(
  BuildContext context, {
  required List<TocEntry> entries,
  required int currentPage,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) =>
        _ContentsSheet(entries: entries, currentPage: currentPage),
  );
}

class _ContentsSheet extends StatelessWidget {
  const _ContentsSheet({required this.entries, required this.currentPage});

  final List<TocEntry> entries;
  final int currentPage;

  static const double _rowHeight = 52;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final current = currentTocIndex(entries, currentPage);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, controller) {
        if (entries.isEmpty) {
          return ListView(
            controller: controller,
            children: [
              _Header(title: l10n.contentsAction),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.contentsEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          );
        }
        // Opened on the chapter being read rather than at the top of a
        // long list the reader would have to scroll down themselves.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (current == null || !controller.hasClients) return;
          final target = (current - 2) * _rowHeight;
          if (controller.offset == 0 && target > 0) {
            controller.jumpTo(
              target.clamp(0.0, controller.position.maxScrollExtent),
            );
          }
        });
        return ListView.builder(
          controller: controller,
          itemCount: entries.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _Header(title: l10n.contentsAction);
            final i = index - 1;
            final entry = entries[i];
            final selected = i == current;
            return SizedBox(
              height: _rowHeight,
              child: ListTile(
                selected: selected,
                selectedTileColor: scheme.primaryContainer.withValues(
                  alpha: 0.45,
                ),
                contentPadding: EdgeInsets.only(
                  left: 16.0 + (entry.level - 1) * 18,
                  right: 16,
                ),
                title: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: entry.level == 1
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                trailing: Text(
                  '${entry.page}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                onTap: () => Navigator.of(context).pop(entry.page),
              ),
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}
