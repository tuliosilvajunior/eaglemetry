import 'package:flutter/material.dart';

abstract final class AutomotiveFonts {
  static const ui = 'Inter';
  static const mono = 'JetBrains Mono';
}

abstract final class AutomotiveTextStyles {
  static const metricDisplay = TextStyle(
    fontFamily: AutomotiveFonts.mono,
    fontSize: 64,
    fontWeight: FontWeight.w700,
    height: 1,
    letterSpacing: 0,
  );

  static const metricDisplayMobile = TextStyle(
    fontFamily: AutomotiveFonts.mono,
    fontSize: 48,
    fontWeight: FontWeight.w700,
    height: 1,
  );

  static const headlineLg = TextStyle(
    fontFamily: AutomotiveFonts.ui,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    height: 40 / 32,
  );

  static const headlineMd = TextStyle(
    fontFamily: AutomotiveFonts.ui,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 32 / 24,
  );

  static const bodyLg = TextStyle(
    fontFamily: AutomotiveFonts.ui,
    fontSize: 18,
    fontWeight: FontWeight.w400,
    height: 28 / 18,
  );

  static const bodyMd = TextStyle(
    fontFamily: AutomotiveFonts.ui,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 24 / 16,
  );

  static const labelCaps = TextStyle(
    fontFamily: AutomotiveFonts.ui,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    height: 16 / 12,
    letterSpacing: 0.6,
  );

  static const unitLabel = TextStyle(
    fontFamily: AutomotiveFonts.mono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 20 / 14,
  );
}

@immutable
class AutomotiveTypography extends ThemeExtension<AutomotiveTypography> {
  const AutomotiveTypography({
    required this.metricDisplay,
    required this.metricDisplayMobile,
    required this.headlineLg,
    required this.headlineMd,
    required this.bodyLg,
    required this.bodyMd,
    required this.labelCaps,
    required this.unitLabel,
  });

  factory AutomotiveTypography.standard() {
    return const AutomotiveTypography(
      metricDisplay: AutomotiveTextStyles.metricDisplay,
      metricDisplayMobile: AutomotiveTextStyles.metricDisplayMobile,
      headlineLg: AutomotiveTextStyles.headlineLg,
      headlineMd: AutomotiveTextStyles.headlineMd,
      bodyLg: AutomotiveTextStyles.bodyLg,
      bodyMd: AutomotiveTextStyles.bodyMd,
      labelCaps: AutomotiveTextStyles.labelCaps,
      unitLabel: AutomotiveTextStyles.unitLabel,
    );
  }

  final TextStyle metricDisplay;
  final TextStyle metricDisplayMobile;
  final TextStyle headlineLg;
  final TextStyle headlineMd;
  final TextStyle bodyLg;
  final TextStyle bodyMd;
  final TextStyle labelCaps;
  final TextStyle unitLabel;

  @override
  AutomotiveTypography copyWith({
    TextStyle? metricDisplay,
    TextStyle? metricDisplayMobile,
    TextStyle? headlineLg,
    TextStyle? headlineMd,
    TextStyle? bodyLg,
    TextStyle? bodyMd,
    TextStyle? labelCaps,
    TextStyle? unitLabel,
  }) {
    return AutomotiveTypography(
      metricDisplay: metricDisplay ?? this.metricDisplay,
      metricDisplayMobile: metricDisplayMobile ?? this.metricDisplayMobile,
      headlineLg: headlineLg ?? this.headlineLg,
      headlineMd: headlineMd ?? this.headlineMd,
      bodyLg: bodyLg ?? this.bodyLg,
      bodyMd: bodyMd ?? this.bodyMd,
      labelCaps: labelCaps ?? this.labelCaps,
      unitLabel: unitLabel ?? this.unitLabel,
    );
  }

  @override
  AutomotiveTypography lerp(
    covariant ThemeExtension<AutomotiveTypography>? other,
    double t,
  ) {
    if (other is! AutomotiveTypography) return this;
    return AutomotiveTypography(
      metricDisplay: TextStyle.lerp(metricDisplay, other.metricDisplay, t)!,
      metricDisplayMobile: TextStyle.lerp(
        metricDisplayMobile,
        other.metricDisplayMobile,
        t,
      )!,
      headlineLg: TextStyle.lerp(headlineLg, other.headlineLg, t)!,
      headlineMd: TextStyle.lerp(headlineMd, other.headlineMd, t)!,
      bodyLg: TextStyle.lerp(bodyLg, other.bodyLg, t)!,
      bodyMd: TextStyle.lerp(bodyMd, other.bodyMd, t)!,
      labelCaps: TextStyle.lerp(labelCaps, other.labelCaps, t)!,
      unitLabel: TextStyle.lerp(unitLabel, other.unitLabel, t)!,
    );
  }
}

extension AutomotiveTypographyTheme on BuildContext {
  AutomotiveTypography get automotiveTypography {
    return Theme.of(this).extension<AutomotiveTypography>() ??
        AutomotiveTypography.standard();
  }
}
