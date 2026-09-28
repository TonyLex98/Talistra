import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Total reading time and number of distinct pages read, for one document.
class DocumentStats {
  const DocumentStats({
    required this.documentId,
    required this.seconds,
    required this.pages,
  });
  final String documentId;
  final int seconds;
  final int pages;
}

/// A calendar-day snapshot of reading. Pages are unique within the day,
/// while time is the actual foreground dwell time recorded that day.
class DailyStats {
  const DailyStats({
    required this.day,
    required this.seconds,
    required this.pages,
  });
  final DateTime day;
  final int seconds;
  final int pages;
}

/// Tracks genuine reading activity — time spent and pages actually read.
///
/// Two things make the difference between a number that means something
/// and one that doesn't:
///
///  * Pages are counted as a *set* per document, not as a running tally.
///    Scrolling back over a page you've already read, or bouncing between
///    two pages, used to add to the count every single time, so "pages
///    read" could run far past the length of the book.
///  * Time is only ever accumulated by the reader screen while it's
///    actually on screen and the app is in the foreground (it stops the
///    clock on every lifecycle change), so a document left open in the
///    background overnight adds nothing.
class StatisticsService extends ChangeNotifier {
  StatisticsService._(
    this._prefs,
    this._secondsByDocument,
    this._pagesByDocument,
    this._secondsByDay,
    this._pagesByDay,
  );

  /// v2 stores which pages were read rather than how many times a page
  /// was visited. Reading time carries over from v1; the old page tallies
  /// are dropped, since there's no way to reconstruct a set of pages from
  /// an inflated count.
  static const _key = 'reading_statistics_v3';
  static const _previousKey = 'reading_statistics_v2';
  static const _legacyKey = 'reading_statistics_v1';

  final SharedPreferences _prefs;
  final Map<String, int> _secondsByDocument;
  final Map<String, Set<int>> _pagesByDocument;
  final Map<String, int> _secondsByDay;
  final Map<String, Set<String>> _pagesByDay;

  int get totalSeconds => _secondsByDocument.values.fold(0, (a, b) => a + b);
  int get totalPages => _pagesByDocument.values.fold(0, (a, b) => a + b.length);

  List<DocumentStats> get byDocument => [
    for (final id in {..._secondsByDocument.keys, ..._pagesByDocument.keys})
      DocumentStats(
        documentId: id,
        seconds: _secondsByDocument[id] ?? 0,
        pages: _pagesByDocument[id]?.length ?? 0,
      ),
  ]..sort((a, b) => b.seconds.compareTo(a.seconds));

  List<DailyStats> get byDay => [
    for (final key in {..._secondsByDay.keys, ..._pagesByDay.keys})
      DailyStats(
        day: DateTime.parse(key),
        seconds: _secondsByDay[key] ?? 0,
        pages: _pagesByDay[key]?.length ?? 0,
      ),
  ]..sort((a, b) => b.day.compareTo(a.day));

  static Future<StatisticsService> load(SharedPreferences prefs) async {
    final seconds = <String, int>{};
    final pages = <String, Set<int>>{};
    final secondsByDay = <String, int>{};
    final pagesByDay = <String, Set<String>>{};

    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry
            in (decoded['seconds'] as Map<String, dynamic>? ?? const {})
                .entries) {
          seconds[entry.key] = (entry.value as num).toInt();
        }
        for (final entry
            in (decoded['readPages'] as Map<String, dynamic>? ?? const {})
                .entries) {
          pages[entry.key] = {
            for (final page in entry.value as List<dynamic>)
              (page as num).toInt(),
          };
        }
        for (final entry
            in (decoded['dailySeconds'] as Map<String, dynamic>? ?? const {})
                .entries) {
          secondsByDay[entry.key] = (entry.value as num).toInt();
        }
        for (final entry
            in (decoded['dailyPages'] as Map<String, dynamic>? ?? const {})
                .entries) {
          pagesByDay[entry.key] = {
            for (final page in entry.value as List<dynamic>) page as String,
          };
        }
      } catch (_) {
        // Corrupted stats shouldn't take down the app — start fresh.
      }
    } else {
      // v2 had the same all-time document data, but no date information.
      // Preserve it as all-time history; daily cards start accumulating from
      // the update rather than inventing dates for old reading.
      final legacy =
          prefs.getString(_previousKey) ?? prefs.getString(_legacyKey);
      if (legacy != null) {
        try {
          final decoded = jsonDecode(legacy) as Map<String, dynamic>;
          for (final entry
              in (decoded['seconds'] as Map<String, dynamic>? ?? const {})
                  .entries) {
            seconds[entry.key] = (entry.value as num).toInt();
          }
        } catch (_) {
          // Same as above: a bad legacy blob is simply not migrated.
        }
      }
    }
    return StatisticsService._(prefs, seconds, pages, secondsByDay, pagesByDay);
  }

  /// Records [seconds] of foreground reading time against [documentId],
  /// and marks [page] (1-based) as read if given. A page already in the
  /// set doesn't count again.
  Future<void> recordReading({
    required String documentId,
    required int seconds,
    int? page,
  }) async {
    var changed = false;
    if (seconds > 0) {
      _secondsByDocument[documentId] =
          (_secondsByDocument[documentId] ?? 0) + seconds;
      changed = true;
      final day = _dayKey(DateTime.now());
      _secondsByDay[day] = (_secondsByDay[day] ?? 0) + seconds;
    }
    if (page != null && page > 0) {
      final pages = _pagesByDocument.putIfAbsent(documentId, () => <int>{});
      if (pages.add(page)) changed = true;
      final day = _dayKey(DateTime.now());
      _pagesByDay.putIfAbsent(day, () => <String>{}).add('$documentId:$page');
    }
    if (!changed) return;
    await _persist();
    notifyListeners();
  }

  /// Drops everything recorded for [documentId] — called when the reader
  /// deletes the document, so the totals keep matching the per-book list
  /// instead of counting books that are no longer in the library.
  Future<void> forget(String documentId) async {
    final had =
        _secondsByDocument.remove(documentId) != null ||
        _pagesByDocument.remove(documentId) != null;
    if (!had) return;
    await _persist();
    notifyListeners();
  }

  /// Moves everything recorded for [from] onto [to] — a book restored from a
  /// backup comes back under a new library id.
  Future<void> reassign(String from, String to) async {
    if (from == to) return;
    var changed = false;
    final seconds = _secondsByDocument.remove(from);
    if (seconds != null) {
      _secondsByDocument[to] = (_secondsByDocument[to] ?? 0) + seconds;
      changed = true;
    }
    final pages = _pagesByDocument.remove(from);
    if (pages != null) {
      _pagesByDocument.putIfAbsent(to, () => <int>{}).addAll(pages);
      changed = true;
    }
    for (final day in _pagesByDay.values) {
      final moved = [
        for (final entry in day)
          if (entry.startsWith('$from:')) entry,
      ];
      for (final entry in moved) {
        day
          ..remove(entry)
          ..add('$to${entry.substring(from.length)}');
        changed = true;
      }
    }
    if (!changed) return;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final payload = jsonEncode({
      'seconds': _secondsByDocument,
      'readPages': {
        for (final entry in _pagesByDocument.entries)
          entry.key: entry.value.toList(),
      },
      'dailySeconds': _secondsByDay,
      'dailyPages': {
        for (final entry in _pagesByDay.entries)
          entry.key: entry.value.toList(),
      },
    });
    await _prefs.setString(_key, payload);
  }

  static String _dayKey(DateTime value) => DateTime(
    value.year,
    value.month,
    value.day,
  ).toIso8601String().substring(0, 10);
}
