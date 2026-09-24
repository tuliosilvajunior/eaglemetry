import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/app_spacing.dart';

/// The journey's persistent instant-readout strip: one card pinned under the
/// body, showing one live reading at a time and cycling to the next on tap.
///
/// Pass it to `AppJourneyScaffold.footer`. It is chrome, not a destination's
/// content: built once above whatever switches the bodies, so changing tab
/// neither rebuilds it nor resets which reading it is on.
///
/// ## Which reading is showing is this widget's own state
///
/// Deliberately not lifted to the shell. The shell decides *whether* the strip
/// is there and how it moves; nothing above needs to know which of the
/// readings is face-up, and a caller that had to hold that index would have to
/// keep it alive across tab switches for no gain. The shell supplies the
/// readings and stays out of the cycle.
///
/// [readings] is content-agnostic on purpose — the strip does no formatting and
/// reads no vehicle signal itself. A reading that needs a spoken label should
/// carry its own `Semantics`; all this widget contributes is the button role
/// for the tap.
///
/// An empty list renders nothing at all, which is what a journey with no live
/// source yet should look like: a reserved strip, not an invented value.
class InstantReadoutBar extends StatefulWidget {
  const InstantReadoutBar({required this.readings, super.key});

  /// The readings to cycle through, in order. Index 0 shows first.
  ///
  /// A reading brings its own surface. The strip paints nothing of its own, so
  /// the width it does not use is canvas rather than an empty card, and a
  /// reading that is itself an `AppCard` is not a card drawn on a card.
  ///
  /// A reading is also given no width. It gets the strip's full height and as
  /// much width as it asks for, from the leading edge — the strip does not
  /// divide itself into shares, because a share is a guess about content the
  /// strip cannot see. A reading that wants the whole width can still take it.
  final List<Widget> readings;

  @override
  State<InstantReadoutBar> createState() => _InstantReadoutBarState();
}

class _InstantReadoutBarState extends State<InstantReadoutBar> {
  int _index = 0;

  /// Kept in range against a [readings] list that can change length while the
  /// strip is alive — a source going away must not leave the strip pointing
  /// past the end.
  int get _safeIndex =>
      widget.readings.isEmpty ? 0 : _index % widget.readings.length;

  void _cycle() {
    if (widget.readings.length < 2) return;
    HapticFeedback.selectionClick();
    setState(() => _index = _safeIndex + 1);
  }

  @override
  Widget build(BuildContext context) {
    final readings = widget.readings;
    if (readings.isEmpty) return const SizedBox.shrink();
    // A `Row` rather than an `Align`: it stretches the reading to the strip's
    // height while leaving its width loose, so the reading sizes itself and
    // what it does not take stays canvas.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: readings.length > 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _cycle,
            child: AnimatedSwitcher(
              duration: AppMotion.base,
              switchInCurve: AppMotion.curve,
              switchOutCurve: AppMotion.curve,
              // The default layout loosens both axes in its `Stack`, which
              // would drop the strip's height on the way to the reading and
              // leave it measuring itself against nothing. Passing the
              // constraints straight through keeps the height tight and the
              // width free, which is the whole contract here.
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.passthrough,
                alignment: AlignmentDirectional.centerStart,
                children: [...previous, ?current],
              ),
              child: KeyedSubtree(
                key: ValueKey(_safeIndex),
                child: readings[_safeIndex],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
