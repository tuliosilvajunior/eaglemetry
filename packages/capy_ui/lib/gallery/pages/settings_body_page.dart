import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SettingsBodyGalleryPage extends StatefulWidget {
  const SettingsBodyGalleryPage({super.key});

  @override
  State<SettingsBodyGalleryPage> createState() =>
      _SettingsBodyGalleryPageState();
}

class _SettingsBodyGalleryPageState extends State<SettingsBodyGalleryPage> {
  AppThemeId _themeId = AppThemeId.light;
  bool _reduceMotion = false;
  bool _allowKeyboard = true;
  SurfaceWidthClass _widthClass = SurfaceWidthClass.compact;

  SurfaceCapabilities get _capabilities => SurfaceCapabilities(
    widthClass: _widthClass,
    supportsSelection: _widthClass == SurfaceWidthClass.expanded,
    inputMode: _widthClass == SurfaceWidthClass.expanded
        ? SurfaceInputMode.rotary
        : SurfaceInputMode.touch,
    allowKeyboard: _allowKeyboard,
    density: _widthClass == SurfaceWidthClass.compact
        ? SurfaceDensity.compact
        : SurfaceDensity.comfortable,
  );

  // Fixed preview widths: phone, tablet (medium), head unit.
  static const _phoneWidth = 390.0;
  static const _tabletWidth = 720.0; // Medium: 600-839
  static const _carWidth = 960.0; // Scaled view of 1920, still expanded.

  SurfaceCapabilities _capabilitiesFor(SurfaceWidthClass widthClass) =>
      SurfaceCapabilities(
        widthClass: widthClass,
        supportsSelection: widthClass == SurfaceWidthClass.expanded,
        inputMode: widthClass == SurfaceWidthClass.expanded
            ? SurfaceInputMode.rotary
            : SurfaceInputMode.touch,
        allowKeyboard: _allowKeyboard,
        density: widthClass == SurfaceWidthClass.compact
            ? SurfaceDensity.compact
            : SurfaceDensity.comfortable,
      );

  Widget _previewFrame({
    required String label,
    required String subtitle,
    required double width,
    required SurfaceCapabilities capabilities,
  }) {
    final frameColors = AppThemeColors.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: frameColors.surface,
        borderRadius: AppRadii.mdRadius,
        border: Border.all(color: frameColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2,
            ),
            decoration: BoxDecoration(
              color: frameColors.control,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadii.md),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.label),
                Text(
                  subtitle,
                  style: AppText.caption.copyWith(color: frameColors.inkMuted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x3),
            child: SettingsBody(
              themeId: _themeId,
              onThemeChanged: (id) => setState(() => _themeId = id),
              reduceMotion: _reduceMotion,
              onReduceMotionChanged: (value) =>
                  setState(() => _reduceMotion = value),
              capabilities: capabilities,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.forId(_themeId),
      child: GalleryDemoPage(
        title: 'SettingsBody',
        summary:
            'Shared theme + toggles slices. Same body in car and phone, branched on SurfaceCapabilities. Compact is single column, medium/expanded is a 2-column section grid.',
        note:
            'Toggle allowKeyboard to see read-only TipBox. Toggle reduceMotion via shared row. Switch widthClass between compact/medium/expanded. Below: phone, tablet (medium), and head unit at fixed widths. Grid branches only on widthClass, never on isCar.',
        child: GalleryStack(
          children: [
            AppCard(
              title: 'Controls',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TrackSegmentedControl<SurfaceWidthClass>(
                    items: const [
                      TabItem(
                        value: SurfaceWidthClass.compact,
                        label: 'Compact',
                      ),
                      TabItem(value: SurfaceWidthClass.medium, label: 'Medium'),
                      TabItem(
                        value: SurfaceWidthClass.expanded,
                        label: 'Expanded',
                      ),
                    ],
                    selected: _widthClass,
                    onSelected: (value) => setState(() => _widthClass = value),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  SettingToggleRow(
                    label: 'Allow keyboard',
                    description:
                        'When off, theme picker and toggles are read-only with TipBox.',
                    value: _allowKeyboard,
                    onChanged: (value) =>
                        setState(() => _allowKeyboard = value),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  SettingToggleRow(
                    label: 'Reduce motion (via body)',
                    description:
                        'Shared toggle through SettingsBody. Respects allowKeyboard.',
                    value: _reduceMotion,
                    onChanged: (value) => setState(() => _reduceMotion = value),
                  ),
                  const SizedBox(height: AppSpacing.x2),
                  GalleryCaption(
                    'Current: ${_capabilities.widthClass.name}, '
                    'allowKeyboard=${_capabilities.allowKeyboard}, '
                    'reduceMotion=$_reduceMotion, '
                    'inputMode=${_capabilities.inputMode.name}',
                  ),
                ],
              ),
            ),
            // Live body at the selected widthClass (full gallery width).
            AppCard(
              title: 'Live body — ${_widthClass.name}',
              subtitle: _allowKeyboard ? 'Editable' : 'Read-only + TipBox',
              child: Builder(
                builder: (context) => SettingsBody(
                  themeId: _themeId,
                  onThemeChanged: (id) => setState(() => _themeId = id),
                  reduceMotion: _reduceMotion,
                  onReduceMotionChanged: (value) =>
                      setState(() => _reduceMotion = value),
                  capabilities: _capabilities,
                ),
              ),
            ),
            AppCard(
              title: 'Phone vs tablet vs head unit',
              subtitle: 'Fixed-width previews — compact/medium/expanded',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const GalleryCaption(
                    'Phone 390 px (compact, touch) single column · Tablet 720 px (medium) 2-col grid · Head unit 1920 px scaled to 960 px (expanded, rotary) 2-col grid. Same SettingsBody, different widthClass.',
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _previewFrame(
                          label: 'Phone — 390×800',
                          subtitle:
                              'compact · touch · allowKeyboard: $_allowKeyboard',
                          width: _phoneWidth,
                          capabilities: _capabilitiesFor(
                            SurfaceWidthClass.compact,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.gridGutter),
                        _previewFrame(
                          label: 'Tablet — 720×1024',
                          subtitle:
                              'medium · touch · allowKeyboard: $_allowKeyboard',
                          width: _tabletWidth,
                          capabilities: _capabilitiesFor(
                            SurfaceWidthClass.medium,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.gridGutter),
                        _previewFrame(
                          label: 'Head unit — 1920×1080',
                          subtitle:
                              'expanded · rotary · allowKeyboard: $_allowKeyboard',
                          width: _carWidth,
                          capabilities: _capabilitiesFor(
                            SurfaceWidthClass.expanded,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  GalleryCaption(
                    'The body reads capabilities.widthClass for layout (compact single column, medium/expanded 2-column grid via SettingsAdaptiveGrid) and allowKeyboard for editability. No isCar branch.',
                  ),
                ],
              ),
            ),
            AppCard(
              title: 'Live theme preview',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MetricValue(value: '202', unit: 'km', size: MetricSize.lg),
                  const SizedBox(height: AppSpacing.x3),
                  GalleryCaption(
                    'Theme $_themeId applies to this gallery page via Theme wrapper above.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
