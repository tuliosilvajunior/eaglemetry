import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_system/design_system.dart';

/// A "cryptex" value picker: a row of independently spinnable digit rings
/// (like the rotating cylinders of a cryptex) that together compose a currency
/// amount with two decimal places — e.g. a charge price per kWh or a total
/// paid amount.
///
/// The number of integer rings is [integerDigits] (decimals are fixed at two),
/// so the value ranges from `0.00` to `10^integerDigits - 0.01`. Each ring
/// loops endlessly over `0-9` with iOS-style perspective via
/// [ListWheelScrollView]. Spinning any ring re-assembles the value and calls
/// [onChanged]; changing [value] from outside spins the rings to match along
/// the shortest path.
class ChargeCostCryptex extends StatefulWidget {
  const ChargeCostCryptex({
    super.key,
    required this.value,
    required this.currency,
    required this.onChanged,
    this.integerDigits = 2,
    this.suffix,
    this.enabled = true,
  });

  /// Current amount, clamped to `0.00 .. 10^integerDigits - 0.01`.
  final double value;

  /// Currency symbol shown to the left of the rings (e.g. `R$`).
  final String currency;

  /// Called with the newly assembled amount whenever a ring settles on a digit.
  final ValueChanged<double> onChanged;

  /// Number of integer-part rings. Decimals are always two.
  final int integerDigits;

  /// Optional unit shown after the rings (e.g. `/ kWh`).
  final String? suffix;

  final bool enabled;

  @override
  State<ChargeCostCryptex> createState() => _ChargeCostCryptexState();
}

const int _decimalDigits = 2;
const double _wheelItemExtent = 44;
const double _wheelWidth = 46;
const int _visibleRows = 3;

class _ChargeCostCryptexState extends State<ChargeCostCryptex> {
  late final List<FixedExtentScrollController> _controllers;
  late List<int> _digits;

  int get _digitCount => widget.integerDigits + _decimalDigits;

  int get _maxCents {
    var max = 1;
    for (var i = 0; i < _digitCount; i++) {
      max *= 10;
    }
    return max - 1;
  }

  @override
  void initState() {
    super.initState();
    _digits = _digitsFromValue(widget.value);
    _controllers = [
      for (final digit in _digits)
        FixedExtentScrollController(initialItem: digit),
    ];
  }

  @override
  void didUpdateWidget(ChargeCostCryptex oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reflect external value changes (e.g. cleared to zero). Self-induced
    // changes already match, so this only fires for outside edits.
    if (_centsFromDigits(_digits) != _centsFromValue(widget.value)) {
      final target = _digitsFromValue(widget.value);
      for (var i = 0; i < _digitCount; i++) {
        if (target[i] != _digits[i]) {
          _spinToDigit(i, target[i]);
        }
      }
      _digits = target;
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  int _centsFromValue(double value) =>
      (value.clamp(0.0, _maxCents / 100) * 100).round();

  List<int> _digitsFromValue(double value) {
    var cents = _centsFromValue(value);
    final digits = List<int>.filled(_digitCount, 0);
    for (var i = _digitCount - 1; i >= 0; i--) {
      digits[i] = cents % 10;
      cents ~/= 10;
    }
    return digits;
  }

  int _centsFromDigits(List<int> digits) {
    var cents = 0;
    for (final digit in digits) {
      cents = cents * 10 + digit;
    }
    return cents;
  }

  void _spinToDigit(int position, int targetDigit) {
    final controller = _controllers[position];
    if (!controller.hasClients) return;
    final current = controller.selectedItem;
    final currentDigit = ((current % 10) + 10) % 10;
    var delta = targetDigit - currentDigit;
    // Take the shortest way around the ring.
    if (delta > 5) delta -= 10;
    if (delta < -5) delta += 10;
    if (delta == 0) return;
    controller.animateToItem(
      current + delta,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _onDigitChanged(int position, int rawIndex) {
    final digit = ((rawIndex % 10) + 10) % 10;
    if (_digits[position] == digit) return;
    setState(() => _digits[position] = digit);
    HapticFeedback.selectionClick();
    widget.onChanged(_centsFromDigits(_digits) / 100);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final suffix = widget.suffix;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.x2,
        vertical: AutomotiveSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: AutomotiveRadii.baseRadius,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The selection "window" the active digit of every ring lines up in.
          IgnorePointer(
            child: Container(
              height: _wheelItemExtent,
              decoration: BoxDecoration(
                color: colorScheme.secondary.withValues(alpha: 0.10),
                borderRadius: AutomotiveRadii.baseRadius,
                border: Border(
                  top: BorderSide(color: colorScheme.secondary),
                  bottom: BorderSide(color: colorScheme.secondary),
                ),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _label(widget.currency, colorScheme.onSurfaceVariant),
              const SizedBox(width: AutomotiveSpacing.x1),
              for (var i = 0; i < widget.integerDigits; i++)
                _wheel(i, colorScheme),
              _label(',', colorScheme.onSurface),
              for (var i = widget.integerDigits; i < _digitCount; i++)
                _wheel(i, colorScheme),
              if (suffix != null && suffix.isNotEmpty) ...[
                const SizedBox(width: AutomotiveSpacing.x1),
                _label(suffix, colorScheme.onSurfaceVariant, small: true),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _label(String text, Color color, {bool small = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        text,
        style:
            (small
                    ? AutomotiveTextStyles.unitLabel
                    : AutomotiveTextStyles.headlineMd)
                .copyWith(color: color, fontFamily: AutomotiveFonts.mono),
      ),
    );
  }

  Widget _wheel(int position, ColorScheme colorScheme) {
    return SizedBox(
      width: _wheelWidth,
      height: _wheelItemExtent * _visibleRows,
      // A digit ring is not a scrollable list — suppress the auto scrollbar
      // that web/desktop ScrollBehavior would otherwise attach to it.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListWheelScrollView.useDelegate(
          controller: _controllers[position],
          itemExtent: _wheelItemExtent,
          perspective: 0.006,
          diameterRatio: 1.25,
          overAndUnderCenterOpacity: 0.35,
          physics: widget.enabled
              ? const FixedExtentScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          onSelectedItemChanged: widget.enabled
              ? (index) => _onDigitChanged(position, index)
              : null,
          childDelegate: ListWheelChildLoopingListDelegate(
            children: [
              for (var d = 0; d <= 9; d++)
                Center(
                  child: Text(
                    '$d',
                    style: AutomotiveTextStyles.headlineLg.copyWith(
                      color: colorScheme.onSurface,
                      fontFamily: AutomotiveFonts.mono,
                      fontSize: 30,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
