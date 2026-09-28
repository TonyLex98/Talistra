import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../utils/reflow_builder.dart';

/// What reads the text out: the platform's speech engine in the app, a
/// stand-in in tests.
abstract class SpeechEngine {
  /// Switches to [languageCode] (BCP-47); false when the device has no voice
  /// for it.
  Future<bool> setLanguage(String languageCode);

  /// Speaks [text] and completes once it has been spoken — or cut off by
  /// [stop].
  Future<void> speak(String text);

  Future<void> stop();
}

/// [SpeechEngine] over the platform's own text-to-speech.
class DeviceSpeechEngine implements SpeechEngine {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;

  @override
  Future<bool> setLanguage(String languageCode) async {
    if (!_configured) {
      // speak() has to wait for the sentence to end, or the next one would
      // cut it off the moment it started.
      await _tts.awaitSpeakCompletion(true);
      _configured = true;
    }
    final available = await _tts.isLanguageAvailable(languageCode);
    if (available != true) return false;
    await _tts.setLanguage(languageCode);
    return true;
  }

  @override
  Future<void> speak(String text) => _tts.speak(text);

  @override
  Future<void> stop() => _tts.stop();
}

/// One sentence of a page, where it lies in its block.
typedef SpokenSentence = ({int blockIndex, int start, int end, String text});

final _sentencePattern = RegExp(
  r'[^.!?…\n]+(?:[.!?…]+["»”’)\]]*|\n|$)',
  unicode: true,
);

/// A page's text as the sentences it is read out in, each pointing back at
/// the characters it came from — which is what lets the reader follow the
/// voice with a highlight.
List<SpokenSentence> sentencesOf(List<ReflowBlock> blocks) {
  final sentences = <SpokenSentence>[];
  for (var i = 0; i < blocks.length; i++) {
    final text = blocks[i].text;
    if (text.trim().isEmpty) continue;
    for (final match in _sentencePattern.allMatches(text)) {
      var start = match.start;
      var end = match.end;
      while (start < end && _isSpace(text.codeUnitAt(start))) {
        start++;
      }
      while (end > start && _isSpace(text.codeUnitAt(end - 1))) {
        end--;
      }
      final sentence = text.substring(start, end);
      // A run of dashes or dots is nothing a voice can say.
      if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(sentence)) continue;
      sentences.add((blockIndex: i, start: start, end: end, text: sentence));
    }
  }
  return sentences;
}

bool _isSpace(int unit) => unit == 0x20 || unit == 0x0A || unit == 0x09;

/// Reads a book out loud from a page on, one sentence at a time, turning the
/// pages itself and telling the reader where it is so the page can follow.
class ReadAloud extends ChangeNotifier {
  ReadAloud(this._engine);

  final SpeechEngine _engine;

  /// Bumped by every [start] and [stop], so a reading that was stopped (or
  /// replaced by a new one) notices and gives up at its next sentence.
  int _generation = 0;
  bool _reading = false;

  bool get isReading => _reading;

  /// Starts reading [languageCode] text from page [fromPage] (1-based) to the
  /// last of [pageCount], calling [onSentence] as each sentence begins.
  /// Returns false, without reading, when the device has no voice for the
  /// language.
  Future<bool> start({
    required String languageCode,
    required int fromPage,
    required int pageCount,
    required List<ReflowBlock> Function(int page) blocksOf,
    required void Function(int page, SpokenSentence sentence) onSentence,
    VoidCallback? onFinished,
  }) async {
    await stop();
    final generation = ++_generation;
    if (!await _engine.setLanguage(languageCode)) return false;
    if (generation != _generation) return true;
    _reading = true;
    notifyListeners();
    unawaited(
      _run(generation, fromPage, pageCount, blocksOf, onSentence, onFinished),
    );
    return true;
  }

  Future<void> _run(
    int generation,
    int fromPage,
    int pageCount,
    List<ReflowBlock> Function(int page) blocksOf,
    void Function(int page, SpokenSentence sentence) onSentence,
    VoidCallback? onFinished,
  ) async {
    try {
      for (var page = fromPage; page <= pageCount; page++) {
        for (final sentence in sentencesOf(blocksOf(page))) {
          if (generation != _generation) return;
          onSentence(page, sentence);
          await _engine.speak(sentence.text);
        }
      }
    } catch (_) {
      // The engine went away mid-book: stop quietly, the reader can start
      // again.
    }
    if (generation != _generation) return;
    _reading = false;
    notifyListeners();
    onFinished?.call();
  }

  Future<void> stop() async {
    _generation++;
    if (!_reading) return;
    _reading = false;
    notifyListeners();
    await _engine.stop();
  }

  @override
  void dispose() {
    _generation++;
    if (_reading) unawaited(_engine.stop());
    super.dispose();
  }
}
