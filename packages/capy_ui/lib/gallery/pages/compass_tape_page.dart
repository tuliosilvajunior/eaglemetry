import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class CompassTapeGalleryPage extends StatefulWidget {
  const CompassTapeGalleryPage({super.key});

  @override
  State<CompassTapeGalleryPage> createState() => _CompassTapeGalleryPageState();
}

class _CompassTapeGalleryPageState extends State<CompassTapeGalleryPage> {
  double? _compassDeg = 75;
  CompassState _compassState = CompassState.live;

  static const _cardinals = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'CompassTape',
      summary:
          'A strip of the compass dial running under a fixed centre bar. '
          'The tape moves. The bar does not.',
      note:
          'Jump 350° to 10° and the tape takes the short way through north. '
          'A held course is muted rather than dropped. `--` is a missing '
          'reading, not a fault painted as a dash on the card.',
      child: GalleryStack(
        children: [
          CompassCard(
            label: 'Compass',
            value: compassBearingLabel(_compassDeg),
            bearingDeg: _compassDeg,
            cardinalLabels: _cardinals,
            state: _compassState,
            caption: switch (_compassState) {
              CompassState.live => null,
              CompassState.held => 'Stopped. Last direction.',
              CompassState.unavailable => 'No GPS signal',
            },
          ),
          AppCard(
            title: 'Course',
            subtitle: 'Then how the reading stands',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrackSegmentedControl<double?>(
                  items: const [
                    TabItem(value: 0, label: '0°'),
                    TabItem(value: 75, label: '75°'),
                    TabItem(value: 180, label: '180°'),
                    TabItem(value: 350, label: '350°'),
                    TabItem(value: 10, label: '10°'),
                    TabItem(value: null, label: '--'),
                  ],
                  selected: _compassDeg,
                  onSelected: (value) => setState(() {
                    _compassDeg = value;
                    if (value == null) {
                      _compassState = CompassState.unavailable;
                    }
                    if (value != null &&
                        _compassState == CompassState.unavailable) {
                      _compassState = CompassState.live;
                    }
                  }),
                ),
                const SizedBox(height: AppSpacing.x4),
                TrackSegmentedControl<CompassState>(
                  items: const [
                    TabItem(value: CompassState.live, label: 'Live'),
                    TabItem(value: CompassState.held, label: 'Held'),
                    TabItem(value: CompassState.unavailable, label: 'None'),
                  ],
                  selected: _compassState,
                  onSelected: (value) => setState(() {
                    _compassState = value;
                    if (value == CompassState.unavailable) _compassDeg = null;
                    if (value != CompassState.unavailable &&
                        _compassDeg == null) {
                      _compassDeg = 75;
                    }
                  }),
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'Held is a stopped car: the course is kept and muted, '
                  'because the direction is still true and only its currency '
                  'changed.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
