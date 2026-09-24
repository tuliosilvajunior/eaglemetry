/// Shared v2 design system for the car app and the companion app.
///
/// Coexists with the legacy car-app `lib/design_system/` (`AutomotiveDS`)
/// rather than replacing it in place: screens migrate one at a time, and a
/// legacy widget is deleted once its last usage is gone. Import this barrel,
/// not the individual token or component files.
///
/// The rules these components encode are documented in
/// `packages/capy_ui/DESIGN.md`.
library;

export 'app_theme.dart';
export 'components/anchored_tooltip.dart';
export 'components/app_card.dart';
export 'components/app_journey_scaffold.dart';
export 'components/breathing_warning_banner.dart';
export 'components/capy_face.dart';
export 'components/card_stage.dart';
export 'components/category_menu.dart';
export 'components/card_stage_controller.dart';
export 'components/card_stage_resize.dart';
export 'components/chart_pin_annotation.dart';
export 'components/chart_tooltip.dart';
export 'components/charge_session_summary_card.dart';
export 'components/charging_amperage_dialog.dart';
export 'components/climate_control_card.dart';
export 'components/climate_temperature_bar.dart';
export 'components/now_playing_bar.dart';
export 'components/compass_tape.dart';
export 'components/confirm_dialog.dart';
export 'components/cycle_bar.dart';
export 'components/floating_surface.dart';
export 'components/dropdown_field.dart';
export 'components/efficiency_card.dart';
export 'components/efficiency_chart.dart';
export 'components/energy_bar_chart.dart';
export 'components/entrance_gate.dart';
export 'components/icon_buttons.dart';
export 'components/icon_value_grid.dart';
export 'components/information_card.dart';
export 'components/instant_readout_bar.dart';
export 'components/limit_slider.dart';
export 'components/magnitude_bars.dart';
export 'components/material_symbol_icons.dart';
export 'components/metric_mosaic.dart';
export 'components/metric_value.dart';
export 'components/money_keypad_dialog.dart';
export 'components/name_place_dialog.dart';
export 'components/pill_tab_bar.dart';
export 'components/route_map_card.dart';
export 'components/route_preview_map.dart';
export 'components/segmented_donut.dart';
export 'components/series_trace.dart';
export 'components/setting_toggle_row.dart';
export 'components/selectable_tile.dart';
export 'components/share_bar.dart';
export 'components/soc_span_bar.dart';
export 'components/soft_action_tile.dart';
export 'components/stat_column.dart';
export 'components/status_badge.dart';
export 'components/sync_progress_bar.dart';
export 'components/text_tab_bar.dart';
export 'components/theme_picker.dart';
export 'components/tilt_gauge.dart';
export 'components/tip_box.dart';
export 'components/track_segmented_control.dart';
export 'components/trip_session_card.dart';
export 'tokens/app_colors.dart';
export 'tokens/app_palettes.dart';
export 'tokens/app_spacing.dart';
export 'tokens/chart_bar_profile.dart';
export 'tokens/app_typography.dart';
export 'bodies/surface_capabilities.dart';
export 'bodies/settings_source.dart';
export 'bodies/settings_body_controller.dart';
export 'bodies/settings_body.dart';
export 'bodies/places_body.dart';
export 'bodies/places_detail_body.dart';
export 'bodies/places_merge_body.dart';
export 'bodies/trips_body.dart';
export 'bodies/app_theme_name.dart';
export 'components/day_section_header.dart';
export 'components/place_detail_dialog.dart';
export 'components/place_merge_dialog.dart';
export 'components/trips_filter_bar.dart';
export 'components/settings_blocks.dart';
export 'l10n/capy_ui_localizations.dart';

/// Pub package name. Pass this to [Image.asset] and [FontLoader] so assets
/// resolve from this package rather than from the host app.
const capyUiPackage = 'capy_ui';
