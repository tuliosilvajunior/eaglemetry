import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One glyph + value pair in an [IconValueGrid].
class IconValueEntry {
  const IconValueEntry({
    required this.icon,
    required this.value,
    this.color,
    this.semanticLabel,
  });

  final IconData icon;

  /// Pre-formatted, localized value (`44.0 kWh`).
  final String value;

  /// Glyph tint. Defaults to [AppColors.ink]; pass a series color when the
  /// entry maps to a segment of an adjacent chart.
  final Color? color;

  /// Localized meaning of the glyph for assistive technology.
  final String? semanticLabel;
}

/// Compact legend under a donut: glyphs paired with their measured value,
/// laid out in fixed columns.
///
/// The glyph is the legend key — it repeats the icon shown on the ring
/// perimeter, which is why entries can carry a series [IconValueEntry.color]
/// to match their segment.
class IconValueGrid extends StatelessWidget {
  const IconValueGrid({
    required this.entries,
    this.columns = 2,
    this.spacing = AppSpacing.x4,
    this.runSpacing = AppSpacing.x4,
    super.key,
  });

  final List<IconValueEntry> entries;
  final int columns;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < entries.length; start += columns) {
      final end = (start + columns).clamp(0, entries.length);
      final slice = entries.sublist(start, end);
      rows.add(
        Row(
          children: [
            for (var i = 0; i < columns; i++) ...[
              if (i > 0) SizedBox(width: spacing),
              Expanded(
                child: i < slice.length
                    ? _Entry(entry: slice[i])
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) SizedBox(height: runSpacing),
          rows[i],
        ],
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.entry});

  final IconValueEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Row(
      children: [
        Semantics(
          label: entry.semanticLabel,
          child: ExcludeSemantics(
            child: Icon(
              entry.icon,
              size: AppSizes.iconMd,
              color: entry.color ?? colors.ink,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.x3),
        Flexible(
          child: Text(
            entry.value,
            style: AppText.legendValue,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
