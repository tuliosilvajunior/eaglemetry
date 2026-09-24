import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SettingToggleRowGalleryPage extends StatefulWidget {
  const SettingToggleRowGalleryPage({super.key});

  @override
  State<SettingToggleRowGalleryPage> createState() =>
      _SettingToggleRowGalleryPageState();
}

class _SettingToggleRowGalleryPageState
    extends State<SettingToggleRowGalleryPage> {
  bool _gps = true;
  bool _autoStart = false;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'SettingToggleRow',
      summary:
          'Named setting with a switch. The on state is the theme amber, '
          'the one named exception that lets a series hue carry a control state.',
      note:
          'The whole row is the target. Disabled keeps the switch in the '
          'state it is stuck in rather than hiding the row.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Live',
            child: Column(
              children: [
                SettingToggleRow(
                  label: 'Record GPS',
                  description: 'Store a position with each frame.',
                  value: _gps,
                  onChanged: (value) => setState(() => _gps = value),
                ),
                const SizedBox(height: AppSpacing.x3),
                SettingToggleRow(
                  label: 'Start collection on boot',
                  value: _autoStart,
                  onChanged: (value) => setState(() => _autoStart = value),
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'Disabled',
            child: Column(
              children: [
                SettingToggleRow(
                  label: 'On, no write',
                  description: 'The switch stays on and the label drops.',
                  value: true,
                  onChanged: null,
                ),
                SizedBox(height: AppSpacing.x3),
                SettingToggleRow(
                  label: 'Off, no write',
                  value: false,
                  onChanged: null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
