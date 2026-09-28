import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a reader left in a book: a bookmark on a page, or a note — a passage
/// they marked, with whatever they wanted to say about it.
class Annotation {
  const Annotation({
    required this.id,
    required this.documentId,
    required this.page,
    required this.createdAt,
    this.quote,
    this.note,
  });

  final String id;
  final String documentId;

  /// 1-based, in the reader's own page numbers.
  final int page;
  final DateTime createdAt;

  /// The passage a note was made on; null for a bookmark.
  final String? quote;

  /// What the reader wrote; null or empty when they only marked the passage.
  final String? note;

  bool get isBookmark => quote == null;

  Annotation copyWith({String? note}) => Annotation(
    id: id,
    documentId: documentId,
    page: page,
    createdAt: createdAt,
    quote: quote,
    note: note ?? this.note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'page': page,
    'createdAt': createdAt.toIso8601String(),
    if (quote != null) 'quote': quote,
    if (note != null) 'note': note,
  };

  factory Annotation.fromJson(Map<String, dynamic> json) => Annotation(
    id: json['id'] as String,
    documentId: json['documentId'] as String,
    page: json['page'] as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
    quote: json['quote'] as String?,
    note: json['note'] as String?,
  );
}

/// Keeps every book's bookmarks and notes, in SharedPreferences next to the
/// library they belong to.
class AnnotationService extends ChangeNotifier {
  AnnotationService(this._prefs, this._annotations);

  static const storageKey = 'annotations_v1';

  final SharedPreferences _prefs;
  final List<Annotation> _annotations;

  static AnnotationService load(SharedPreferences prefs) =>
      AnnotationService(prefs, decode(prefs.getString(storageKey)));

  /// The annotations in [raw] (as [encode] wrote them), skipping any entry
  /// that doesn't read rather than losing the rest.
  static List<Annotation> decode(String? raw) {
    if (raw == null) return [];
    final result = <Annotation>[];
    try {
      for (final entry in jsonDecode(raw) as List) {
        try {
          result.add(Annotation.fromJson(entry as Map<String, dynamic>));
        } catch (_) {
          // One broken entry is one lost note, not all of them.
        }
      }
    } catch (_) {
      return [];
    }
    return result;
  }

  String encode() => jsonEncode([for (final a in _annotations) a.toJson()]);

  /// A book's bookmarks and notes, in page order.
  List<Annotation> forDocument(String documentId) =>
      _annotations.where((a) => a.documentId == documentId).toList()
        ..sort((a, b) {
          final byPage = a.page.compareTo(b.page);
          return byPage != 0 ? byPage : a.createdAt.compareTo(b.createdAt);
        });

  bool isBookmarked(String documentId, int page) => _annotations.any(
    (a) => a.documentId == documentId && a.page == page && a.isBookmark,
  );

  /// Puts a bookmark on [page], or takes it off if there was one. Returns
  /// whether the page is bookmarked now.
  Future<bool> toggleBookmark(String documentId, int page) async {
    final existing = _annotations.indexWhere(
      (a) => a.documentId == documentId && a.page == page && a.isBookmark,
    );
    if (existing >= 0) {
      _annotations.removeAt(existing);
    } else {
      _annotations.add(
        Annotation(
          id: _newId(),
          documentId: documentId,
          page: page,
          createdAt: DateTime.now(),
        ),
      );
    }
    await _save();
    return existing < 0;
  }

  Future<Annotation> addNote({
    required String documentId,
    required int page,
    required String quote,
    String? note,
  }) async {
    final annotation = Annotation(
      id: _newId(),
      documentId: documentId,
      page: page,
      createdAt: DateTime.now(),
      quote: quote,
      note: note == null || note.trim().isEmpty ? null : note.trim(),
    );
    _annotations.add(annotation);
    await _save();
    return annotation;
  }

  Future<void> updateNote(String id, String note) async {
    final index = _annotations.indexWhere((a) => a.id == id);
    if (index < 0) return;
    _annotations[index] = _annotations[index].copyWith(note: note.trim());
    await _save();
  }

  Future<void> remove(String id) async {
    _annotations.removeWhere((a) => a.id == id);
    await _save();
  }

  /// Forgets everything left in a book the reader removed from the library.
  Future<void> removeDocument(String documentId) async {
    final before = _annotations.length;
    _annotations.removeWhere((a) => a.documentId == documentId);
    if (_annotations.length != before) await _save();
  }

  /// Adds [incoming] (from a backup), skipping any already here.
  Future<void> merge(List<Annotation> incoming) async {
    final known = {for (final a in _annotations) a.id};
    _annotations.addAll(incoming.where((a) => !known.contains(a.id)));
    await _save();
  }

  /// Moves everything left in [from] onto [to] — a restored backup knows a
  /// book by its old library id.
  Future<void> reassign(String from, String to) async {
    var changed = false;
    for (var i = 0; i < _annotations.length; i++) {
      final a = _annotations[i];
      if (a.documentId != from) continue;
      _annotations[i] = Annotation(
        id: a.id,
        documentId: to,
        page: a.page,
        createdAt: a.createdAt,
        quote: a.quote,
        note: a.note,
      );
      changed = true;
    }
    if (changed) await _save();
  }

  Future<void> _save() async {
    notifyListeners();
    await _prefs.setString(storageKey, encode());
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';
}
