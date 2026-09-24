import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class AppJourneyScaffoldGalleryPage extends StatefulWidget {
  const AppJourneyScaffoldGalleryPage({super.key});

  @override
  State<AppJourneyScaffoldGalleryPage> createState() =>
      _AppJourneyScaffoldGalleryPageState();
}

enum _Dest { charging, trips, history }

class _AppJourneyScaffoldGalleryPageState
    extends State<AppJourneyScaffoldGalleryPage> {
  _Dest _selected = _Dest.charging;
  bool _footer = true;
  bool _staticBar = true;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'AppJourneyScaffold',
      summary:
          'Page-level shell: pill tabs, canvas, optional footer, and a '
          'static climate bar that no destination can take away.',
      note:
          'The footer is chrome of the journey and rides a card stage. The '
          'static bar is the vehicle\'s. Turn them on and off here to see '
          'what each one changes about the window.',
      scrollable: false,
      child: Column(
        children: [
          Padding(
            padding: AppSpacing.screenPadding.copyWith(top: 0),
            child: AppCard(
              title: 'Chrome',
              child: Column(
                children: [
                  SettingToggleRow(
                    label: 'Footer',
                    description: 'Instant readout under the body.',
                    value: _footer,
                    onChanged: (value) => setState(() => _footer = value),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  SettingToggleRow(
                    label: 'Static climate bar',
                    description: 'Paints the bezel and insets the window.',
                    value: _staticBar,
                    onChanged: (value) => setState(() => _staticBar = value),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: AppJourneyScaffold<_Dest>(
              tabs: const [
                TabItem(value: _Dest.charging, label: 'Charging'),
                TabItem(value: _Dest.trips, label: 'Trips'),
                TabItem(value: _Dest.history, label: 'History'),
              ],
              selected: _selected,
              onSelected: (value) => setState(() => _selected = value),
              trailing: SquareIconButton(
                icon: Icons.settings,
                size: AppSizes.minTouchTarget,
                onPressed: () {},
                tooltip: 'Settings',
              ),
              footer: _footer
                  ? const SizedBox(
                      height: 96,
                      child: InstantReadoutBar(
                        readings: [
                          SizedBox(
                            width: 280,
                            child: _MiniReading(
                              label: 'Outside',
                              value: '18.5°C',
                            ),
                          ),
                          SizedBox(
                            width: 280,
                            child: _MiniReading(label: 'Heading', value: '75°'),
                          ),
                        ],
                      ),
                    )
                  : null,
              staticBar: _staticBar
                  ? const ColoredBox(
                      color: AppColors.climateBarSurface,
                      child: Center(
                        child: Text(
                          'Climate bar — the vehicle\'s, not the journey\'s',
                          style: TextStyle(
                            color: AppColors.climateBarOnSurfaceMuted,
                          ),
                        ),
                      ),
                    )
                  : null,
              body: Padding(
                padding: AppSpacing.screenPadding,
                child: AppCard(
                  title: switch (_selected) {
                    _Dest.charging => 'Charging',
                    _Dest.trips => 'Trips',
                    _Dest.history => 'History',
                  },
                  child: const GalleryCaption(
                    'The selected destination. Changing tab does not rebuild '
                    'the footer or the static bar.',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniReading extends StatelessWidget {
  const _MiniReading({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      title: label,
      child: Text(value, style: AppText.cardTitle),
    );
  }
}
