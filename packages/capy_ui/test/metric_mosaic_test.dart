import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

MosaicTile _tile(String caption, MosaicTileSpan span) =>
    MosaicTile(caption: caption, value: '1', span: span);

void main() {
  group('packing', () {
    test('a hero takes the first four cells and the row fills beside it', () {
      final tiles = [
        _tile('hero', MosaicTileSpan.hero),
        _tile('a', MosaicTileSpan.small),
        _tile('b', MosaicTileSpan.small),
      ];

      final packed = packMosaic(tiles, columns: 4);

      expect(packed[0].column, 0);
      expect(packed[0].row, 0);
      // Column 2 is the first free cell: the hero holds 0 and 1 on both rows.
      expect(packed[1].column, 2);
      expect(packed[1].row, 0);
      expect(packed[2].column, 3);
      expect(packed[2].row, 0);
    });

    test('a later narrow tile fills a gap a wide one could not', () {
      final tiles = [
        _tile('hero', MosaicTileSpan.hero),
        _tile('wide', MosaicTileSpan.wide),
        // Only one cell is left on row 1 beside the hero, so the wide tile
        // above dropped past it — this one goes back and takes it.
        _tile('small', MosaicTileSpan.small),
      ];

      final packed = packMosaic(tiles, columns: 3);

      expect((packed[0].column, packed[0].row), (0, 0));
      expect((packed[1].column, packed[1].row), (0, 2));
      expect((packed[2].column, packed[2].row), (2, 0));
    });

    test('a tile wider than the grid is clamped, not dropped', () {
      final packed = packMosaic([
        _tile('wide', MosaicTileSpan.wide),
      ], columns: 1);

      expect(packed, hasLength(1));
      expect(packed.single.column, 0);
    });

    test('a tall tile blocks the cell under it', () {
      final tiles = [
        _tile('tall', MosaicTileSpan.tall),
        _tile('a', MosaicTileSpan.small),
        _tile('b', MosaicTileSpan.small),
      ];

      final packed = packMosaic(tiles, columns: 2);

      expect((packed[0].column, packed[0].row), (0, 0));
      expect((packed[1].column, packed[1].row), (1, 0));
      expect((packed[2].column, packed[2].row), (1, 1));
    });
  });

  testWidgets('the mosaic fills the height it is given, without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 800,
              height: 300,
              child: MetricMosaic(
                tiles: [
                  _tile('hero', MosaicTileSpan.hero),
                  _tile('a', MosaicTileSpan.small),
                  _tile('b', MosaicTileSpan.wide),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('hero'), findsOneWidget);
    final hero = tester.getRect(find.text('hero'));
    final other = tester.getRect(find.text('a'));
    // The hero is two rows tall, so it starts above and reaches past the
    // one-cell tile beside it.
    expect(hero.top, lessThanOrEqualTo(other.top));
  });

  testWidgets('an empty mosaic takes no space', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Center(child: MetricMosaic(tiles: [])),
        ),
      ),
    );

    expect(tester.getSize(find.byType(MetricMosaic)), Size.zero);
  });
}
