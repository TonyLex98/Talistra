import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/services/read_aloud.dart';
import 'package:transreade/utils/reflow_builder.dart';

/// Speaks nothing: records what it was asked to say, and says each sentence
/// only when the test lets it finish.
class _FakeEngine implements SpeechEngine {
  _FakeEngine({this.voices = const {'ru'}});

  final Set<String> voices;
  final List<String> spoken = [];
  Completer<void>? _current;
  bool stopped = false;

  @override
  Future<bool> setLanguage(String languageCode) async =>
      voices.contains(languageCode);

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    _current = Completer<void>();
    return _current!.future;
  }

  void finishSentence() => _current?.complete();

  @override
  Future<void> stop() async {
    stopped = true;
    if (_current != null && !_current!.isCompleted) _current!.complete();
  }
}

ReflowBlock _p(String text) => ReflowBlock.paragraph(text);

void main() {
  test('a page is read sentence by sentence, pointing at each', () {
    final sentences = sentencesOf([
      _p('Он пришёл. «Кто там?» — спросила она… Никто!'),
      ReflowBlock.paragraph('', isDivider: true),
      _p('Мороз и солнце;\nдень чудесный'),
      _p('* * *'),
    ]);
    expect(sentences.map((s) => s.text), [
      'Он пришёл.',
      '«Кто там?»',
      '— спросила она…',
      'Никто!',
      'Мороз и солнце;',
      'день чудесный',
    ]);
    final second = sentences[1];
    expect(second.blockIndex, 0);
    expect(
      'Он пришёл. «Кто там?» — спросила она… Никто!'.substring(
        second.start,
        second.end,
      ),
      '«Кто там?»',
    );
    expect(sentences.last.blockIndex, 2);
  });

  test('reading follows the book across pages and stops at its end', () async {
    final engine = _FakeEngine();
    final readAloud = ReadAloud(engine);
    final heard = <(int, String)>[];
    var finished = false;
    final pages = [
      [_p('Первая. Вторая.')],
      [_p('Третья.')],
    ];
    expect(
      await readAloud.start(
        languageCode: 'ru',
        fromPage: 1,
        pageCount: 2,
        blocksOf: (page) => pages[page - 1],
        onSentence: (page, s) => heard.add((page, s.text)),
        onFinished: () => finished = true,
      ),
      isTrue,
    );
    expect(readAloud.isReading, isTrue);
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
      engine.finishSentence();
    }
    await Future<void>.delayed(Duration.zero);
    expect(heard, [(1, 'Первая.'), (1, 'Вторая.'), (2, 'Третья.')]);
    expect(finished, isTrue);
    expect(readAloud.isReading, isFalse);
  });

  test('stopping cuts the sentence off and reads no further', () async {
    final engine = _FakeEngine();
    final readAloud = ReadAloud(engine);
    await readAloud.start(
      languageCode: 'ru',
      fromPage: 1,
      pageCount: 1,
      blocksOf: (_) => [_p('Раз. Два. Три.')],
      onSentence: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);
    await readAloud.stop();
    await Future<void>.delayed(Duration.zero);
    expect(engine.stopped, isTrue);
    expect(engine.spoken, ['Раз.']);
    expect(readAloud.isReading, isFalse);
  });

  test('a language without a voice is refused up front', () async {
    final readAloud = ReadAloud(_FakeEngine(voices: const {}));
    expect(
      await readAloud.start(
        languageCode: 'ru',
        fromPage: 1,
        pageCount: 1,
        blocksOf: (_) => [_p('Текст.')],
        onSentence: (_, _) {},
      ),
      isFalse,
    );
    expect(readAloud.isReading, isFalse);
  });
}
