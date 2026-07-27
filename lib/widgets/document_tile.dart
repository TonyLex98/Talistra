import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/djvu_service.dart';
import '../services/page_image_cache.dart';
import '../utils/pdf_region_renderer.dart';

class DocumentTile extends StatefulWidget {
  const DocumentTile({
    super.key,
    required this.document,
    required this.index,
    required this.onTap,
    required this.onDelete,
    required this.onToggleStar,
  });

  final LibraryDocument document;

  /// This tile's position in the (already-sorted) library list, needed
  /// to attach the drag handle to the right item in the surrounding
  /// [ReorderableListView].
  final int index;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onToggleStar;

  @override
  State<DocumentTile> createState() => _DocumentTileState();
}

class _DocumentTileState extends State<DocumentTile> {
  late Future<Uint8List?> _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _thumbnailFuture = _loadOrGenerateThumbnail();
  }

  @override
  void didUpdateWidget(covariant DocumentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.id != widget.document.id) {
      _thumbnailFuture = _loadOrGenerateThumbnail();
    }
  }

  /// Reads the cached first-page thumbnail if there is one; otherwise
  /// renders and caches it now, so it's instant every time after the
  /// first time this document is shown in the library.
  Future<Uint8List?> _loadOrGenerateThumbnail() async {
    // Plain text has no page to render a thumbnail from — the fallback
    // icon below is the whole story for these.
    if (widget.document.isTextDocument) return null;

    final cache = context.read<ThumbnailCache>();
    final cached = await cache.read(widget.document.id);
    if (cached != null) return cached;

    try {
      if (widget.document.isDjvu) {
        final document = await DjvuDocument.open(widget.document.filePath);
        try {
          final info = await document.pageInfo(0);
          const width = 160;
          final height = (width / info.aspectRatio).round().clamp(1, 300);
          final bytes = await document.renderPage(
            0,
            width: width,
            height: height,
          );
          await cache.write(widget.document.id, bytes);
          return bytes;
        } finally {
          await document.close();
        }
      }

      final renderer = await PdfRegionRenderer.open(widget.document.filePath);
      try {
        final size = await renderer.pageSize(0);
        if (size.width <= 0 || size.height <= 0) return null;
        final scale = 160.0 / size.width;
        final bytes = await renderer.renderRegion(
          pageIndex: 0,
          pdfBounds: Rect.fromLTWH(0, 0, size.width, size.height),
          scale: scale,
        );
        if (bytes != null) await cache.write(widget.document.id, bytes);
        return bytes;
      } finally {
        await renderer.close();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasProgress = widget.document.pageCount > 0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _buildThumbnail(scheme),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.document.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    if (hasProgress) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: widget.document.progress,
                          minHeight: 4,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.pageProgress(
                          widget.document.lastPage,
                          widget.document.pageCount,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ] else
                      Text(
                        l10n.neverOpened,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  widget.document.starred
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: widget.document.starred ? scheme.primary : null,
                ),
                tooltip: widget.document.starred
                    ? l10n.unpinTooltip
                    : l10n.pinTooltip,
                onPressed: widget.onToggleStar,
              ),
              ReorderableDragStartListener(
                index: widget.index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.drag_handle),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () => _showMenu(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 44,
        height: 56,
        child: FutureBuilder<Uint8List?>(
          future: _thumbnailFuture,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null || bytes.isEmpty) {
              return ColoredBox(
                color: scheme.primaryContainer,
                child: Icon(
                  // Text formats (txt, epub, fb2, rtf, docx) have no page to
                  // make a thumbnail from, so they get a book icon rather
                  // than the PDF one.
                  widget.document.isTextDocument
                      ? Icons.menu_book_rounded
                      : widget.document.isDjvu
                      ? Icons.auto_stories_rounded
                      : Icons.picture_as_pdf_rounded,
                  color: scheme.onPrimaryContainer,
                ),
              );
            }
            return Image.memory(bytes, fit: BoxFit.cover);
          },
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(l10n.removeFromLibrary),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteDocumentTitle),
        content: Text(l10n.deleteDocumentBody(widget.document.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onDelete();
  }
}
