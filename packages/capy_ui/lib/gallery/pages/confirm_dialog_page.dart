import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ConfirmDialogGalleryPage extends StatefulWidget {
  const ConfirmDialogGalleryPage({super.key});

  @override
  State<ConfirmDialogGalleryPage> createState() =>
      _ConfirmDialogGalleryPageState();
}

class _ConfirmDialogGalleryPageState extends State<ConfirmDialogGalleryPage> {
  String _last = 'Nothing confirmed yet';

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'ConfirmDialog',
      summary:
          'Asks before an action that cannot be undone. A tap on the '
          'scrim, cancel, and a back gesture all refuse the action.',
      note:
          'Destructive confirm is a critical glyph, not a red panel. A '
          'wide dialog would invite the eye to the buttons before the sentence.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Last answer',
            subtitle: _last,
            child: Column(
              children: [
                SoftActionTile(
                  icon: Icons.delete_outline,
                  label: 'Wipe telemetry (destructive)',
                  iconColor: AppColors.critical,
                  onPressed: () async {
                    final ok = await showConfirmDialog(
                      context: context,
                      title: 'Wipe all telemetry?',
                      message:
                          'This deletes every trip, charge and frame on '
                          'this unit. It cannot be undone.',
                      confirmLabel: 'Wipe',
                      cancelLabel: 'Keep',
                      barrierLabel: 'Close wipe confirmation',
                      destructive: true,
                    );
                    if (!mounted) return;
                    setState(() {
                      _last = ok == true
                          ? 'Confirmed wipe'
                          : 'Refused or dismissed';
                    });
                  },
                ),
                const SizedBox(height: AppSpacing.x3),
                SoftActionTile(
                  icon: Icons.merge_type,
                  label: 'Merge two charges',
                  onPressed: () async {
                    final ok = await showConfirmDialog(
                      context: context,
                      title: 'Merge these charges?',
                      message:
                          'The two sessions become one row. Totals add. '
                          'The older start time is kept.',
                      confirmLabel: 'Merge',
                      cancelLabel: 'Cancel',
                      barrierLabel: 'Close merge confirmation',
                    );
                    if (!mounted) return;
                    setState(() {
                      _last = ok == true
                          ? 'Confirmed merge'
                          : 'Refused or dismissed';
                    });
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
