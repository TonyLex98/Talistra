import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A word the reader looked up and kept, with what it said where they met it.
class VocabularyEntry {
  const VocabularyEntry({
    required this.id,
    required this.word,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.addedAt,
    required this.dueAt,
    this.translation,
    this.sentence,
    this.sentenceTranslation,
    this.box = 0,
  });

  final String id;
  final String word;
  final String? translation;

  /// The sentence the word was met in, and what it said — the context that
  /// makes a card worth reviewing.
  final String? sentence;
  final String? sentenceTranslation;

  /// BCP-47 codes of the pair it was translated between.
  final String sourceLanguage;
  final String targetLanguage;

  final DateTime addedAt;

  /// How well the reader knows it: the Leitner box it is in, 0 for a word
  /// just met (or just forgotten), up to [VocabularyService.intervals]'s end.
  final int box;

  /// When it is next worth showing again.
  final DateTime dueAt;

  VocabularyEntry copyWith({String? translation, int? box, DateTime? dueAt}) =>
      VocabularyEntry(
        id: id,
        word: word,
        translation: translation ?? this.translation,
        sentence: sentence,
        sentenceTranslation: sentenceTranslation,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        addedAt: addedAt,
        box: box ?? this.box,
        dueAt: dueAt ?? this.dueAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'word': word,
    if (translation != null) 'translation': translation,
    if (sentence != null) 'sentence': sentence,
    if (sentenceTranslation != null) 'sentenceTranslation': sentenceTranslation,
    'source': sourceLanguage,
    'target': targetLanguage,
    'addedAt': addedAt.toIso8601String(),
    'box': box,
    'dueAt': dueAt.toIso8601String(),
  };

  factory VocabularyEntry.fromJson(Map<String, dynamic> json) =>
      VocabularyEntry(
        id: json['id'] as String,
        word: json['word'] as String,
        translation: json['translation'] as String?,
        sentence: json['sentence'] as String?,
        sentenceTranslation: json['sentenceTranslation'] as String?,
        sourceLanguage: json['source'] as String,
        targetLanguage: json['target'] as String,
        addedAt: DateTime.parse(json['addedAt'] as String),
        box: json['box'] as int? ?? 0,
        dueAt: DateTime.parse(json['dueAt'] as String),
      );
}

/// The reader's own dictionary: every word they chose to keep, and when each
/// is due for review — spaced out further every time they remember it.
class VocabularyService extends ChangeNotifier {
  VocabularyService(this._prefs, this._entries, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const storageKey = 'vocabulary_v1';

  /// How long a word rests in each box before it is due again. Remembering it
  /// moves it one box on; forgetting it sends it back to the first.
  static const List<Duration> intervals = [
    Duration.zero,
    Duration(days: 1),
    Duration(days: 3),
    Duration(days: 7),
    Duration(days: 16),
    Duration(days: 35),
    Duration(days: 90),
  ];

  final SharedPreferences _prefs;
  final List<VocabularyEntry> _entries;
  final DateTime Function() _clock;

  static VocabularyService load(SharedPreferences prefs) =>
      VocabularyService(prefs, decode(prefs.getString(storageKey)));

  static List<VocabularyEntry> decode(String? raw) {
    if (raw == null) return [];
    final result = <VocabularyEntry>[];
    try {
      for (final entry in jsonDecode(raw) as List) {
        try {
          result.add(VocabularyEntry.fromJson(entry as Map<String, dynamic>));
        } catch (_) {
          // One unreadable card, not the whole dictionary.
        }
      }
    } catch (_) {
      return [];
    }
    return result;
  }

  String encode() => jsonEncode([for (final e in _entries) e.toJson()]);

  /// Newest first — the word just met is the one the reader is looking for.
  List<VocabularyEntry> get entries =>
      [..._entries]..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  /// The words due for review now, the longest-waiting first.
  List<VocabularyEntry> get due {
    final now = _clock();
    return _entries.where((e) => !e.dueAt.isAfter(now)).toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
  }

  bool contains(String word, String sourceLanguage) =>
      _indexOf(word, sourceLanguage) >= 0;

  int _indexOf(String word, String sourceLanguage) {
    final key = _normalize(word);
    return _entries.indexWhere(
      (e) => e.sourceLanguage == sourceLanguage && _normalize(e.word) == key,
    );
  }

  static String _normalize(String word) => word.trim().toLowerCase();

  /// Keeps [word]. Returns false when it was already kept — the dictionary
  /// holds one card per word and language, and the first context it was met
  /// in stays.
  Future<bool> add({
    required String word,
    required String sourceLanguage,
    required String targetLanguage,
    String? translation,
    String? sentence,
    String? sentenceTranslation,
  }) async {
    final trimmed = word.trim();
    if (trimmed.isEmpty || contains(trimmed, sourceLanguage)) return false;
    final now = _clock();
    _entries.add(
      VocabularyEntry(
        id: '${now.microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}',
        word: trimmed,
        translation: translation?.trim(),
        sentence: sentence?.trim(),
        sentenceTranslation: sentenceTranslation?.trim(),
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        addedAt: now,
        dueAt: now,
      ),
    );
    await _save();
    return true;
  }

  /// Records a review: remembered moves the word a box on and further away,
  /// forgotten starts it over.
  Future<void> review(String id, {required bool remembered}) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final entry = _entries[index];
    final box = remembered ? min(entry.box + 1, intervals.length - 1) : 0;
    final now = _clock();
    _entries[index] = entry.copyWith(
      box: box,
      // A forgotten word comes back in this same session, after the others.
      dueAt: remembered ? now.add(intervals[box]) : now,
    );
    await _save();
  }

  Future<void> updateTranslation(String id, String translation) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(translation: translation.trim());
    await _save();
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _save();
  }

  /// Adds [incoming] (from a backup), skipping words already kept.
  Future<void> merge(List<VocabularyEntry> incoming) async {
    for (final entry in incoming) {
      if (_entries.any((e) => e.id == entry.id) ||
          contains(entry.word, entry.sourceLanguage)) {
        continue;
      }
      _entries.add(entry);
    }
    await _save();
  }

  /// The dictionary as CSV that Anki (and any spreadsheet) imports as it is:
  /// word, translation, the sentence it was met in, and that sentence's
  /// translation — one card per line, no header row.
  String toCsv() {
    String field(String? value) {
      final text = (value ?? '').replaceAll('\r', '');
      return '"${text.replaceAll('"', '""')}"';
    }

    return [
      for (final e in entries)
        [
          e.word,
          e.translation,
          e.sentence,
          e.sentenceTranslation,
        ].map(field).join(','),
    ].join('\n');
  }

  Future<void> _save() async {
    notifyListeners();
    await _prefs.setString(storageKey, encode());
  }
}
