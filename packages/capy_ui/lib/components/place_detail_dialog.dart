import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../bodies/places_detail_body.dart';
import 'floating_surface.dart';

/// Convenience around [PlacesDetailBody] for callers that want a dialog.
Future<PlaceDetailSave?> showPlaceDetailDialog({
  required BuildContext context,
  required double latitude,
  required double longitude,
  String? placeId,
  String? initialName,
  String? initialAutoName,
  double initialRadiusM = kInsightPlaceRadiusM,
  required List<InsightPlace> otherPlaces,
  String title = 'Detalhe do local',
  String hintText = 'Nome',
  String saveLabel = 'Salvar',
  String cancelLabel = 'Cancelar',
  required String barrierLabel,
  bool enableSuggest = false,
  Future<String?> Function()? onSuggest,
  String suggestManualPrompt =
      'Não foi possível obter o endereço. Digite manualmente.',
}) {
  return showFloatingSurface<PlaceDetailSave>(
    context: context,
    barrierLabel: barrierLabel,
    pageBuilder: (context, animation, secondaryAnimation) {
      return _PlaceDetailDialog(
        latitude: latitude,
        longitude: longitude,
        placeId: placeId,
        initialName: initialName,
        initialAutoName: initialAutoName,
        initialRadiusM: initialRadiusM,
        otherPlaces: otherPlaces,
        title: title,
        hintText: hintText,
        saveLabel: saveLabel,
        cancelLabel: cancelLabel,
        enableSuggest: enableSuggest,
        onSuggest: onSuggest,
        suggestManualPrompt: suggestManualPrompt,
      );
    },
  );
}

class _PlaceDetailDialog extends StatelessWidget {
  const _PlaceDetailDialog({
    required this.latitude,
    required this.longitude,
    this.placeId,
    this.initialName,
    this.initialAutoName,
    required this.initialRadiusM,
    required this.otherPlaces,
    required this.title,
    required this.hintText,
    required this.saveLabel,
    required this.cancelLabel,
    this.enableSuggest = false,
    this.onSuggest,
    required this.suggestManualPrompt,
  });

  final double latitude;
  final double longitude;
  final String? placeId;
  final String? initialName;
  final String? initialAutoName;
  final double initialRadiusM;
  final List<InsightPlace> otherPlaces;
  final String title;
  final String hintText;
  final String saveLabel;
  final String cancelLabel;
  final bool enableSuggest;
  final Future<String?> Function()? onSuggest;
  final String suggestManualPrompt;

  @override
  Widget build(BuildContext context) {
    // FloatingPanel bounds height and lifts the panel above the keyboard,
    // so the name field and the save row always stay reachable.
    return FloatingPanel(
      child: PlacesDetailBody(
        latitude: latitude,
        longitude: longitude,
        placeId: placeId,
        initialName: initialName,
        initialAutoName: initialAutoName,
        initialRadiusM: initialRadiusM,
        otherPlaces: otherPlaces,
        title: title,
        hintText: hintText,
        saveLabel: saveLabel,
        cancelLabel: cancelLabel,
        enableSuggest: enableSuggest,
        onSuggest: onSuggest,
        suggestManualPrompt: suggestManualPrompt,
        onSave: (name, radiusM, autoName) {
          Navigator.of(context).pop(
            PlaceDetailSave(name: name, radiusM: radiusM, autoName: autoName),
          );
        },
        onCancel: () => Navigator.of(context).pop(),
      ),
    );
  }
}
