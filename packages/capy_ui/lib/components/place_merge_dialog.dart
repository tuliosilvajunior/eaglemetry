import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../bodies/places_merge_body.dart';
import 'floating_surface.dart';

/// Convenience around [PlacesMergeBody] for callers that want a dialog.
///
/// The reply carries the keep/delete ids and the proposed geometry; the
/// caller performs the update plus the tombstone delete.
Future<PlaceMergeSave?> showPlacesMergeDialog({
  required BuildContext context,
  required PlaceDuplicatePair pair,
  String title = 'Mesclar locais',
  String saveLabel = 'Confirmar mescla',
  String cancelLabel = 'Cancelar',
  required String barrierLabel,
}) {
  return showFloatingSurface<PlaceMergeSave>(
    context: context,
    barrierLabel: barrierLabel,
    pageBuilder: (context, animation, secondaryAnimation) {
      return _PlaceMergeDialog(
        pair: pair,
        title: title,
        saveLabel: saveLabel,
        cancelLabel: cancelLabel,
      );
    },
  );
}

class _PlaceMergeDialog extends StatelessWidget {
  const _PlaceMergeDialog({
    required this.pair,
    required this.title,
    required this.saveLabel,
    required this.cancelLabel,
  });

  final PlaceDuplicatePair pair;
  final String title;
  final String saveLabel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    return FloatingPanel(
      child: PlacesMergeBody(
        pair: pair,
        title: title,
        saveLabel: saveLabel,
        cancelLabel: cancelLabel,
        onSave: (save) => Navigator.of(context).pop(save),
        onCancel: () => Navigator.of(context).pop(),
      ),
    );
  }
}
