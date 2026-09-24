import 'package:flutter/foundation.dart';

/// Which sibling gives up the quarter when the slot at [growIndex] grows.
///
/// The rule: whichever *other* slot currently holds the fewest quarters,
/// collapsing a same-size sibling to nothing before ever shrinking a bigger
/// one, with ties broken toward the lowest index. That is what makes growing
/// an edge card in a 1/2/1 row hide the *other* 1/4 card rather than shave the
/// 2/4 anchor, and makes growing the 2/4 card take from the left 1/4
/// specifically when both edges are tied.
///
/// Returns null when every other slot is already collapsed, so a release build
/// leaves the row alone instead of indexing with -1.
int? quarterDonorFor(List<int> levels, int growIndex) {
  int? donor;
  for (var i = 0; i < levels.length; i++) {
    if (i == growIndex || levels[i] <= 0) continue;
    if (donor == null || levels[i] < levels[donor]) donor = i;
  }
  return donor;
}

/// The resting quarter allocation of a card-stage row, and which slot (if any)
/// has been permanently grown by one.
///
/// This is the second, independent way a card can change size: a *permanent*
/// resize, triggered by a control rather than a drag, that stays where it is
/// set instead of springing back like `CardStageController`'s fullscreen
/// gesture. The two compose freely — the geometry a drag expands *from* is
/// always whatever [units] currently resolves to.
///
/// Immutable, so a screen holds one in `State` and replaces it:
///
/// ```dart
/// var _row = const CardStageResize([1, 2, 1]);
/// // ...
/// setState(() => _row = _row.toggled(index));
/// ```
///
/// Resizing is quarter-stepped by design: a card only ever moves 1/4 ↔ 2/4 or
/// 2/4 ↔ 3/4, never straight 1/4 ↔ 3/4. [toggled] always recomputes from
/// [baseLevels], so moving focus from one card to another passes through the
/// resting row rather than compounding two grows.
@immutable
class CardStageResize {
  const CardStageResize(this.baseLevels)
    : focusedIndex = null,
      donorIndex = null;

  const CardStageResize._(this.baseLevels, this.focusedIndex, this.donorIndex);

  /// Quarters each slot rests at, left to right. Any ratio works as long as
  /// every slot shares the same unit — `[1, 2, 1]` is the dashboard grid.
  final List<int> baseLevels;

  /// The slot currently grown by one quarter, or null for the resting row.
  final int? focusedIndex;

  /// The slot that gave that quarter up. Non-null exactly when
  /// [focusedIndex] is.
  final int? donorIndex;

  bool isFocused(int index) => focusedIndex == index;

  /// What to hand `ExpandableCardStage` as each slot's `units`.
  List<double> get units {
    final levels = List<int>.of(baseLevels);
    final focused = focusedIndex;
    if (focused != null) {
      levels[focused]++;
      levels[donorIndex!]--;
    }
    return [for (final level in levels) level.toDouble()];
  }

  /// Grows [index] by a quarter, or returns to the resting row if it is
  /// already the focused slot.
  ///
  /// Returns `this` unchanged when there is nothing left to take — every other
  /// slot already collapsed — rather than resizing the row into something
  /// incoherent.
  CardStageResize toggled(int index) {
    if (focusedIndex == index) return CardStageResize(baseLevels);
    final donor = quarterDonorFor(baseLevels, index);
    if (donor == null) return this;
    return CardStageResize._(baseLevels, index, donor);
  }
}
