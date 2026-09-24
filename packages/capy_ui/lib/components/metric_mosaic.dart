import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'metric_value.dart';

/// How many cells of the mosaic grid a tile occupies.
///
/// Four shapes, and deliberately no more: a mosaic whose tiles can be any size
/// stops reading as a grid and starts reading as a collection of boxes. One
/// reading gets [MosaicTileSpan.hero]; the rest compete for what is left.
enum MosaicTileSpan {
  /// One cell. The default, and what most readings are.
  small(columns: 1, rows: 1),

  /// Two cells side by side. For a reading whose value is long — a range, a
  /// pair of times — rather than for one that is more important.
  wide(columns: 2, rows: 1),

  /// Two cells stacked.
  tall(columns: 1, rows: 2),

  /// Four cells in a square. The headline of the mosaic.
  hero(columns: 2, rows: 2);

  const MosaicTileSpan({required this.columns, required this.rows});

  final int columns;
  final int rows;
}

/// One reading in a [MetricMosaic].
///
/// Everything here is already localized and already formatted — the mosaic
/// does no formatting and holds no strings of its own, so it can carry a drive,
/// a charge, or anything else with readings to show.
@immutable
class MosaicTile {
  const MosaicTile({
    required this.caption,
    required this.value,
    this.unit,
    this.icon,
    this.accent,
    this.span = MosaicTileSpan.small,
    this.onPressed,
    this.editLabel,
    this.actionIcon = Icons.edit,
  }) : assert(onPressed == null || editLabel != null);

  /// What the reading is, in the caller's words.
  final String caption;

  /// The reading itself, pre-formatted, and already `--` where the car
  /// reported nothing.
  final String value;

  /// Localized unit suffix, kept as its own run beside the numeral.
  final String? unit;

  final IconData? icon;

  /// Semantic color for [icon] only.
  ///
  /// Per `DESIGN.md`: the semantic goes on the icon, never on the tile surface
  /// or the label. A tile whose whole background carries a series color would
  /// read as a selection, which is the one thing color must not say here.
  final Color? accent;

  final MosaicTileSpan span;

  /// Opens the editor behind this reading. Null keeps the tile a reading.
  ///
  /// It is given the cell's own [BuildContext], so an anchored editor points at
  /// the tile the reader pressed instead of at the wall around it. The mosaic
  /// packs its cells itself, so the caller has no other way to name that box.
  ///
  /// A pressable tile grows a pencil, for the same reason `StatColumn` does: it
  /// otherwise looks exactly like the readings beside it, and a reader must not
  /// have to find out by tapping.
  final void Function(BuildContext cellContext)? onPressed;

  /// Localized action name for a screen reader. Required with [onPressed],
  /// because the caption says what the number is, not what a tap does.
  final String? editLabel;

  /// The mark a pressable tile carries. A pencil says the tap writes a value;
  /// a tile whose tap only changes how the same value is printed must not make
  /// that claim, so it gives its own icon.
  final IconData actionIcon;
}

/// A Metro-style mosaic of readings: squares and rectangles packed into a
/// fixed-column grid, each showing one value at a glance.
///
/// The layout is a first-fit pack over an occupancy grid, filling left to right
/// and top to bottom, so a tile that does not fit the current row's remaining
/// space drops to the next one and a later, narrower tile slots into the gap it
/// left. That is what gives the wall its irregular, interlocking look without
/// the caller placing anything by hand — reorder [tiles] and the mosaic
/// repacks.
///
/// It **fills the box it is given** rather than asking for a height: the cell
/// height is whatever the available height divided by the packed row count
/// comes to. This is a card's whole content on a stage that does not scroll, so
/// a mosaic that wanted more room than the card has would have nowhere to put
/// it. Give it fewer tiles instead — `DESIGN.md`'s rule that a cramped layout
/// loses content rather than padding.
class MetricMosaic extends StatelessWidget {
  const MetricMosaic({
    required this.tiles,
    this.columns = 4,
    this.gutter = AppSpacing.x2,
    super.key,
  }) : assert(columns > 0);

  final List<MosaicTile> tiles;

  /// Cells across. Every tile spans one or two of these.
  final int columns;

  /// Space between cells. Tighter than `gridGutter`, because these are
  /// controls inside one card rather than cards on a canvas.
  final double gutter;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    final placements = packMosaic(tiles, columns: columns);
    final rowCount = placements.fold<int>(
      0,
      (rows, placement) => rows > placement.bottom ? rows : placement.bottom,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth =
            (constraints.maxWidth - gutter * (columns - 1)) / columns;
        // A mosaic in an unbounded box has no height to divide, so it falls
        // back to square cells rather than laying out at infinity.
        final bounded = constraints.hasBoundedHeight;
        final cellHeight = bounded
            ? (constraints.maxHeight - gutter * (rowCount - 1)) / rowCount
            : cellWidth;
        // Every child is `Positioned`, so the stack takes no size from them.
        // In an unbounded box it would then lay out at infinity, which is the
        // fallback above failing to arrive: the cell height was decided and
        // the box was still not told. A scrolling parent — the phone's session
        // detail — is exactly that box.
        final stackHeight = bounded
            ? null
            : cellHeight * rowCount + gutter * (rowCount - 1);
        return SizedBox(
          height: stackHeight,
          child: Stack(
            children: [
              for (final placement in placements)
                Positioned(
                  left: placement.column * (cellWidth + gutter),
                  top: placement.row * (cellHeight + gutter),
                  width:
                      placement.tile.span.columns * cellWidth +
                      gutter * (placement.tile.span.columns - 1),
                  height:
                      placement.tile.span.rows * cellHeight +
                      gutter * (placement.tile.span.rows - 1),
                  child: _MosaicCell(tile: placement.tile),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Where one tile landed in the grid.
@immutable
class MosaicPlacement {
  const MosaicPlacement({
    required this.tile,
    required this.column,
    required this.row,
  });

  final MosaicTile tile;
  final int column;
  final int row;

  int get bottom => row + tile.span.rows;

  @override
  bool operator ==(Object other) =>
      other is MosaicPlacement &&
      other.tile == tile &&
      other.column == column &&
      other.row == row;

  @override
  int get hashCode => Object.hash(tile, column, row);
}

/// Packs [tiles] into [columns], first fit, in the order given.
///
/// Exposed for testing: the packing is the part of this component with a right
/// and a wrong answer, and it is far easier to assert on placements than on
/// pixels. A tile wider than the grid is clamped to the full width rather than
/// dropped, since losing a reading silently is worse than one odd row.
List<MosaicPlacement> packMosaic(
  List<MosaicTile> tiles, {
  required int columns,
}) {
  final occupied = <List<bool>>[];
  final placements = <MosaicPlacement>[];

  bool free(int row, int column, int width, int height) {
    for (var r = row; r < row + height; r++) {
      while (occupied.length <= r) {
        occupied.add(List<bool>.filled(columns, false));
      }
      for (var c = column; c < column + width; c++) {
        if (occupied[r][c]) return false;
      }
    }
    return true;
  }

  for (final tile in tiles) {
    final width = tile.span.columns > columns ? columns : tile.span.columns;
    final height = tile.span.rows;
    var placed = false;
    for (var row = 0; !placed; row++) {
      for (var column = 0; column + width <= columns; column++) {
        if (!free(row, column, width, height)) continue;
        for (var r = row; r < row + height; r++) {
          for (var c = column; c < column + width; c++) {
            occupied[r][c] = true;
          }
        }
        placements.add(MosaicPlacement(tile: tile, column: column, row: row));
        placed = true;
        break;
      }
    }
  }
  return placements;
}

/// One tile's surface: a control step inside the card that holds the mosaic.
class _MosaicCell extends StatelessWidget {
  const _MosaicCell({required this.tile});

  final MosaicTile tile;

  /// The numeral shrinks with the tile, so a wall of one-cell tiles does not
  /// have to be read at hero size.
  MetricSize _sizeFor(BoxConstraints constraints) {
    if (tile.span == MosaicTileSpan.hero) return MetricSize.xl;
    if (constraints.maxWidth < 160) return MetricSize.sm;
    return MetricSize.md;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final onPressed = tile.onPressed;
    if (onPressed == null) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.x4),
        decoration: BoxDecoration(
          color: colors.control,
          borderRadius: AppRadii.mdRadius,
        ),
        child: _content(context),
      );
    }
    // The cell's own context is the anchor, so the editor opens beside this
    // tile. `Builder` is what gives the callback a context under the ink,
    // rather than the one the whole mosaic was built in.
    return Semantics(
      button: true,
      label: tile.editLabel,
      child: Material(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
        child: Builder(
          builder: (cellContext) => InkWell(
            onTap: () => onPressed(cellContext),
            borderRadius: AppRadii.mdRadius,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.x4),
              child: _content(cellContext),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final icon = tile.icon;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: AppSizes.iconSm,
                    color: tile.accent ?? colors.inkSubtle,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                ],
                Expanded(
                  child: Text(
                    tile.caption,
                    style: AppText.label.copyWith(color: colors.inkSubtle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (tile.onPressed != null) ...[
                  const SizedBox(width: AppSpacing.x2),
                  Icon(
                    tile.actionIcon,
                    size: AppSizes.iconSm,
                    color: colors.inkSubtle,
                  ),
                ],
              ],
            ),
            // The value is the tile's reason to exist, so it takes whatever
            // the caption leaves and shrinks to fit rather than wrapping into
            // a second line the tile has no room for.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: MetricValue(
                  value: tile.value,
                  unit: tile.unit,
                  size: _sizeFor(constraints),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
