import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class RouteMapCardGalleryPage extends StatefulWidget {
  const RouteMapCardGalleryPage({super.key});

  @override
  State<RouteMapCardGalleryPage> createState() =>
      _RouteMapCardGalleryPageState();
}

enum _RouteKind { drive, still, empty }

class _RouteMapCardGalleryPageState extends State<RouteMapCardGalleryPage> {
  _RouteKind _kind = _RouteKind.drive;
  bool _expanded = false;

  static const _drive = [
    RouteMapPoint(latitude: 38.7223, longitude: -9.1393, speedKmh: 18),
    RouteMapPoint(latitude: 38.7255, longitude: -9.1502, speedKmh: 42),
    RouteMapPoint(latitude: 38.7310, longitude: -9.1608, speedKmh: 68),
    RouteMapPoint(latitude: 38.7364, longitude: -9.1681, speedKmh: 91),
    RouteMapPoint(latitude: 38.7422, longitude: -9.1724, speedKmh: 54),
    RouteMapPoint(latitude: 38.7481, longitude: -9.1750, speedKmh: 22),
  ];

  static const _still = [RouteMapPoint(latitude: 38.7223, longitude: -9.1393)];

  @override
  Widget build(BuildContext context) {
    final points = switch (_kind) {
      _RouteKind.drive => _drive,
      _RouteKind.still => _still,
      _RouteKind.empty => const <RouteMapPoint>[],
    };
    final scale = RouteSpeedScale.fromPoints(points);

    return GalleryDemoPage(
      title: 'RouteMapCard',
      summary:
          'Recorded path on a muted map. Colour is relative to this '
          'drive, not to an absolute speed.',
      note:
          'A single point draws a marker. An empty list draws an empty '
          'card. A leg with no speed is drawn in the unknown colour, not '
          'the slowest one.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Route',
            child: TrackSegmentedControl<_RouteKind>(
              items: const [
                TabItem(value: _RouteKind.drive, label: 'Drive'),
                TabItem(value: _RouteKind.still, label: 'One point'),
                TabItem(value: _RouteKind.empty, label: 'Empty'),
              ],
              selected: _kind,
              onSelected: (value) => setState(() {
                _kind = value;
                _expanded = false;
              }),
            ),
          ),
          SizedBox(
            height: _expanded ? 520 : 360,
            child: RouteMapCard(
              points: points,
              square: false,
              expanded: _expanded,
              expandLabel: 'Expand map',
              collapseLabel: 'Collapse map',
              onToggleExpanded: () => setState(() => _expanded = !_expanded),
              speedLegend: scale.hasSpeed
                  ? RouteSpeedLegend(
                      slowLabel: '${scale.slowestKmh!.round()} km/h',
                      fastLabel: '${scale.fastestKmh!.round()} km/h',
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
