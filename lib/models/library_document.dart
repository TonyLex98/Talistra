/// A PDF that has been imported into the app's library.
class LibraryDocument {
  LibraryDocument({
    required this.id,
    required this.title,
    required this.filePath,
    required this.addedAt,
    required this.sourceFingerprint,
    this.pageCount = 0,
    this.lastPage = 1,
    DateTime? lastOpenedAt,
  }) : lastOpenedAt = lastOpenedAt ?? addedAt;

  final String id;
  final String title;
  final String filePath;
  final DateTime addedAt;
  final int pageCount;
  final int lastPage;
  final DateTime lastOpenedAt;

  /// A cheap fingerprint of the original picked file (name + size), used to
  /// recognize "you already imported this PDF" without re-hashing the
  /// whole file on every import.
  final String sourceFingerprint;

  double get progress => pageCount <= 1 ? 0 : (lastPage - 1) / (pageCount - 1);

  LibraryDocument copyWith({
    int? pageCount,
    int? lastPage,
    DateTime? lastOpenedAt,
  }) {
    return LibraryDocument(
      id: id,
      title: title,
      filePath: filePath,
      addedAt: addedAt,
      sourceFingerprint: sourceFingerprint,
      pageCount: pageCount ?? this.pageCount,
      lastPage: lastPage ?? this.lastPage,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'filePath': filePath,
    'addedAt': addedAt.toIso8601String(),
    'pageCount': pageCount,
    'lastPage': lastPage,
    'lastOpenedAt': lastOpenedAt.toIso8601String(),
    'sourceFingerprint': sourceFingerprint,
  };

  factory LibraryDocument.fromJson(Map<String, dynamic> json) {
    return LibraryDocument(
      id: json['id'] as String,
      title: json['title'] as String,
      filePath: json['filePath'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
      pageCount: json['pageCount'] as int? ?? 0,
      lastPage: json['lastPage'] as int? ?? 1,
      lastOpenedAt: DateTime.tryParse(json['lastOpenedAt'] as String? ?? ''),
      sourceFingerprint: json['sourceFingerprint'] as String? ?? '',
    );
  }
}
