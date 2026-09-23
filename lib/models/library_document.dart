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
    this.reflowMode,
    this.starred = false,
    this.manualOrder,
    this.pdfZoom = 1.0,
    this.pdfScrollFraction = 0.0,
    this.pdfScrollFractionX = 0.0,
    this.reflowFontSize = 17,
    this.format = 'pdf',
    DateTime? lastOpenedAt,
  }) : lastOpenedAt = lastOpenedAt ?? addedAt;

  final String id;
  final String title;
  final String filePath;
  final DateTime addedAt;

  /// 'pdf' or 'txt' — which reader screen and import pipeline this
  /// document belongs to. Defaults to 'pdf' so entries saved before this
  /// field existed keep working unchanged.
  final String format;

  /// Whether this document is read as flowing text (txt, epub, fb2, rtf,
  /// docx) rather than as PDF pages.
  bool get isTextDocument =>
      const {'txt', 'epub', 'fb2', 'rtf', 'docx'}.contains(format);

  bool get isTxt => format == 'txt';
  bool get isDjvu => format == 'djvu' || format == 'djv';
  bool get isXlsx => format == 'xlsx' || format == 'xls';
  final int pageCount;
  final int lastPage;

  /// Which of the two reading views the reader last used, or null when they
  /// have never switched and the format's own default still applies.
  final bool? reflowMode;

  /// The view this document opens in. A workbook's compact, paginated reading
  /// is its default (its raw grid is a layout to look at, not to read
  /// linearly); every format that has a second view defaults to its original
  /// pages.
  bool get reflowModeOrDefault => reflowMode ?? isXlsx;
  final DateTime lastOpenedAt;

  /// Fixed-layout (PDF and DjVu) page-view zoom, how far into [lastPage]
  /// the reader had scrolled vertically (0..1), and how far they'd panned
  /// horizontally (0..1 of the pan range at that zoom) — restored exactly
  /// across a page-view<->reflow switch and across app restarts, specific
  /// to this file. A document is either a PDF or a DjVu, never both, so
  /// the two readers share these fields. Horizontal pan is one setting
  /// for the whole book, same as zoom, so it isn't reset just by moving
  /// between pages.
  final double pdfZoom;
  final double pdfScrollFraction;
  final double pdfScrollFractionX;

  /// Reflow (adaptive) mode's font size, per document.
  final double reflowFontSize;

  /// Starred documents are pinned above everything else in the library.
  final bool starred;

  /// Set the moment the reader drags this document to a new spot in the
  /// library list; null means "never manually reordered", in which case
  /// it keeps sorting by recency the way the library always has.
  final int? manualOrder;

  /// A cheap fingerprint of the original picked file (name + size), used to
  /// recognize "you already imported this PDF" without re-hashing the
  /// whole file on every import.
  final String sourceFingerprint;

  double get progress => pageCount <= 1 ? 0 : (lastPage - 1) / (pageCount - 1);

  LibraryDocument copyWith({
    String? title,
    int? pageCount,
    int? lastPage,
    bool? reflowMode,
    bool? starred,
    int? manualOrder,
    double? pdfZoom,
    double? pdfScrollFraction,
    double? pdfScrollFractionX,
    double? reflowFontSize,
    DateTime? lastOpenedAt,
  }) {
    return LibraryDocument(
      id: id,
      title: title ?? this.title,
      filePath: filePath,
      addedAt: addedAt,
      sourceFingerprint: sourceFingerprint,
      pageCount: pageCount ?? this.pageCount,
      lastPage: lastPage ?? this.lastPage,
      reflowMode: reflowMode ?? this.reflowMode,
      starred: starred ?? this.starred,
      manualOrder: manualOrder ?? this.manualOrder,
      pdfZoom: pdfZoom ?? this.pdfZoom,
      pdfScrollFraction: pdfScrollFraction ?? this.pdfScrollFraction,
      pdfScrollFractionX: pdfScrollFractionX ?? this.pdfScrollFractionX,
      reflowFontSize: reflowFontSize ?? this.reflowFontSize,
      format: format,
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
    'reflowMode': reflowMode,
    'starred': starred,
    'manualOrder': manualOrder,
    'pdfZoom': pdfZoom,
    'pdfScrollFraction': pdfScrollFraction,
    'pdfScrollFractionX': pdfScrollFractionX,
    'reflowFontSize': reflowFontSize,
    'lastOpenedAt': lastOpenedAt.toIso8601String(),
    'sourceFingerprint': sourceFingerprint,
    'format': format,
  };

  factory LibraryDocument.fromJson(Map<String, dynamic> json) {
    return LibraryDocument(
      id: json['id'] as String,
      title: json['title'] as String,
      filePath: json['filePath'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
      pageCount: json['pageCount'] as int? ?? 0,
      lastPage: json['lastPage'] as int? ?? 1,
      reflowMode: json['reflowMode'] as bool? ?? false,
      starred: json['starred'] as bool? ?? false,
      manualOrder: json['manualOrder'] as int?,
      pdfZoom: (json['pdfZoom'] as num?)?.toDouble() ?? 1.0,
      pdfScrollFraction: (json['pdfScrollFraction'] as num?)?.toDouble() ?? 0.0,
      pdfScrollFractionX:
          (json['pdfScrollFractionX'] as num?)?.toDouble() ?? 0.0,
      reflowFontSize: (json['reflowFontSize'] as num?)?.toDouble() ?? 17,
      lastOpenedAt: DateTime.tryParse(json['lastOpenedAt'] as String? ?? ''),
      sourceFingerprint: json['sourceFingerprint'] as String? ?? '',
      format: json['format'] as String? ?? 'pdf',
    );
  }
}
