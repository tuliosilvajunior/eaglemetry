import 'package:flutter/material.dart';

import '../capy_ui.dart';
import 'gallery_catalog.dart';

/// Catalog of every `capy_ui` component. Each tile opens that component's
/// own demonstration page.
class GalleryHome extends StatefulWidget {
  const GalleryHome({super.key});

  @override
  State<GalleryHome> createState() => _GalleryHomeState();
}

class _GalleryHomeState extends State<GalleryHome> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final needle = _query.trim().toLowerCase();
    final visible = [
      for (final entry in galleryEntries)
        if (needle.isEmpty ||
            entry.name.toLowerCase().contains(needle) ||
            entry.summary.toLowerCase().contains(needle) ||
            entry.category.label.toLowerCase().contains(needle))
          entry,
    ];

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'capy_ui gallery',
                style: AppText.cardTitle.copyWith(color: colors.ink),
              ),
              const SizedBox(height: AppSpacing.x2),
              Text(
                'One page per component. Open a tile to see its states and, '
                'where the component is driven by input, the controls that '
                'change it.',
                style: AppText.body.copyWith(color: colors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.x5),
              TextField(
                onChanged: (value) => setState(() => _query = value),
                style: AppText.body.copyWith(color: colors.ink),
                decoration: InputDecoration(
                  hintText: 'Filter by name or category',
                  hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
                  filled: true,
                  fillColor: colors.control,
                  border: OutlineInputBorder(
                    borderRadius: AppRadii.mdRadius,
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x4,
                    vertical: AppSpacing.x4,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.x2),
              Text(
                '${visible.length} of ${galleryEntries.length}',
                style: AppText.caption.copyWith(color: colors.inkSubtle),
              ),
              const SizedBox(height: AppSpacing.x5),
              for (final category in GalleryCategory.values)
                ..._section(context, category, visible),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.x6),
                  child: Text(
                    'No component matches that filter.',
                    style: AppText.body.copyWith(color: colors.inkMuted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _section(
    BuildContext context,
    GalleryCategory category,
    List<GalleryEntry> visible,
  ) {
    final items = [
      for (final entry in visible)
        if (entry.category == category) entry,
    ];
    if (items.isEmpty) return const [];
    final colors = AppThemeColors.of(context);
    return [
      Padding(
        padding: const EdgeInsets.only(
          top: AppSpacing.x4,
          bottom: AppSpacing.x3,
        ),
        child: Text(
          category.label,
          style: AppText.label.copyWith(color: colors.inkMuted),
        ),
      ),
      Wrap(
        spacing: AppSpacing.gridGutter,
        runSpacing: AppSpacing.gridGutter,
        children: [for (final entry in items) _CatalogTile(entry: entry)],
      ),
    ];
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({required this.entry});

  final GalleryEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return SizedBox(
      width: 280,
      child: Material(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
        child: InkWell(
          borderRadius: AppRadii.mdRadius,
          onTap: () => Navigator.of(context).pushNamed('/${entry.id}'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSizes.presetTileHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4,
                vertical: AppSpacing.x3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    entry.name,
                    style: AppText.tabLabel.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    entry.summary,
                    style: AppText.caption.copyWith(color: colors.inkMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
