import 'package:flutter/widgets.dart';

/// Width bucket following Material 3 window size classes.
///
/// `compact` is a phone, `expanded` is the head unit, `medium` covers
/// tablets and foldables between them.
enum SurfaceWidthClass { compact, medium, expanded }

/// How the reader primarily moves focus.
enum SurfaceInputMode { touch, rotary }

/// Layout density. Compact fits more content; comfortable keeps the
/// automotive minimums.
enum SurfaceDensity { compact, comfortable }

/// Value object describing what the current surface can do.
///
/// Bodies branch on this, never on a platform flag. The single factory
/// [SurfaceCapabilities.of] derives the object from [MediaQuery], so the
/// contract is one object, not N dispersed checks.
@immutable
class SurfaceCapabilities {
  const SurfaceCapabilities({
    required this.widthClass,
    required this.supportsSelection,
    required this.inputMode,
    required this.allowKeyboard,
    required this.density,
  });

  /// Derives capabilities from the available width.
  ///
  /// Thresholds follow Material 3: `compact` < 600, `medium` 600-839,
  /// `expanded` >= 840.
  factory SurfaceCapabilities.of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return SurfaceCapabilities.fromWidth(width);
  }

  /// Direct width constructor, used by tests and by callers that already have
  /// a width.
  factory SurfaceCapabilities.fromWidth(double width) {
    final widthClass = _widthClassForWidth(width);
    // Phone (compact) has no persistent selection; head unit (expanded)
    // keeps selection across panes.
    final supportsSelection = widthClass == SurfaceWidthClass.expanded;
    final inputMode = widthClass == SurfaceWidthClass.expanded
        ? SurfaceInputMode.rotary
        : SurfaceInputMode.touch;
    final allowKeyboard = true;
    final density = widthClass == SurfaceWidthClass.compact
        ? SurfaceDensity.compact
        : SurfaceDensity.comfortable;
    return SurfaceCapabilities(
      widthClass: widthClass,
      supportsSelection: supportsSelection,
      inputMode: inputMode,
      allowKeyboard: allowKeyboard,
      density: density,
    );
  }

  static SurfaceWidthClass _widthClassForWidth(double width) {
    if (width < 600) return SurfaceWidthClass.compact;
    if (width < 840) return SurfaceWidthClass.medium;
    return SurfaceWidthClass.expanded;
  }

  final SurfaceWidthClass widthClass;
  final bool supportsSelection;
  final SurfaceInputMode inputMode;
  final bool allowKeyboard;
  final SurfaceDensity density;

  SurfaceCapabilities copyWith({
    SurfaceWidthClass? widthClass,
    bool? supportsSelection,
    SurfaceInputMode? inputMode,
    bool? allowKeyboard,
    SurfaceDensity? density,
  }) {
    return SurfaceCapabilities(
      widthClass: widthClass ?? this.widthClass,
      supportsSelection: supportsSelection ?? this.supportsSelection,
      inputMode: inputMode ?? this.inputMode,
      allowKeyboard: allowKeyboard ?? this.allowKeyboard,
      density: density ?? this.density,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SurfaceCapabilities &&
          other.widthClass == widthClass &&
          other.supportsSelection == supportsSelection &&
          other.inputMode == inputMode &&
          other.allowKeyboard == allowKeyboard &&
          other.density == density;

  @override
  int get hashCode => Object.hash(
    widthClass,
    supportsSelection,
    inputMode,
    allowKeyboard,
    density,
  );

  @override
  String toString() =>
      'SurfaceCapabilities(widthClass: $widthClass, supportsSelection: $supportsSelection, inputMode: $inputMode, allowKeyboard: $allowKeyboard, density: $density)';
}
