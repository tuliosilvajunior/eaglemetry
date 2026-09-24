import 'package:flutter/material.dart';

import 'chart_motion_gallery_screen.dart';
import 'efficiency_gallery_screen.dart';
import 'gallery_scaffold.dart';
import 'now_playing_gallery_page.dart';
import 'pages/anchored_tooltip_page.dart';
import 'pages/app_card_page.dart';
import 'pages/app_journey_scaffold_page.dart';
import 'pages/breathing_warning_banner_page.dart';
import 'pages/capy_face_page.dart';
import 'pages/card_stage_page.dart';
import 'pages/category_menu_page.dart';
import 'pages/charge_session_summary_card_page.dart';
import 'pages/chart_pin_annotation_page.dart';
import 'pages/chart_tooltip_page.dart';
import 'pages/climate_control_card_page.dart';
import 'pages/climate_temperature_bar_page.dart';
import 'pages/compass_tape_page.dart';
import 'pages/confirm_dialog_page.dart';
import 'pages/cycle_bar_page.dart';
import 'pages/dropdown_field_page.dart';
import 'pages/energy_bar_chart_page.dart';
import 'pages/entrance_gate_page.dart';
import 'pages/icon_buttons_page.dart';
import 'pages/icon_value_grid_page.dart';
import 'pages/information_card_page.dart';
import 'pages/instant_readout_bar_page.dart';
import 'pages/limit_slider_page.dart';
import 'pages/metric_mosaic_page.dart';
import 'pages/metric_value_page.dart';
import 'pages/money_keypad_dialog_page.dart';
import 'pages/pill_tab_bar_page.dart';
import 'pages/route_map_card_page.dart';
import 'pages/magnitude_bars_page.dart';
import 'pages/segmented_donut_page.dart';
import 'pages/series_trace_page.dart';
import 'pages/share_bar_page.dart';
import 'pages/soc_span_bar_page.dart';
import 'pages/selectable_tile_page.dart';
import 'pages/setting_toggle_row_page.dart';
import 'pages/soft_action_tile_page.dart';
import 'pages/stat_column_page.dart';
import 'pages/status_badge_page.dart';
import 'pages/text_tab_bar_page.dart';
import 'pages/settings_blocks_page.dart';
import 'pages/settings_body_page.dart';
import 'pages/theme_picker_page.dart';
import 'pages/tilt_gauge_page.dart';
import 'pages/tip_box_page.dart';
import 'pages/track_segmented_control_page.dart';
import 'pages/trip_session_card_page.dart';
import 'pages/trips_body_page.dart';
import 'smoothness_gallery_screen.dart';

/// One component (or harness) the catalog can open.
class GalleryEntry {
  const GalleryEntry({
    required this.id,
    required this.name,
    required this.summary,
    required this.category,
    required this.builder,
  });

  /// Path segment, used as `/$id`.
  final String id;

  final String name;
  final String summary;
  final GalleryCategory category;
  final WidgetBuilder builder;
}

enum GalleryCategory {
  chrome('Chrome'),
  navigation('Navigation'),
  controls('Controls'),
  readouts('Readouts'),
  charts('Charts'),
  overlays('Overlays'),
  surfaces('Surfaces'),
  harnesses('Harnesses');

  const GalleryCategory(this.label);

  final String label;
}

Widget _page(Widget child) => child;

Widget _harness(Widget child) => GalleryHarnessShell(child: child);

/// Every public visual component, plus the three live harnesses that cannot
/// be judged from a static fixture.
final galleryEntries = <GalleryEntry>[
  GalleryEntry(
    id: 'app-card',
    name: 'AppCard',
    summary: 'Dashboard surface. No border, no shadow.',
    category: GalleryCategory.chrome,
    builder: (_) => _page(const AppCardGalleryPage()),
  ),
  GalleryEntry(
    id: 'capy-face',
    name: 'CapyFace',
    summary: 'The mascot, and the nine moods it wears.',
    category: GalleryCategory.chrome,
    builder: (_) => _page(const CapyFaceGalleryPage()),
  ),
  GalleryEntry(
    id: 'status-badge',
    name: 'StatusBadge',
    summary: 'Status light on a card title.',
    category: GalleryCategory.chrome,
    builder: (_) => _page(const StatusBadgeGalleryPage()),
  ),
  GalleryEntry(
    id: 'icon-buttons',
    name: 'Icon buttons',
    summary: 'Info glyph and square action.',
    category: GalleryCategory.chrome,
    builder: (_) => _page(const IconButtonsGalleryPage()),
  ),
  GalleryEntry(
    id: 'theme-picker',
    name: 'ThemePicker',
    summary: 'Catalogue of themes, judged by looking.',
    category: GalleryCategory.chrome,
    builder: (_) => _page(const ThemePickerGalleryPage()),
  ),
  GalleryEntry(
    id: 'app-journey-scaffold',
    name: 'AppJourneyScaffold',
    summary: 'Pills, canvas, footer, climate bezel.',
    category: GalleryCategory.chrome,
    builder: (_) => _page(const AppJourneyScaffoldGalleryPage()),
  ),
  GalleryEntry(
    id: 'pill-tab-bar',
    name: 'PillTabBar',
    summary: 'Page-level tabs. One sliding fill.',
    category: GalleryCategory.navigation,
    builder: (_) => _page(const PillTabBarGalleryPage()),
  ),
  GalleryEntry(
    id: 'text-tab-bar',
    name: 'TextTabBar',
    summary: 'In-card tabs. No fill.',
    category: GalleryCategory.navigation,
    builder: (_) => _page(const TextTabBarGalleryPage()),
  ),
  GalleryEntry(
    id: 'track-segmented-control',
    name: 'TrackSegmentedControl',
    summary: 'In-card filter on a grey track.',
    category: GalleryCategory.navigation,
    builder: (_) => _page(const TrackSegmentedControlGalleryPage()),
  ),
  GalleryEntry(
    id: 'category-menu',
    name: 'CategoryMenu',
    summary: 'Settings rail with search and detail.',
    category: GalleryCategory.navigation,
    builder: (_) => _page(const CategoryMenuGalleryPage()),
  ),
  GalleryEntry(
    id: 'limit-slider',
    name: 'LimitSlider',
    summary: 'Charge target on a 0–100 % pill.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const LimitSliderGalleryPage()),
  ),
  GalleryEntry(
    id: 'selectable-tile',
    name: 'SelectableTile',
    summary: 'Two-line preset. Inverse when picked.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const SelectableTileGalleryPage()),
  ),
  GalleryEntry(
    id: 'dropdown-field',
    name: 'DropdownField',
    summary: 'Width-matched modal option menu.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const DropdownFieldGalleryPage()),
  ),
  GalleryEntry(
    id: 'soft-action-tile',
    name: 'SoftActionTile',
    summary: 'Filled grey action row.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const SoftActionTileGalleryPage()),
  ),
  GalleryEntry(
    id: 'setting-toggle-row',
    name: 'SettingToggleRow',
    summary: 'Named setting. Amber means live.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const SettingToggleRowGalleryPage()),
  ),
  GalleryEntry(
    id: 'climate-control-card',
    name: 'ClimateControlCard',
    summary: 'Front-row HVAC. Bounds disable steppers.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const ClimateControlCardGalleryPage()),
  ),
  GalleryEntry(
    id: 'climate-temperature-bar',
    name: 'ClimateTemperatureBar',
    summary: 'Always-dark zone pills on the bezel.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const ClimateTemperatureBarGalleryPage()),
  ),
  GalleryEntry(
    id: 'cycle-bar',
    name: 'CycleBar',
    summary: 'One battery cycle as a static pill.',
    category: GalleryCategory.controls,
    builder: (_) => _page(const CycleBarGalleryPage()),
  ),
  GalleryEntry(
    id: 'soc-span-bar',
    name: 'SocSpanBar',
    summary: 'What one session did to the battery.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const SocSpanBarGalleryPage()),
  ),
  GalleryEntry(
    id: 'share-bar',
    name: 'ShareBar',
    summary: 'How a whole divides, as one pill.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const ShareBarGalleryPage()),
  ),
  GalleryEntry(
    id: 'magnitude-bars',
    name: 'MagnitudeBars',
    summary: 'Measured quantities on one scale.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const MagnitudeBarsGalleryPage()),
  ),
  GalleryEntry(
    id: 'series-trace',
    name: 'SeriesTrace',
    summary: 'One quantity across a session.',
    category: GalleryCategory.charts,
    builder: (_) => _page(const SeriesTraceGalleryPage()),
  ),
  GalleryEntry(
    id: 'metric-value',
    name: 'MetricValue',
    summary: 'Numeral and unit on one baseline.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const MetricValueGalleryPage()),
  ),
  GalleryEntry(
    id: 'metric-mosaic',
    name: 'MetricMosaic',
    summary: 'One hero, the rest packed around it.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const MetricMosaicGalleryPage()),
  ),
  GalleryEntry(
    id: 'stat-column',
    name: 'StatColumn',
    summary: 'Value, unit, caption. Stepper or pencil.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const StatColumnGalleryPage()),
  ),
  GalleryEntry(
    id: 'icon-value-grid',
    name: 'IconValueGrid',
    summary: 'Legend under a donut.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const IconValueGridGalleryPage()),
  ),
  GalleryEntry(
    id: 'instant-readout-bar',
    name: 'InstantReadoutBar',
    summary: 'Footer that cycles one live reading.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const InstantReadoutBarGalleryPage()),
  ),
  GalleryEntry(
    id: 'compass-tape',
    name: 'CompassTape',
    summary: 'Course under a fixed bar.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const CompassTapeGalleryPage()),
  ),
  GalleryEntry(
    id: 'tilt-gauge',
    name: 'TiltGauge',
    summary: 'Pitch and roll. Same value, two silhouettes.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const TiltGaugeGalleryPage()),
  ),
  GalleryEntry(
    id: 'tip-box',
    name: 'TipBox',
    summary: 'Recessed note. Not tappable.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const TipBoxGalleryPage()),
  ),
  GalleryEntry(
    id: 'breathing-warning-banner',
    name: 'BreathingWarningBanner',
    summary: 'Fixed-height status with a breathing icon.',
    category: GalleryCategory.readouts,
    builder: (_) => _page(const BreathingWarningBannerGalleryPage()),
  ),
  GalleryEntry(
    id: 'energy-bar-chart',
    name: 'EnergyBarChart',
    summary: 'Drive and charge bars. Rebuckets on Add bar.',
    category: GalleryCategory.charts,
    builder: (_) => _page(const EnergyBarChartGalleryPage()),
  ),
  GalleryEntry(
    id: 'segmented-donut',
    name: 'SegmentedDonut',
    summary: 'Breakdown, drive split, and meter.',
    category: GalleryCategory.charts,
    builder: (_) => _page(const SegmentedDonutGalleryPage()),
  ),
  GalleryEntry(
    id: 'chart-tooltip',
    name: 'ChartTooltip',
    summary: 'Callout bubble. Every caret side.',
    category: GalleryCategory.charts,
    builder: (_) => _page(const ChartTooltipGalleryPage()),
  ),
  GalleryEntry(
    id: 'chart-pin-annotation',
    name: 'ChartPinAnnotation',
    summary: 'Rule and dot on a pinned reading.',
    category: GalleryCategory.charts,
    builder: (_) => _page(const ChartPinAnnotationGalleryPage()),
  ),
  GalleryEntry(
    id: 'charge-session-summary-card',
    name: 'ChargeSessionSummaryCard',
    summary: 'Last charge with battery and climate.',
    category: GalleryCategory.charts,
    builder: (_) => _page(const ChargeSessionSummaryCardGalleryPage()),
  ),
  GalleryEntry(
    id: 'efficiency-card',
    name: 'EfficiencyCard',
    summary: 'Live demand, cost, and smoothness pill.',
    category: GalleryCategory.charts,
    builder: (_) => _harness(const EfficiencyGalleryScreen()),
  ),
  GalleryEntry(
    id: 'anchored-tooltip',
    name: 'AnchoredTooltip',
    summary: 'Anchor, route, and selected trigger.',
    category: GalleryCategory.overlays,
    builder: (_) => _page(const AnchoredTooltipGalleryPage()),
  ),
  GalleryEntry(
    id: 'information-card',
    name: 'InformationCard',
    summary: 'Muted block inside a tooltip panel.',
    category: GalleryCategory.overlays,
    builder: (_) => _page(const InformationCardGalleryPage()),
  ),
  GalleryEntry(
    id: 'confirm-dialog',
    name: 'ConfirmDialog',
    summary: 'Ask before an irreversible action.',
    category: GalleryCategory.overlays,
    builder: (_) => _page(const ConfirmDialogGalleryPage()),
  ),
  GalleryEntry(
    id: 'money-keypad-dialog',
    name: 'MoneyKeypadDialog',
    summary: 'Terminal digits. Writes only on confirm.',
    category: GalleryCategory.overlays,
    builder: (_) => _page(const MoneyKeypadDialogGalleryPage()),
  ),
  GalleryEntry(
    id: 'card-stage',
    name: 'ExpandableCardStage',
    summary: 'Drag to fullscreen. Buttons resize.',
    category: GalleryCategory.surfaces,
    builder: (_) => _page(const CardStageGalleryPage()),
  ),
  GalleryEntry(
    id: 'route-map-card',
    name: 'RouteMapCard',
    summary: 'Recorded path. Colour relative to this drive.',
    category: GalleryCategory.surfaces,
    builder: (_) => _page(const RouteMapCardGalleryPage()),
  ),
  GalleryEntry(
    id: 'now-playing',
    name: 'Now playing',
    summary: '64 px pill. Themes, widths, states.',
    category: GalleryCategory.surfaces,
    builder: (_) => _harness(const NowPlayingGalleryPage()),
  ),
  GalleryEntry(
    id: 'entrance-gate',
    name: 'EntranceGate',
    summary: 'Mounts a subtree so its entrance can play.',
    category: GalleryCategory.surfaces,
    builder: (_) => _page(const EntranceGateGalleryPage()),
  ),
  GalleryEntry(
    id: 'settings-blocks',
    name: 'SettingsBlocks',
    summary:
        'Scaffolding blocks: SettingsEntry, SettingsRows, SettingsSections, SettingsAdaptiveGrid.',
    category: GalleryCategory.surfaces,
    builder: (_) => _page(const SettingsBlocksGalleryPage()),
  ),
  GalleryEntry(
    id: 'settings-body',
    name: 'SettingsBody',
    summary: 'Shared theme slice, same on both surfaces.',
    category: GalleryCategory.surfaces,
    builder: (_) => _page(const SettingsBodyGalleryPage()),
  ),
  GalleryEntry(
    id: 'trip-session-card',
    name: 'TripSessionCard',
    summary: 'Adaptive trip card with route map banner or thumbnail.',
    category: GalleryCategory.surfaces,
    builder: (_) => _page(const TripSessionCardGalleryPage()),
  ),
  GalleryEntry(
    id: 'trips-body',
    name: 'TripsBody',
    summary: 'Shared day-grouped trip history with filter bar.',
    category: GalleryCategory.surfaces,
    builder: (_) => _page(const TripsBodyGalleryPage()),
  ),
  GalleryEntry(
    id: 'chart-motion',
    name: 'Chart motion',
    summary: 'EnergyBarChart while its numbers change.',
    category: GalleryCategory.harnesses,
    builder: (_) => _harness(const ChartMotionGalleryScreen()),
  ),
  GalleryEntry(
    id: 'smoothness',
    name: 'Driving smoothness',
    summary: 'The pill under a simulated car.',
    category: GalleryCategory.harnesses,
    builder: (_) => _harness(const SmoothnessGalleryScreen()),
  ),
];

GalleryEntry? galleryEntryById(String id) {
  for (final entry in galleryEntries) {
    if (entry.id == id) return entry;
  }
  return null;
}

List<GalleryEntry> galleryEntriesIn(GalleryCategory category) => [
  for (final entry in galleryEntries)
    if (entry.category == category) entry,
];
