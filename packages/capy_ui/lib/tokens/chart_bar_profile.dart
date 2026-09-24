import 'package:telemetry_core/telemetry_core.dart';

/// The slot grid of a bar chart: how wide a bar is, and how much clear space
/// sits between two bars.
///
/// The two measurements always travel together, so they are one value. A chart
/// that takes only the width would draw at a pitch the bucket math did not
/// assume, and the last bar would fall outside the plot.
///
/// This class is the only home of the pitch. `energyChartBarCapacity` in
/// `telemetry_core` takes [pitch] and [gap] as arguments, so the domain package
/// holds no pixel and does not restate the sum. See ADR 0011.
final class ChartBarProfile {
  const ChartBarProfile({required this.width, required this.gap})
    : assert(width > 0),
      assert(gap >= 0);

  /// Bar width in logical pixels. Bars are pill-capped, so the cap radius is
  /// half of this.
  final double width;

  /// Clear space between two neighbouring bars.
  final double gap;

  /// Distance from one bar centre to the next.
  double get pitch => width + gap;

  /// Width taken by [slotCount] bars, trailing gap excluded.
  double contentWidth(int slotCount) =>
      slotCount <= 0 ? 0 : slotCount * width + (slotCount - 1) * gap;

  @override
  bool operator ==(Object other) =>
      other is ChartBarProfile && other.width == width && other.gap == gap;

  @override
  int get hashCode => Object.hash(width, gap);

  @override
  String toString() => 'ChartBarProfile(width: $width, gap: $gap)';
}

/// How the design system asks the domain for a bar count.
extension ChartBarProfileCapacity on ChartBarProfile {
  /// How many bars of this profile fit [plotWidth] logical pixels.
  int slotsIn(double plotWidth) =>
      energyChartBarCapacity(plotWidth, pitch: pitch, gap: gap);
}
