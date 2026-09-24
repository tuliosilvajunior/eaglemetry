import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Preferred vertical direction for a dropdown menu.
///
/// An explicit direction flips when it cannot contain the full menu and the
/// opposite direction can. [auto] selects the direction with more space.
enum DropdownMenuDirection { auto, up, down }

@immutable
class DropdownOption<T> {
  const DropdownOption({required this.value, required this.label});

  final T value;

  /// Localized text shown in the field and menu.
  final String label;
}

/// Controlled selector with a modal, width-matched option menu.
///
/// The field uses the inverse selected state while the menu is open. The route
/// dims the remaining screen. The menu fades and moves upward on entry, then
/// sends the new value before it plays the inverse transition.
class DropdownField<T> extends StatefulWidget {
  const DropdownField({
    required this.value,
    required this.options,
    required this.onChanged,
    required this.barrierLabel,
    this.width,
    this.direction = DropdownMenuDirection.auto,
    super.key,
  }) : assert(options.length > 0);

  final T value;
  final List<DropdownOption<T>> options;
  final ValueChanged<T>? onChanged;
  final String barrierLabel;

  /// Fixed width. Leave null to fill the available parent width.
  final double? width;

  final DropdownMenuDirection direction;

  @override
  State<DropdownField<T>> createState() => _DropdownFieldState<T>();
}

class _DropdownFieldState<T> extends State<DropdownField<T>> {
  bool _isOpen = false;

  DropdownOption<T> get _selected => widget.options.firstWhere(
    (option) => option.value == widget.value,
    orElse: () => widget.options.first,
  );

  Future<void> _open(BuildContext anchorContext) async {
    if (_isOpen || widget.onChanged == null) return;

    final waitForReverse = !MediaQuery.disableAnimationsOf(context);
    setState(() => _isOpen = true);
    DropdownOption<T>? selected;
    try {
      selected = await showDropdownOptions<T>(
        context: context,
        anchorContext: anchorContext,
        options: widget.options,
        selectedValue: widget.value,
        barrierLabel: widget.barrierLabel,
        direction: widget.direction,
      );
      if (mounted && selected != null) widget.onChanged!(selected.value);
      if (waitForReverse) await Future<void>.delayed(AppMotion.base);
    } finally {
      if (mounted) setState(() => _isOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final enabled = widget.onChanged != null;
    final active = enabled && _isOpen;
    final foreground = !enabled
        ? colors.inkSubtle
        : active
        ? colors.onSelection
        : colors.ink;

    return Builder(
      builder: (anchorContext) => Material(
        key: const Key('dropdown-field-material'),
        color: active ? colors.selectionFill : colors.control,
        borderRadius: AppRadii.mdRadius,
        animationDuration: AppMotion.fast,
        child: InkWell(
          onTap: enabled ? () => _open(anchorContext) : null,
          borderRadius: AppRadii.mdRadius,
          child: SizedBox(
            width: widget.width,
            height: AppSizes.actionRowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _selected.label,
                      style: AppText.bodyStrong.copyWith(color: foreground),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x3),
                  Icon(
                    active
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: AppSizes.iconMd,
                    color: foreground,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a width-matched dropdown menu next to [anchorContext].
Future<DropdownOption<T>?> showDropdownOptions<T>({
  required BuildContext context,
  required BuildContext anchorContext,
  required List<DropdownOption<T>> options,
  required T selectedValue,
  required String barrierLabel,
  DropdownMenuDirection direction = DropdownMenuDirection.auto,
}) {
  assert(options.isNotEmpty);

  final anchorBox = anchorContext.findRenderObject()! as RenderBox;
  final anchorRect = anchorBox.localToGlobal(Offset.zero) & anchorBox.size;
  final disableAnimations = MediaQuery.disableAnimationsOf(context);

  return showGeneralDialog<DropdownOption<T>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: AppThemeColors.of(context).modalScrim,
    transitionDuration: disableAnimations ? Duration.zero : AppMotion.base,
    pageBuilder: (context, animation, secondaryAnimation) {
      final progress = disableAnimations
          ? const AlwaysStoppedAnimation<double>(1)
          : CurvedAnimation(
              parent: animation,
              curve: AppMotion.curve,
              reverseCurve: Curves.easeInCubic,
            );
      return _DropdownMenuOverlay<T>(
        anchorRect: anchorRect,
        direction: direction,
        animation: progress,
        options: options,
        selectedValue: selectedValue,
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

class _DropdownMenuOverlay<T> extends StatelessWidget {
  const _DropdownMenuOverlay({
    required this.anchorRect,
    required this.direction,
    required this.animation,
    required this.options,
    required this.selectedValue,
  });

  final Rect anchorRect;
  final DropdownMenuDirection direction;
  final Animation<double> animation;
  final List<DropdownOption<T>> options;
  final T selectedValue;

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.paddingOf(context);
    return CustomSingleChildLayout(
      delegate: _DropdownMenuLayoutDelegate(
        anchorRect: anchorRect,
        preferredDirection: direction,
        safePadding: safePadding,
      ),
      child: FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(animation),
          child: _DropdownMenu<T>(
            width: anchorRect.width,
            options: options,
            selectedValue: selectedValue,
          ),
        ),
      ),
    );
  }
}

class _DropdownMenu<T> extends StatefulWidget {
  const _DropdownMenu({
    required this.width,
    required this.options,
    required this.selectedValue,
  });

  final double width;
  final List<DropdownOption<T>> options;
  final T selectedValue;

  @override
  State<_DropdownMenu<T>> createState() => _DropdownMenuState<T>();
}

class _DropdownMenuState<T> extends State<_DropdownMenu<T>> {
  late T _selectedValue = widget.selectedValue;

  void _select(DropdownOption<T> option) {
    setState(() => _selectedValue = option.value);
    Navigator.of(context).pop(option);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return SizedBox(
      key: const Key('dropdown-menu-surface'),
      width: widget.width,
      child: Material(
        color: colors.surface,
        borderRadius: AppRadii.mdRadius,
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.x2),
          shrinkWrap: true,
          itemCount: widget.options.length,
          separatorBuilder: (context, index) =>
              const SizedBox(height: AppSpacing.x2),
          itemBuilder: (context, index) {
            final option = widget.options[index];
            final selected = option.value == _selectedValue;
            return Material(
              color: selected ? colors.selectionFill : colors.control,
              borderRadius: AppRadii.smRadius,
              child: InkWell(
                key: ValueKey<Object?>(option.value),
                onTap: () => _select(option),
                borderRadius: AppRadii.smRadius,
                child: SizedBox(
                  height: AppSizes.actionRowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x8,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        option.label,
                        style: AppText.bodyStrong.copyWith(
                          color: selected ? colors.onSelection : colors.ink,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DropdownMenuLayoutDelegate extends SingleChildLayoutDelegate {
  _DropdownMenuLayoutDelegate({
    required this.anchorRect,
    required this.preferredDirection,
    required this.safePadding,
  });

  final Rect anchorRect;
  final DropdownMenuDirection preferredDirection;
  final EdgeInsets safePadding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final minTop = safePadding.top + AppSpacing.screenPadding.top;
    final maxBottom =
        constraints.maxHeight -
        safePadding.bottom -
        AppSpacing.screenPadding.bottom;
    return BoxConstraints(
      maxWidth: anchorRect.width,
      maxHeight: (maxBottom - minTop).clamp(0.0, double.infinity),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minLeft = safePadding.left + AppSpacing.screenPadding.left;
    final maxRight =
        size.width - safePadding.right - AppSpacing.screenPadding.right;
    final minTop = safePadding.top + AppSpacing.screenPadding.top;
    final maxBottom =
        size.height - safePadding.bottom - AppSpacing.screenPadding.bottom;
    final availableUp = anchorRect.bottom - minTop;
    final availableDown = maxBottom - anchorRect.top;
    final direction = _resolveDirection(
      menuHeight: childSize.height,
      availableUp: availableUp,
      availableDown: availableDown,
    );
    final desiredTop = switch (direction) {
      DropdownMenuDirection.up => anchorRect.bottom - childSize.height,
      DropdownMenuDirection.down => anchorRect.top,
      DropdownMenuDirection.auto => throw StateError('auto must resolve'),
    };
    final left = anchorRect.left
        .clamp(minLeft, maxRight - childSize.width)
        .toDouble();
    final top = desiredTop
        .clamp(minTop, maxBottom - childSize.height)
        .toDouble();
    return Offset(left, top);
  }

  DropdownMenuDirection _resolveDirection({
    required double menuHeight,
    required double availableUp,
    required double availableDown,
  }) {
    final upFits = availableUp >= menuHeight;
    final downFits = availableDown >= menuHeight;
    return switch (preferredDirection) {
      DropdownMenuDirection.auto =>
        availableDown >= availableUp
            ? DropdownMenuDirection.down
            : DropdownMenuDirection.up,
      DropdownMenuDirection.up when !upFits && downFits =>
        DropdownMenuDirection.down,
      DropdownMenuDirection.down when !downFits && upFits =>
        DropdownMenuDirection.up,
      _ => preferredDirection,
    };
  }

  @override
  bool shouldRelayout(_DropdownMenuLayoutDelegate oldDelegate) {
    return anchorRect != oldDelegate.anchorRect ||
        preferredDirection != oldDelegate.preferredDirection ||
        safePadding != oldDelegate.safePadding;
  }
}
