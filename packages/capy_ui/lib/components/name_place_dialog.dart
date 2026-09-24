import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'floating_surface.dart';
import 'soft_action_tile.dart';

/// Asks for a place name in a modal dialog. Returns the trimmed name, or null if cancelled.
Future<String?> showNamePlaceDialog({
  required BuildContext context,
  required String title,
  required String hintText,
  required String saveLabel,
  required String cancelLabel,
  required String barrierLabel,
  String? initialName,
}) {
  return showFloatingSurface<String>(
    context: context,
    barrierLabel: barrierLabel,
    pageBuilder: (context, animation, secondaryAnimation) {
      return _NamePlaceDialog(
        title: title,
        hintText: hintText,
        saveLabel: saveLabel,
        cancelLabel: cancelLabel,
        initialName: initialName,
      );
    },
  );
}

class _NamePlaceDialog extends StatefulWidget {
  const _NamePlaceDialog({
    required this.title,
    required this.hintText,
    required this.saveLabel,
    required this.cancelLabel,
    this.initialName,
  });

  final String title;
  final String hintText;
  final String saveLabel;
  final String cancelLabel;
  final String? initialName;

  @override
  State<_NamePlaceDialog> createState() => _NamePlaceDialogState();
}

class _NamePlaceDialogState extends State<_NamePlaceDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final safePadding = MediaQuery.paddingOf(context);
    final available =
        MediaQuery.sizeOf(context).width -
        safePadding.horizontal -
        AppSpacing.x12;
    return Center(
      child: SizedBox(
        width: math.min(available, AppSizes.confirmDialogWidth),
        child: Material(
          color: colors.surface,
          borderRadius: AppRadii.xlRadius,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: AppSpacing.cardPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: AppText.cardTitle.copyWith(color: colors.ink),
                ),
                const SizedBox(height: AppSpacing.x4),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: AppText.body.copyWith(color: colors.ink),
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
                  ),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: AppSpacing.x6),
                Row(
                  children: [
                    Expanded(
                      child: SoftActionTile(
                        label: widget.cancelLabel,
                        centered: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    Expanded(
                      child: SoftActionTile(
                        label: widget.saveLabel,
                        centered: true,
                        onPressed: _save,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
