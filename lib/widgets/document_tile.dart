import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/djvu_service.dart';
import '../services/library_service.dart';
import '../services/page_image_cache.dart';
import '../utils/pdf_region_renderer.dart';

/// The star and the menu are the least interesting thing on a library row and
/// the title is the most, so they get the compact metrics the reader headers
/// use instead of Material's 48px box — the width they hand back goes to the
/// name, which is what truncates.
const EdgeInsets _actionPadding = EdgeInsets.symmetric(horizontal: 4);
const BoxConstraints _actionBox = BoxConstraints(minWidth: 34, minHeight: 40);

class DocumentTile extends StatefulWidget {
  const DocumentTile({
    super.key,
    required this.document,
    required this.onTap,
    required this.onDelete,
    required this.onToggleStar,
  });

  final LibraryDocument document;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onToggleStar;

  @override
  State<DocumentTile> createState() => _DocumentTileState();
}

/// One page's physical dimensions, for the pulled-down detail panel — either
/// a real scan's pixel size and DPI (DjVu), or a fixed-layout page's
/// physical size in millimetres (PDF). Text formats have neither: they
/// reflow to fit the screen, so there is no fixed "page size" to report.
sealed class _PageMeasurement {
  const _PageMeasurement();
}

class _ScanResolution extends _PageMeasurement {
  const _ScanResolution(this.width, this.height, this.dpi);
  final int width;
  final int height;
  final int dpi;
}

class _PageSizeMm extends _PageMeasurement {
  const _PageSizeMm(this.width, this.height);
  final int width;
  final int height;
}

/// A short, format-only badge — "PDF", "DJVU", "EPUB" and so on. These are
/// acronyms, identical in every language the app ships, so this is a plain
/// lookup rather than a localized string.
String _formatBadge(String format) {
  switch (format) {
    case 'djvu':
    case 'djv':
      return 'DJVU';
    case 'epub':
    case 'fb2':
    case 'rtf':
    case 'docx':
    case 'txt':
    case 'md':
    case 'xlsx':
    case 'xls':
      return format.toUpperCase();
    default:
      return 'PDF';
  }
}

class _DocumentTileState extends State<DocumentTile> {
  late Future<Uint8List?> _thumbnailFuture;

  /// Whether the pulled-down detail panel (full title + format + page
  /// size/resolution) is showing.
  bool _expanded = false;

  /// Net vertical movement of the drag currently in progress, used to
  /// decide at the end whether it was a deliberate pull rather than an
  /// incidental wobble mid-tap.
  double _dragDistance = 0;

  /// The page measurement (see [_PageMeasurement]), fetched lazily — only
  /// once the panel is actually opened, since it means opening the file a
  /// second time and most tiles are never expanded.
  Future<_PageMeasurement?>? _measurementFuture;

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
      _measurementFuture = null;
      _expanded = false;
    }
  }

  /// Reads the cached first-page thumbnail if there is one; otherwise
  /// renders and caches it now, so it's instant every time after the
  /// first time this document is shown in the library.
  Future<Uint8List?> _loadOrGenerateThumbnail() async {
    // Plain text and spreadsheets have no page to render a thumbnail from —
    // the fallback icon below is the whole story for these.
    if (widget.document.isTextDocument || widget.document.isXlsx) return null;

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

  /// The physical page size or scan resolution, fetched once and cached for
  /// the life of this tile. Opens the document a second time (briefly —
  /// only the first page's own header is actually read), which is why this
  /// only ever runs on demand rather than alongside the thumbnail.
  Future<_PageMeasurement?> _loadMeasurement() async {
    if (widget.document.isTextDocument || widget.document.isXlsx) return null;
    try {
      if (widget.document.isDjvu) {
        final document = await DjvuDocument.open(widget.document.filePath);
        try {
          final info = await document.pageInfo(0);
          if (info.width <= 0 || info.height <= 0) return null;
          return _ScanResolution(info.width, info.height, info.dpi);
        } finally {
          await document.close();
        }
      }
      final renderer = await PdfRegionRenderer.open(widget.document.filePath);
      try {
        final size = await renderer.pageSize(0);
        if (size.width <= 0 || size.height <= 0) return null;
        // PDF page geometry is in points (1/72 inch); a reader thinks in
        // millimetres, not points, for what a *physical* page size means.
        const mmPerPoint = 25.4 / 72;
        return _PageSizeMm(
          (size.width * mmPerPoint).round(),
          (size.height * mmPerPoint).round(),
        );
      } finally {
        await renderer.close();
      }
    } catch (_) {
      return null;
    }
  }

  void _setExpanded(bool value) {
    if (_expanded == value) return;
    setState(() => _expanded = value);
    if (value) _measurementFuture ??= _loadMeasurement();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasProgress = widget.document.pageCount > 0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _expanded ? () => _setExpanded(false) : widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildThumbnail(scheme),
                  const SizedBox(width: 14),
                  Expanded(
                    // A drag anywhere on the title/progress area pulls the
                    // full title and page details into view — the small
                    // chevron next to the title is the same action for
                    // anyone who taps instead of drags.
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: (_) => _dragDistance = 0,
                      onVerticalDragUpdate: (details) =>
                          _dragDistance += details.delta.dy,
                      onVerticalDragEnd: (_) {
                        if (_dragDistance > 18) {
                          _setExpanded(true);
                        } else if (_dragDistance < -18) {
                          _setExpanded(false);
                        }
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  widget.document.title,
                                  maxLines: _expanded ? null : 1,
                                  overflow: _expanded
                                      ? null
                                      : TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => _setExpanded(!_expanded),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: AnimatedRotation(
                                    turns: _expanded ? 0.5 : 0,
                                    duration: const Duration(milliseconds: 180),
                                    child: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      size: 20,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
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
                    visualDensity: VisualDensity.compact,
                    padding: _actionPadding,
                    constraints: _actionBox,
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _showMenu(context),
                    visualDensity: VisualDensity.compact,
                    padding: _actionPadding,
                    constraints: _actionBox,
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? _buildDetails(context, scheme)
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context, ColorScheme scheme) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _DetailChip(text: _formatBadge(widget.document.format)),
          if (widget.document.pageCount > 0)
            _DetailChip(
              text: l10n.statisticsPagesShort(widget.document.pageCount),
            ),
          FutureBuilder<_PageMeasurement?>(
            future: _measurementFuture,
            builder: (context, snapshot) {
              final measurement = snapshot.data;
              if (measurement == null) return const SizedBox.shrink();
              final text = switch (measurement) {
                _ScanResolution(:final width, :final height, :final dpi) =>
                  l10n.documentDetailsScanResolution(width, height, dpi),
                _PageSizeMm(:final width, :final height) =>
                  l10n.documentDetailsPageSize(width, height),
              };
              return _DetailChip(text: text);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 44,
        height: 56,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _thumbnailFuture,
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes == null || bytes.isEmpty) {
                  return ColoredBox(
                    color: scheme.primaryContainer,
                    child: Icon(
                      // Text formats (txt, epub, fb2, rtf, docx) and
                      // spreadsheets have no page to make a thumbnail from,
                      // so they get their own icon rather than the PDF one.
                      widget.document.isTextDocument
                          ? Icons.menu_book_rounded
                          : widget.document.isXlsx
                          ? Icons.table_chart_rounded
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
            // The format badge sits on every thumbnail, not just the
            // fallback icon — a page image alone doesn't say whether it
            // came from a PDF or a DjVu scan, and the two read and turn
            // pages differently enough that it's worth knowing at a glance.
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(5),
                  ),
                ),
                child: Text(
                  _formatBadge(widget.document.format),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 7,
                    fontWeight: FontWeight.w700,
                    height: 1,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ],
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
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.renameBook),
              onTap: () {
                Navigator.pop(ctx);
                _renameDocument(context);
              },
            ),
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

  Future<void> _renameDocument(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final library = context.read<LibraryService>();
    final controller = TextEditingController(text: widget.document.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.renameDocumentTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 1,
          decoration: InputDecoration(hintText: l10n.renameDocumentHint),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    // The dialog's own exit transition is still animating the TextField for
    // a frame or two after showDialog resolves — disposing the controller
    // synchronously here fights that in-flight rebuild ("used after being
    // disposed"). A post-frame callback waits for it to actually finish.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    final trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    await library.rename(widget.document.id, trimmed);
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

/// One pill in the pulled-down detail row (format, page count, page size).
class _DetailChip extends StatelessWidget {
  const _DetailChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
