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
    required this.readingPage,
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

  /// Called with the match the reader has landed on, and every match found
  /// so far — the reader jumps to the landed-on match's page and highlights
  /// it, and also washes over that page's other matches (from the full
  /// list) more faintly, so their positions are visible at a glance too.
  final void Function(SearchMatch match, List<SearchMatch> allMatches) onSelect;

  /// Where the reader is, as a zero-based page index in the same coordinates
  /// as [SearchMatch.pageIndex]. A search starts looking from there rather
  /// than from the first page of the book: looking something up mid-book
  /// should not throw the reader back to the beginning.
  final int Function() readingPage;

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

  /// Where the reader was when the search bar opened (or the page they last
  /// stepped to). Captured rather than read per batch, because landing on a
  /// match moves the reader and the next batch would otherwise measure itself
  /// against the page the previous batch sent them to.
  int _fromPage = 0;

  /// Whether the reader has stepped through the matches with the arrows.
  /// Until they do, matches that are still arriving keep re-landing the search
  /// on the closest one to where they were reading; once they have, the
  /// search leaves them alone.
  bool _readerMoved = false;

  /// Whether a real (non-empty) query has actually been run — distinguishes
  /// "haven't searched yet" (no query, or still typing) from "searched and
  /// found nothing", which are otherwise the same empty [_matches] list.
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    _fromPage = widget.readingPage();
  }

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
    // Only a page the reader chose — by stepping through the last search's
    // matches — moves where the next one starts. A page the search itself
    // landed on doesn't: refining a query a letter at a time would otherwise
    // start each version from wherever the shorter one happened to open.
    if (_readerMoved) _fromPage = widget.readingPage();
    _readerMoved = false;
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
              setState(() => _matches = [..._matches, ...batch]);
              _landOnClosestMatch();
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

  /// Lands the search on the match closest ahead of where the reader was.
  ///
  /// Matches can arrive in several batches and out of page order (the PDF
  /// reader's isolates finish pages whenever they finish them), so this runs
  /// again per batch: each re-landing is nearer than the last, and the search
  /// settles once the book has been scanned.
  void _landOnClosestMatch() {
    if (_readerMoved || _matches.isEmpty) return;
    final best = _closestAheadOf(_matches, _fromPage);
    if (_current >= 0 && _matches[_current] == _matches[best]) return;
    setState(() => _current = best);
    widget.onSelect(_matches[best], _matches);
  }

  void _selectAt(int index) {
    final wrapped = _wrap(index);
    if (wrapped < 0) return;
    _readerMoved = true;
    setState(() => _current = wrapped);
    widget.onSelect(_matches[wrapped], _matches);
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
              suffixIconConstraints: const BoxConstraints(
                minWidth: 0,
                minHeight: 0,
              ),
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

/// The index of the match a search should open on: the first one on
/// [fromPage] or later, or the first in the book when everything found lies
/// behind where the reader was — the same wrap the arrows make at the ends.
///
/// [matches] is not in page order while a PDF index is still being built, so
/// "closest" is worked out by page rather than by position in the list.
int _closestAheadOf(List<SearchMatch> matches, int fromPage) {
  var best = 0;
  for (var i = 1; i < matches.length; i++) {
    final candidate = matches[i];
    final incumbent = matches[best];
    if (candidate.pageIndex == incumbent.pageIndex) continue;
    final ahead = candidate.pageIndex >= fromPage;
    final incumbentAhead = incumbent.pageIndex >= fromPage;
    if (ahead != incumbentAhead) {
      if (ahead) best = i;
      continue;
    }
    // Both on the same side of the reader: the smallest page number is the
    // nearest one ahead, and — when neither is ahead and the search wraps to
    // the start of the book — the first match found.
    if (candidate.pageIndex < incumbent.pageIndex) best = i;
  }
  return best;
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
