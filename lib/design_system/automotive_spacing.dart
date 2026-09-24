import 'package:flutter/widgets.dart';

abstract final class AutomotiveSpacing {
  static const unit = 8.0;
  static const railWidth = 96.0;
  static const gutter = 24.0;
  static const marginScreen = 32.0;
  static const touchTargetMin = 64.0;

  static const x0 = 0.0;
  static const x0_5 = 4.0;
  static const x1 = 8.0;
  static const x1_5 = 12.0;
  static const x2 = 16.0;
  static const x3 = 24.0;
  static const x4 = 32.0;
  static const x5 = 40.0;
  static const x6 = 48.0;
  static const x8 = 64.0;

  static const screenPadding = EdgeInsets.all(marginScreen);
  static const panelPadding = EdgeInsets.all(x3);
  static const compactPanelPadding = EdgeInsets.all(x2);
}

abstract final class AutomotiveRadii {
  static const sm = 2.0;
  static const base = 4.0;
  static const md = 6.0;
  static const lg = 8.0;
  static const xl = 12.0;
  static const full = 9999.0;

  static BorderRadius get smRadius => BorderRadius.circular(sm);
  static BorderRadius get baseRadius => BorderRadius.circular(base);
  static BorderRadius get mdRadius => BorderRadius.circular(md);
  static BorderRadius get lgRadius => BorderRadius.circular(lg);
  static BorderRadius get xlRadius => BorderRadius.circular(xl);
  static BorderRadius get fullRadius => BorderRadius.circular(full);
}

abstract final class AutomotiveDimensions {
  static const navRailWidth = AutomotiveSpacing.railWidth;
  static const navIconSize = 32.0;
  static const activeRailMarkerWidth = 4.0;
  static const progressHeight = 12.0;
  static const minTouchTarget = AutomotiveSpacing.touchTargetMin;
  static const panelBorderWidth = 1.0;
  static const activeBorderWidth = 2.0;
}
