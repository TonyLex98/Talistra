import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';

/// The long-press-to-mark layer every reading surface shares: the system's own
/// selection (press and hold a word, widen the mark with its handles, drag it
/// across lines) with the reader's own actions on the marked text — copy it,
/// or send it through the translation card.
///
/// [SelectionArea] has to sit *outside* the pager or scroller it covers. Put
/// inside one, the selection region claims a horizontal drag the moment the
/// finger passes its slop — and the swipe that was meant to turn the page
/// never reaches the [PageView] at all.
///
/// The marked text is reported through [onTranslateSelection]; copying is
/// handled here, because it is the same in every reader.
class ReadingSelectionArea extends StatefulWidget {
  const ReadingSelectionArea({
    super.key,
    required this.translatorEnabled,
    required this.onTranslateSelection,
    this.allText,
    required this.child,
  });

  /// Whether the reader may translate what they marked: with the translator
  /// switched off, the menu offers copy alone.
  final bool translatorEnabled;

  /// Called with the text the reader marked, once they ask for its
  /// translation.
  final void Function(String text) onTranslateSelection;

  /// The whole page as the reader's own model has it — with the line breaks
  /// its text was laid out with. Without it, «Копировать всё» can only glue
  /// together what the selection region reports, and a region reports each
  /// paragraph on its own, with nothing between them.
  final String? Function()? allText;

  final Widget child;

  @override
  State<ReadingSelectionArea> createState() => ReadingSelectionAreaState();
}

class ReadingSelectionAreaState extends State<ReadingSelectionArea> {
  final GlobalKey<SelectionAreaState> _areaKey =
      GlobalKey<SelectionAreaState>();

  /// What the reader has marked right now. A mark of nothing — a caret
  /// between two words, a run of whitespace — gets no menu at all, so the
  /// menu is built from this rather than from the selection's geometry.
  String? _marked;

  /// Drops the mark, its handles and its menu. Callers use this when the
  /// reader moves on (a page turned, a search landed), so a mark never hangs
  /// over text that has since been turned past.
  void clearSelection() {
    clearMark();
    _areaKey.currentState?.selectableRegion.clearSelection();
  }

  /// Forgets the marked text the menu was built from, without touching the
  /// system's own selection.
  void clearMark() {
    if (_marked == null) return;
    setState(() => _marked = null);
  }

  void _onSelectionChanged(SelectedContent? content) {
    final text = content?.plainText.trim();
    if (text == null || text.isEmpty) {
      clearMark();
      return;
    }
    if (text == _marked) return;
    setState(() => _marked = text);
  }

  void _finish(
    SelectableRegionState region,
    void Function(String? text) action,
  ) {
    final text = _marked;
    region.hideToolbar();
    region.clearSelection();
    clearMark();
    action(text);
  }

  /// Marks everything the region holds — the page being read, plus whatever
  /// the pager has already built around it — and leaves the mark up, so the
  /// reader can still widen or shrink it before acting on it.
  void _selectAll(SelectableRegionState region) {
    region.selectAll(SelectionChangedCause.toolbar);
  }

  /// Takes the whole page to the clipboard in one go, for a reader who wants
  /// all of it and doesn't care to drag two handles across it first.
  void _copyAll(SelectableRegionState region) {
    final text = widget.allText?.call() ?? _allOfRegion(region);
    region.hideToolbar();
    region.clearSelection();
    clearMark();
    _copy(text);
  }

  /// Everything the region itself holds, for a surface that can't say what
  /// its page is. Marking it reports the text through [SelectionArea]'s own
  /// callback first, which is where this reads it back from.
  String? _allOfRegion(SelectableRegionState region) {
    region.selectAll();
    return _marked;
  }

  Widget _buildMenu(BuildContext context, SelectableRegionState region) {
    final text = _marked;
    if (text == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final anchors = region.contextMenuAnchors;
    final items = [
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: l10n.selectionCopy,
        onPressed: () => _finish(region, _copy),
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: l10n.selectionCopyAll,
        onPressed: () => _copyAll(region),
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: l10n.selectionSelectAll,
        onPressed: () => _selectAll(region),
      ),
      if (widget.translatorEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.custom,
          label: l10n.selectionTranslateShort,
          onPressed: () => _finish(
            region,
            (text) => text == null ? null : widget.onTranslateSelection(text),
          ),
        ),
    ];
    return ReadingSelectionMenu(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      children: AdaptiveTextSelectionToolbar.getAdaptiveButtons(
        context,
        items,
      ).toList(),
    );
  }

  void _copy(String? text) {
    final l10n = AppLocalizations.of(context);
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.nothingToCopy),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.copiedLabel),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      key: _areaKey,
      onSelectionChanged: _onSelectionChanged,
      contextMenuBuilder: _buildMenu,
      child: widget.child,
    );
  }
}

/// The menu shown over marked text: the Android selection toolbar, except that
/// what doesn't fit a row wraps to a second one instead of hiding behind an
/// overflow button.
///
/// [TextSelectionToolbar] pages its buttons: on a phone four Russian labels
/// never fit one row, so «Перевести» sat behind a ⋮ nobody thinks to tap —
/// and the row that was shown ran past the edge of the screen. Anchoring and
/// look are the platform's own; only the layout is ours.
class ReadingSelectionMenu extends StatelessWidget {
  const ReadingSelectionMenu({
    super.key,
    required this.anchorAbove,
    required this.anchorBelow,
    required this.children,
  });

  /// Where the marked text starts: the menu sits above it when there is room.
  final Offset anchorAbove;

  /// Where the marked text ends, used when the menu has to go below it.
  final Offset anchorBelow;

  final List<Widget> children;

  static const double _screenPadding = 8;

  /// How far the menu sits from the text above it, and from the text below it
  /// — the platform's own gaps, which leave room for the selection handles.
  static const double _gapAbove = 8;
  static const double _gapBelow = 28;

  @override
  Widget build(BuildContext context) {
    final paddingAbove = MediaQuery.paddingOf(context).top + _screenPadding;
    // The anchors arrive in screen coordinates; the delegate works in this
    // widget's own, which start inside the padding added below.
    final shift = Offset(_screenPadding, paddingAbove);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        paddingAbove,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove: anchorAbove - shift - const Offset(0, _gapAbove),
          anchorBelow: anchorBelow - shift + const Offset(0, _gapBelow),
        ),
        // The overlay asks for the menu's size without saying what the screen
        // is, so a row of buttons wide enough to need wrapping never learns it
        // should wrap. The screen's own width is the only honest bound.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 2 * _screenPadding,
          ),
          child: Material(
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            color: _surfaceOf(Theme.of(context).colorScheme),
            elevation: 1,
            type: MaterialType.card,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The toolbar's own surface: the theme's, unless the theme never asked for
  /// a different one — in which case the platform menu is plain white (or
  /// grey) and so is this.
  static Color _surfaceOf(ColorScheme scheme) {
    final isDefaultSurface = switch (scheme.brightness) {
      Brightness.light => identical(
        ThemeData().colorScheme.surface,
        scheme.surface,
      ),
      Brightness.dark => identical(
        ThemeData.dark().colorScheme.surface,
        scheme.surface,
      ),
    };
    if (!isDefaultSurface) return scheme.surface;
    return switch (scheme.brightness) {
      Brightness.light => const Color(0xffffffff),
      Brightness.dark => const Color(0xff424242),
    };
  }
}
