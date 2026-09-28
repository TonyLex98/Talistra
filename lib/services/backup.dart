import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/library_document.dart';
import 'annotation_service.dart';
import 'vocabulary_service.dart';

/// A backup of everything the reader has made in the app — reading progress,
/// bookmarks and notes, the vocabulary, statistics and settings — as one JSON
/// file they can keep anywhere and restore on another phone.
///
/// The books themselves stay out: they can be gigabytes, and the reader has
/// them already. A restored book is recognised by its file (see
/// [LibraryDocument.sourceFingerprint]) once it is back in the library, and
/// picks its progress, notes and statistics up again then.

const backupFormat = 'talistra-backup';
const backupVersion = 1;

const _libraryKey = 'library_documents';
const _statisticsKey = 'reading_statistics_v3';

/// Books from a restored backup that aren't in the library yet, waiting for
/// the reader to add them again.
const pendingRestoreKey = 'pending_restore_v1';

/// The reader's settings worth carrying to another phone. Not what is only
/// true of this install — which book was open last, whether the bundled
/// guide was added.
const _settingKeys = [
  'source_language',
  'target_language',
  'theme_mode',
  'reading_theme',
  'app_locale',
  'translator_enabled',
  'sync_translation_experimental',
  'reading_font',
  'reading_weight',
  'reading_contrast',
  'reading_brightness',
  'keep_screen_on_while_reading',
  'keep_screen_on_above_battery',
];

/// The backup of what [prefs] holds now, as the text of the file.
String createBackup(SharedPreferences prefs, {DateTime? now}) {
  final settings = <String, Object>{};
  for (final key in _settingKeys) {
    final value = prefs.get(key);
    if (value != null) settings[key] = value;
  }
  final library = [
    for (final raw in prefs.getStringList(_libraryKey) ?? const <String>[])
      _tryDecode(raw),
  ].whereType<Map<String, dynamic>>().toList();
  return const JsonEncoder.withIndent(' ').convert({
    'format': backupFormat,
    'version': backupVersion,
    'createdAt': (now ?? DateTime.now()).toIso8601String(),
    'settings': settings,
    'library': library,
    'annotations': _tryDecode(prefs.getString(AnnotationService.storageKey)),
    'vocabulary': _tryDecode(prefs.getString(VocabularyService.storageKey)),
    'statistics': _tryDecode(prefs.getString(_statisticsKey)),
  });
}

Object? _tryDecode(String? raw) {
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// Merges the backup in [raw] into what [prefs] holds, written straight to
/// storage; the services have to be loaded again afterwards to see it.
///
/// Nothing the reader has now is thrown away: settings take the backup's
/// values, but progress is only carried onto books found in both, notes and
/// words are added to the ones already here, and statistics keep the larger
/// of the two counts rather than adding them up (restoring the same backup
/// twice must not double the reading time).
///
/// Throws a [FormatException] for anything that isn't a Talistra backup.
Future<void> restoreBackup(SharedPreferences prefs, String raw) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const FormatException('Not a Talistra backup');
  }
  if (decoded is! Map<String, dynamic> || decoded['format'] != backupFormat) {
    throw const FormatException('Not a Talistra backup');
  }
  final version = decoded['version'];
  if (version is! int || version > backupVersion) {
    throw const FormatException('This backup is from a newer Talistra');
  }

  // Settings.
  final settings = decoded['settings'];
  if (settings is Map<String, dynamic>) {
    for (final entry in settings.entries) {
      if (!_settingKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      }
    }
  }

  // The library: progress onto the books that are here, the rest set aside
  // for when they are added again.
  final current = <LibraryDocument>[
    for (final raw in prefs.getStringList(_libraryKey) ?? const <String>[])
      ?_documentOf(_tryDecode(raw)),
  ];
  final byFingerprint = {for (final d in current) d.sourceFingerprint: d};
  final idMap = <String, String>{};
  final pending = <Map<String, dynamic>>[
    for (final raw in prefs.getStringList(pendingRestoreKey) ?? const [])
      ?(_tryDecode(raw) as Map<String, dynamic>?),
  ];
  final library = decoded['library'];
  if (library is List) {
    for (final entry in library) {
      final saved = _documentOf(entry);
      if (saved == null || saved.sourceFingerprint.isEmpty) continue;
      final here = byFingerprint[saved.sourceFingerprint];
      if (here == null) {
        pending
          ..removeWhere(
            (p) => p['sourceFingerprint'] == saved.sourceFingerprint,
          )
          ..add(saved.toJson());
        continue;
      }
      idMap[saved.id] = here.id;
      final index = current.indexOf(here);
      current[index] = withProgressOf(here, saved);
    }
  }
  await prefs.setStringList(_libraryKey, [
    for (final d in current) jsonEncode(d.toJson()),
  ]);
  await prefs.setStringList(pendingRestoreKey, [
    for (final p in pending) jsonEncode(p),
  ]);

  // Bookmarks and notes, onto the books' ids here.
  final annotations = AnnotationService.decode(
    prefs.getString(AnnotationService.storageKey),
  );
  final knownNotes = {for (final a in annotations) a.id};
  final savedNotes = decoded['annotations'];
  if (savedNotes is List) {
    for (final a in AnnotationService.decode(jsonEncode(savedNotes))) {
      if (knownNotes.contains(a.id)) continue;
      final id = idMap[a.documentId] ?? a.documentId;
      annotations.add(
        Annotation(
          id: a.id,
          documentId: id,
          page: a.page,
          createdAt: a.createdAt,
          quote: a.quote,
          note: a.note,
        ),
      );
    }
  }
  await prefs.setString(
    AnnotationService.storageKey,
    jsonEncode([for (final a in annotations) a.toJson()]),
  );

  // Vocabulary.
  final words = VocabularyService.decode(
    prefs.getString(VocabularyService.storageKey),
  );
  final savedWords = decoded['vocabulary'];
  if (savedWords is List) {
    for (final w in VocabularyService.decode(jsonEncode(savedWords))) {
      final known = words.any(
        (e) =>
            e.id == w.id ||
            (e.sourceLanguage == w.sourceLanguage &&
                e.word.toLowerCase() == w.word.toLowerCase()),
      );
      if (!known) words.add(w);
    }
  }
  await prefs.setString(
    VocabularyService.storageKey,
    jsonEncode([for (final w in words) w.toJson()]),
  );

  // Statistics.
  final savedStats = decoded['statistics'];
  if (savedStats is Map<String, dynamic>) {
    final here =
        _tryDecode(prefs.getString(_statisticsKey)) as Map<String, dynamic>? ??
        {};
    String remap(String id) => idMap[id] ?? id;
    Map<String, int> maxCounts(Object? a, Object? b, {bool byDocument = true}) {
      final result = <String, int>{};
      for (final source in [a, b]) {
        if (source is! Map) continue;
        for (final entry in source.entries) {
          final key = byDocument
              ? remap(entry.key as String)
              : entry.key as String;
          final value = (entry.value as num).toInt();
          if (value > (result[key] ?? 0)) result[key] = value;
        }
      }
      return result;
    }

    Map<String, List<Object>> union(
      Object? a,
      Object? b,
      String Function(String key) keyOf,
      Object Function(Object value) valueOf,
    ) {
      final result = <String, Set<Object>>{};
      for (final source in [a, b]) {
        if (source is! Map) continue;
        for (final entry in source.entries) {
          final set = result.putIfAbsent(
            keyOf(entry.key as String),
            () => <Object>{},
          );
          for (final value in entry.value as List) {
            set.add(valueOf(value as Object));
          }
        }
      }
      return {for (final e in result.entries) e.key: e.value.toList()};
    }

    await prefs.setString(
      _statisticsKey,
      jsonEncode({
        'seconds': maxCounts(here['seconds'], savedStats['seconds']),
        'readPages': union(
          here['readPages'],
          savedStats['readPages'],
          remap,
          (v) => v,
        ),
        'dailySeconds': maxCounts(
          here['dailySeconds'],
          savedStats['dailySeconds'],
          byDocument: false,
        ),
        'dailyPages': union(
          here['dailyPages'],
          savedStats['dailyPages'],
          (day) => day,
          // "documentId:page" — the document part follows the books' ids.
          (v) {
            final text = v as String;
            final colon = text.lastIndexOf(':');
            if (colon < 0) return text;
            return '${remap(text.substring(0, colon))}${text.substring(colon)}';
          },
        ),
      }),
    );
  }
}

LibraryDocument? _documentOf(Object? json) {
  if (json is! Map<String, dynamic>) return null;
  try {
    return LibraryDocument.fromJson(json);
  } catch (_) {
    return null;
  }
}

/// [here] — the book as it is in this library, its file and id — with the
/// reader's progress and choices from [saved].
LibraryDocument withProgressOf(LibraryDocument here, LibraryDocument saved) =>
    LibraryDocument(
      id: here.id,
      title: saved.title,
      filePath: here.filePath,
      addedAt: here.addedAt,
      sourceFingerprint: here.sourceFingerprint,
      pageCount: here.pageCount > 0 ? here.pageCount : saved.pageCount,
      lastPage: saved.lastPage,
      reflowMode: saved.reflowMode,
      starred: saved.starred,
      manualOrder: saved.manualOrder,
      pdfZoom: saved.pdfZoom,
      pdfScrollFraction: saved.pdfScrollFraction,
      pdfScrollFractionX: saved.pdfScrollFractionX,
      reflowFontSize: saved.reflowFontSize,
      format: here.format,
      lastOpenedAt: saved.lastOpenedAt.isAfter(here.lastOpenedAt)
          ? saved.lastOpenedAt
          : here.lastOpenedAt,
    );
