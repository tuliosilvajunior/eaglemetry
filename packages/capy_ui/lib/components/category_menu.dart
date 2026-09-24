import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'floating_surface.dart';

/// One category in the rail of a [CategoryMenu].
class CategoryMenuEntry<T> {
  const CategoryMenuEntry({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;

  /// Localized label. Wraps to a second line, as `Mirrors and steering wheel`
  /// does in the reference.
  final String label;

  final IconData icon;
}

/// A run of entries separated from its neighbours by a rule.
///
/// A group is the only separator in the rail. Everything else in this system
/// separates by surface contrast, but the rail has no surface of its own to
/// step down from — it sits directly on the panel — so the rule is the
/// deliberate exception `DESIGN.md` reserves for a real separator.
class CategoryMenuGroup<T> {
  const CategoryMenuGroup(this.entries);

  final List<CategoryMenuEntry<T>> entries;
}

/// Optional search row above the rail.
///
/// The component filters by a case-insensitive match on
/// [CategoryMenuEntry.label], which is the text the user is reading. Both
/// strings are supplied by the caller, per the no-hardcoded-strings rule.
class CategoryMenuSearch {
  const CategoryMenuSearch({required this.hint, required this.emptyLabel});

  /// Placeholder inside the empty field.
  final String hint;

  /// Shown in place of the rail when no label matches.
  final String emptyLabel;
}

/// Master-detail menu: a rail of categories on the left, the options for the
/// selected category on the right.
///
/// This is the controlled, embeddable form. [showCategoryMenu] floats it over
/// the screen, which is how the app uses it; the plain widget exists so the
/// gallery and tests can render it without a route.
///
/// The rail is the only selection surface. The detail side is entirely the
/// caller's — [detailBuilder] receives the selected value and returns whatever
/// that category needs, and the panel scrolls it. The menu therefore knows
/// nothing about settings, and holds no copy of the state it is showing.
class CategoryMenu<T> extends StatefulWidget {
  const CategoryMenu({
    required this.groups,
    required this.selected,
    required this.onSelected,
    required this.detailBuilder,
    this.search,
    this.detailScrolls = true,
    this.railWidth = AppSizes.categoryMenuRailWidth,
    super.key,
  });

  final List<CategoryMenuGroup<T>> groups;

  /// The category whose options the detail side is showing.
  final T selected;

  final ValueChanged<T> onSelected;

  final Widget Function(BuildContext context, T selected) detailBuilder;

  /// Omit for a rail with no search row.
  final CategoryMenuSearch? search;

  /// Whether the panel scrolls the detail side for the caller.
  ///
  /// True for a category whose detail is a page of controls: the menu gives it
  /// unbounded height and one scroll view around the lot, which is what every
  /// settings category wants.
  ///
  /// False hands the detail a **bounded** box and its own scrolling. A
  /// category whose detail is a long list of records needs this: inside the
  /// menu's scroll view a list has no viewport to be lazy against and builds
  /// every row it has, so fifty records are fifty rows laid out in one frame.
  /// Given the box, the same list builds the handful that are visible.
  final bool detailScrolls;

  final double railWidth;

  @override
  State<CategoryMenu<T>> createState() => _CategoryMenuState<T>();
}

class _CategoryMenuState<T> extends State<CategoryMenu<T>> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Groups that survive the query, with empty groups dropped so the rail
  /// never renders a rule with nothing under it.
  List<CategoryMenuGroup<T>> get _visibleGroups {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return widget.groups;
    final groups = <CategoryMenuGroup<T>>[];
    for (final group in widget.groups) {
      final entries = group.entries
          .where((entry) => entry.label.toLowerCase().contains(query))
          .toList();
      if (entries.isNotEmpty) groups.add(CategoryMenuGroup<T>(entries));
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final search = widget.search;
    final groups = _visibleGroups;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: widget.railWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (search != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.x4,
                    AppSpacing.x4,
                    AppSpacing.x4,
                    AppSpacing.x2,
                  ),
                  child: _CategorySearchField(
                    controller: _query,
                    hint: search.hint,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                _CategoryRule(color: colors.divider),
              ],
              Expanded(
                child: groups.isEmpty && search != null
                    ? _CategoryEmptyState(label: search.emptyLabel)
                    : ListView.separated(
                        padding: const EdgeInsets.all(AppSpacing.x4),
                        itemCount: groups.length,
                        separatorBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.x2,
                          ),
                          child: _CategoryRule(color: colors.divider),
                        ),
                        itemBuilder: (context, index) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final entry in groups[index].entries)
                              _CategoryRailRow<T>(
                                entry: entry,
                                selected: entry.value == widget.selected,
                                onPressed: () => widget.onSelected(entry.value),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: colors.canvas,
            // The padding belongs to the scroll view in the scrolling mode, so
            // the content still runs to the panel edge once it has been
            // scrolled. A detail that scrolls itself gets it as a plain inset
            // instead: where its own padding goes is its business, and this is
            // only the frame it is given.
            child: widget.detailScrolls
                ? SingleChildScrollView(
                    padding: AppSpacing.cardPadding,
                    child: widget.detailBuilder(context, widget.selected),
                  )
                : Padding(
                    padding: AppSpacing.cardPadding,
                    child: widget.detailBuilder(context, widget.selected),
                  ),
          ),
        ),
      ],
    );
  }
}

class _CategoryRailRow<T> extends StatelessWidget {
  const _CategoryRailRow({
    required this.entry,
    required this.selected,
    required this.onPressed,
  });

  final CategoryMenuEntry<T> entry;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final foreground = selected ? colors.onSelection : colors.ink;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x1),
      child: Material(
        color: selected ? colors.selectionFill : colors.surface,
        borderRadius: AppRadii.mdRadius,
        animationDuration: AppMotion.fast,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.mdRadius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSizes.minTouchTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4,
                vertical: AppSpacing.x2,
              ),
              child: Row(
                children: [
                  Icon(entry.icon, size: AppSizes.iconMd, color: foreground),
                  const SizedBox(width: AppSpacing.x3),
                  Expanded(
                    child: Text(
                      entry.label,
                      style: (selected ? AppText.bodyStrong : AppText.body)
                          .copyWith(color: foreground),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
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

class _CategorySearchField extends StatelessWidget {
  const _CategorySearchField({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Container(
      height: AppSizes.minTouchTarget,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
      decoration: BoxDecoration(
        color: colors.control,
        borderRadius: AppRadii.fullRadius,
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: AppSizes.iconMd, color: colors.inkSubtle),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: AppText.body.copyWith(color: colors.ink),
              cursorColor: colors.ink,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryEmptyState extends StatelessWidget {
  const _CategoryEmptyState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Padding(
      padding: AppSpacing.cardPadding,
      child: Text(label, style: AppText.body.copyWith(color: colors.inkSubtle)),
    );
  }
}

class _CategoryRule extends StatelessWidget {
  const _CategoryRule({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSizes.categoryMenuRule,
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
      color: color,
    );
  }
}

/// Floats a [CategoryMenu] over the screen, above everything, on a dimmed
/// backdrop.
///
/// It uses the same scrim, timing, and 97% entry scale as the anchored
/// tooltip, so the two floating surfaces in the app arrive the same way. It is
/// centered rather than anchored: this panel is a card-sized surface with its
/// own internal navigation, and a caret pointing back at a button would claim
/// it belongs to that button.
///
/// The panel keeps its own selection while it is open, starting at
/// [initialSelected]. [onSelected] reports each change to the caller, which
/// stays free to persist it or ignore it.
Future<void> showCategoryMenu<T>({
  required BuildContext context,
  required List<CategoryMenuGroup<T>> groups,
  required T initialSelected,
  required Widget Function(BuildContext context, T selected) detailBuilder,
  required String barrierLabel,
  CategoryMenuSearch? search,
  ValueChanged<T>? onSelected,
}) {
  return showFloatingSurface<void>(
    context: context,
    barrierLabel: barrierLabel,
    pageBuilder: (context, animation, secondaryAnimation) {
      return _CategoryMenuOverlay<T>(
        groups: groups,
        initialSelected: initialSelected,
        detailBuilder: detailBuilder,
        search: search,
        onSelected: onSelected,
      );
    },
  );
}

class _CategoryMenuOverlay<T> extends StatefulWidget {
  const _CategoryMenuOverlay({
    required this.groups,
    required this.initialSelected,
    required this.detailBuilder,
    required this.search,
    required this.onSelected,
  });

  final List<CategoryMenuGroup<T>> groups;
  final T initialSelected;
  final Widget Function(BuildContext context, T selected) detailBuilder;
  final CategoryMenuSearch? search;
  final ValueChanged<T>? onSelected;

  @override
  State<_CategoryMenuOverlay<T>> createState() =>
      _CategoryMenuOverlayState<T>();
}

class _CategoryMenuOverlayState<T> extends State<_CategoryMenuOverlay<T>> {
  late T _selected = widget.initialSelected;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final safePadding = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    final available = Size(
      size.width - safePadding.horizontal - AppSpacing.x12 * 2,
      size.height - safePadding.vertical - AppSpacing.x12,
    );
    final panelSize = Size(
      math.min(available.width, AppSizes.categoryMenuWidth),
      math.min(available.height, AppSizes.categoryMenuHeight),
    );

    return Center(
      child: SizedBox.fromSize(
        key: const Key('category-menu-panel'),
        size: panelSize,
        child: Material(
          color: colors.surface,
          borderRadius: AppRadii.xlRadius,
          clipBehavior: Clip.antiAlias,
          child: CategoryMenu<T>(
            groups: widget.groups,
            selected: _selected,
            search: widget.search,
            detailBuilder: widget.detailBuilder,
            onSelected: (value) {
              if (value == _selected) return;
              setState(() => _selected = value);
              widget.onSelected?.call(value);
            },
          ),
        ),
      ),
    );
  }
}
