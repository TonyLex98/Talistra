import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/utils/reflow_paginator.dart';

List<ReflowSubPage> _paginate(
  List<ReflowBlock> blocks, {
  Size Function(ReflowBlock)? imageSizeFor,
}) => paginateReflowBlocks(
  blocks: blocks,
  width: 300,
  height: 500,
  fontSize: 16,
  styleFor: (_) => const TextStyle(fontSize: 16, height: 1.5),
  blockSpacing: 16,
  imageSpacing: 20,
  textScaler: TextScaler.noScaling,
  imageSizeFor: imageSizeFor,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a figure that turned out blank takes no room', () {
    final pages = _paginate([
      const ReflowBlock.paragraph('Before.'),
      ReflowBlock.image(Rect.zero),
      const ReflowBlock.paragraph('After.'),
    ]);
    expect(pages.single.map((s) => s.blockIndex), [0, 2]);
  });

  test('a figure is given the room its own size asks for', () {
    // Two figures of 240 px would not share a 500 px page; two of 180 do.
    List<ReflowSubPage> withHeight(double height) => _paginate([
      ReflowBlock.image(Rect.fromLTWH(0, 0, 100, 100)),
      ReflowBlock.image(Rect.fromLTWH(0, 0, 100, 100)),
    ], imageSizeFor: (_) => Size(100, height));
    expect(withHeight(180), hasLength(1));
    expect(withHeight(240), hasLength(2));
  });
}
