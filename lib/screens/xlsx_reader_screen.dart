import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:excel/excel.dart' as xlsx;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/reading_display_service.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';

/// Height of the floating top bar (excluding the status-bar inset it sits
/// under) — matched to the other readers'.
const double _barHeight = 50;

class _XlsxSheet {
  const _XlsxSheet({required this.name, required this.rows});
  final String name;
  final List<List<String>> rows;
}

/// Reader for spreadsheets (.xlsx/.xls) — a table, not prose, so this skips
/// every other reader's pagination/translation/search machinery entirely:
/// just sheet tabs over a pannable, pinch-zoomable grid.
class XlsxReaderScreen extends StatefulWidget {
  const XlsxReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<XlsxReaderScreen> createState() => _XlsxReaderScreenState();
}

class _XlsxReaderScreenState extends State<XlsxReaderScreen>
    with WidgetsBindingObserver {
  late LibraryDocument _document;

  List<_XlsxSheet> _sheets = const [];
  int _sheetIndex = 0;
  bool _loading = true;
  String? _error;

  static const _minDwellSeconds = 3;
  static const _maxCountedDwellSeconds = 600;
  DateTime? _pageEnteredAt;

  // Looked up once, in initState, and reused in dispose() — a fresh
  // context.read() there is unsafe (the element may already be deactivated
  // by the time dispose runs, e.g. when a rename elsewhere in the tree
  // triggers a rebuild that tears this route down).
  late final ReadingDisplayService _readingDisplay;
  late final StatisticsService _statistics;

  @override
  void initState() {
    super.initState();
    _readingDisplay = context.read<ReadingDisplayService>();
    _statistics = context.read<StatisticsService>();
    _document = context.read<LibraryService>().documents.firstWhere(
      (d) => d.id == widget.documentId,
    );
    _sheetIndex = math.max(0, _document.lastPage - 1);
    _pageEnteredAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    context.read<SettingsService>().setLastDocumentId(widget.documentId);
    unawaited(_readingDisplay.enter(context.read<SettingsService>()));
    _load();
  }

  /// Sheets with no cell text at all (a hidden helper tab, or one the
  /// workbook declares but never wrote to) get no tab — nothing to show.
  Future<void> _load() async {
    try {
      final bytes = await File(_document.filePath).readAsBytes();
      final workbook = xlsx.Excel.decodeBytes(bytes);
      final sheets = <_XlsxSheet>[];
      for (final entry in workbook.tables.entries) {
        final rows = <List<String>>[
          for (final row in entry.value.rows)
            [for (final cell in row) cell?.value?.toString() ?? ''],
        ];
        if (rows.any((row) => row.any((cell) => cell.isNotEmpty))) {
          sheets.add(_XlsxSheet(name: entry.key, rows: rows));
        }
      }
      if (!mounted) return;
      final index = sheets.isEmpty
          ? 0
          : _sheetIndex.clamp(0, sheets.length - 1);
      setState(() {
        _sheets = sheets;
        _sheetIndex = index;
        _loading = false;
      });
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: index + 1,
        pageCount: sheets.length,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_readingDisplay.exit());
    _flushDwellTime();
    super.dispose();
  }

  void _flushDwellTime() {
    final enteredAt = _pageEnteredAt;
    if (enteredAt == null) return;
    final elapsed = DateTime.now().difference(enteredAt).inSeconds;
    _pageEnteredAt = null;
    if (elapsed < _minDwellSeconds) return;
    _statistics.recordReading(
      documentId: widget.documentId,
      seconds: elapsed.clamp(0, _maxCountedDwellSeconds),
      page: _sheetIndex + 1,
    );
  }

  /// Same rule as every other reader: time only counts while the app is
  /// actually in the foreground, never with the screen off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pageEnteredAt ??= DateTime.now();
    } else {
      _flushDwellTime();
    }
  }

  void _selectSheet(int index) {
    if (index == _sheetIndex) return;
    _flushDwellTime();
    _pageEnteredAt = DateTime.now();
    setState(() => _sheetIndex = index);
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: index + 1,
      pageCount: _sheets.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          // Same shape as every other reader: the content owns the screen
          // and the bar floats above it.
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: _barHeight),
                child: _buildBody(settings, scheme),
              ),
            ),
          ),
          _buildFloatingBar(l10n, settings),
        ],
      ),
    );
  }

  Widget _buildFloatingBar(AppLocalizations l10n, SettingsService settings) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: settings.readingTheme.secondaryBackground,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
        child: Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: SizedBox(
            height: _barHeight,
            child: Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      _document.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(SettingsService settings, ColorScheme scheme) {
    if (_loading) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final error = _error;
    if (error != null) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).openFailed(error)),
          ),
        ),
      );
    }
    if (_sheets.isEmpty) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).spreadsheetEmpty),
          ),
        ),
      );
    }
    return ColoredBox(
      color: settings.readingTheme.background,
      child: Column(
        children: [
          if (_sheets.length > 1) _buildSheetTabs(scheme),
          Expanded(
            child: _SheetGrid(sheet: _sheets[_sheetIndex], scheme: scheme),
          ),
        ],
      ),
    );
  }

  Widget _buildSheetTabs(ColorScheme scheme) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _sheets.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return ChoiceChip(
            label: Text(_sheets[index].name),
            selected: index == _sheetIndex,
            onSelected: (_) => _selectSheet(index),
          );
        },
      ),
    );
  }
}

/// A spreadsheet's rows and columns, pannable and pinch-zoomable in both
/// directions at once — [InteractiveViewer] handles that natively for a
/// naturally-sized (not viewport-constrained) child, without a bespoke
/// two-axis scroll-sync implementation.
class _SheetGrid extends StatelessWidget {
  const _SheetGrid({required this.sheet, required this.scheme});

  final _XlsxSheet sheet;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final columnCount = sheet.rows.fold<int>(
      0,
      (max, row) => math.max(max, row.length),
    );
    if (columnCount == 0) return const SizedBox.shrink();
    return InteractiveViewer(
      constrained: false,
      minScale: 0.5,
      maxScale: 4,
      boundaryMargin: const EdgeInsets.all(40),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Table(
          border: TableBorder.all(color: scheme.outlineVariant),
          defaultColumnWidth: const IntrinsicColumnWidth(),
          children: [
            for (var r = 0; r < sheet.rows.length; r++)
              TableRow(
                decoration: r == 0
                    ? BoxDecoration(color: scheme.surfaceContainerHighest)
                    : null,
                children: [
                  for (var c = 0; c < columnCount; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Text(
                        c < sheet.rows[r].length ? sheet.rows[r][c] : '',
                        style: TextStyle(
                          fontWeight: r == 0
                              ? FontWeight.w700
                              : FontWeight.w400,
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
}
