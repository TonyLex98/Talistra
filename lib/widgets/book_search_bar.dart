import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../utils/text_search.dart';

/// The search field shown in the reader's top bar while searching.
///
/// It is deliberately NOT a dialog: the reader drops this row into its
/// floating top bar (in place of the title), so the page stays visible below
/// and a match is highlighted right in the file the reader is looking at.
///
/// The caller supplies [search] — for a query it either streams matches back
/// in [onBatch] (the PDF reader's background isolate, page by page) or calls
/// it once with the whole list (text formats, already in memory) and finishes
/// with [onDone]. [onSelect] is called whenever the reader lands on a match
/// (first after a search, next/previous from the arrows, or a tapped row).
class BookSearchBar extends StatefulWidget {
  const BookSearchBar({
    super.key,
    required this.search,
    required this.onSelect,
    required this.onClose,
  });

  /// Runs a search for [query]. May deliver matches in several [onBatch]
  /// calls as pages finish (PDF) or one (text), then [onDone] exactly once.
  final Future<void> Function(
    String query, {
    required void Function(List<SearchMatch>) onBatch,
    required void Function() onDone,
  })
  search;

  /// Called with the match the reader has landed on; the reader jumps to its
  /// page and highlights it in the file.
  final ValueChanged<SearchMatch> onSelect;

  final VoidCallback onClose;

  @override
  State<BookSearchBar> createState() => _BookSearchBarState();
}

class _BookSearchBarState extends State<BookSearchBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _searching = false;
  List<SearchMatch> _matches = const [];
  int _current = -1;
  Timer? _debounce;
  int _searchGeneration = 0;

  /// Whether a real (non-empty) query has actually been run — distinguishes
  /// "haven't searched yet" (no query, or still typing) from "searched and
  /// found nothing", which are otherwise the same empty [_matches] list.
  bool _hasSearched = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  void _runSearch() {
    final query = _controller.text;
    if (query.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _matches = const [];
          _searching = false;
          _hasSearched = false;
          _current = -1;
        });
      }
      return;
    }
    final generation = ++_searchGeneration;
    setState(() {
      _searching = true;
      _hasSearched = true;
      _matches = const [];
      _current = -1;
    });
    unawaited(
      widget
          .search(
            query,
            onBatch: (batch) {
              if (!mounted || generation != _searchGeneration) return;
              setState(() {
                _matches = [..._matches, ...batch];
                if (_current < 0) _current = 0;
              });
              if (_current == 0 && _matches.isNotEmpty) {
                widget.onSelect(_matches.first);
              }
            },
            onDone: () {
              if (!mounted || generation != _searchGeneration) return;
              setState(() => _searching = false);
            },
          )
          .catchError((_) {
            if (!mounted || generation != _searchGeneration) return;
            setState(() {
              _matches = const [];
              _searching = false;
              _current = -1;
            });
          }),
    );
  }

  void _selectAt(int index) {
    final wrapped = _wrap(index);
    if (wrapped < 0) return;
    setState(() => _current = wrapped);
    widget.onSelect(_matches[wrapped]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasResults = _matches.isNotEmpty;

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            style: const TextStyle(fontSize: 14),
            onChanged: (_) => _scheduleSearch(),
            onSubmitted: (_) => _runSearch(),
            decoration: InputDecoration(
              hintText: l10n.searchHint,
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
              suffixIcon: (_searching && !hasResults)
                  ? const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: _MiniSpinner(size: 14, strokeWidth: 2),
                    )
                  : (!hasResults && _hasSearched)
                  ? Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        l10n.searchNoResults,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : null,
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
            ),
          ),
        ),
        const SizedBox(width: 4),
        _ArrowButton(
          icon: Icons.arrow_upward,
          tooltip: l10n.searchPrevious,
          enabled: hasResults,
          onTap: () => _selectAt(_current - 1),
        ),
        const SizedBox(width: 2),
        if (hasResults)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 64),
            child: Text(
              '${_current + 1}/${_matches.length}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(width: 2),
        _ArrowButton(
          icon: Icons.arrow_downward,
          tooltip: l10n.searchNext,
          enabled: hasResults,
          onTap: () => _selectAt(_current + 1),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          tooltip: l10n.cancel,
          visualDensity: VisualDensity.compact,
          onPressed: widget.onClose,
        ),
      ],
    );
  }

  /// Wraps next/previous so the arrows always move, even at the ends.
  int _wrap(int index) {
    if (_matches.isEmpty) return -1;
    return (index % _matches.length + _matches.length) % _matches.length;
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      icon: Icon(
        icon,
        color: enabled ? null : scheme.onSurfaceVariant.withValues(alpha: 0.4),
      ),
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
    );
  }
}

/// A small, self-contained loading spinner that is guaranteed to stay inside
/// its box. (A plain `CircularProgressIndicator` paints a fixed ~36px disc that
/// ignores its constraints and would overflow the compact search row.)
class _MiniSpinner extends StatefulWidget {
  const _MiniSpinner({required this.size, required this.strokeWidth});

  final double size;
  final double strokeWidth;

  @override
  State<_MiniSpinner> createState() => _MiniSpinnerState();
}

class _MiniSpinnerState extends State<_MiniSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0,
      upperBound: 1,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final color = Theme.of(context).colorScheme.primary;
          return CustomPaint(
            painter: _SpinnerPainter(
              progress: _controller.value,
              color: color,
              strokeWidth: widget.strokeWidth,
            ),
          );
        },
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    const startAngle = -90 * 3.14159265 / 180;
    const sweep = 270 * 3.14159265 / 180;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, startAngle + progress * sweep, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) =>
      old.progress != progress || old.color != color;
}
