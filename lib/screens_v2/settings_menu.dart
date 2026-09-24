import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'settings/charge_pane.dart';
import 'settings/data_pane.dart';
import 'settings/developer_pane.dart';
import 'settings/displays_pane.dart';
import 'settings/system_pane.dart';

/// The categories of the floating settings menu.
///
/// Grouped by what the user is trying to do, not by which controller owns the
/// value: Displays is what the app looks like, Charge is how charging behaves,
/// Data is what it records and what becomes of it, System is what gets updated
/// under it, and Developer is everything that only matters while the app is being built.
enum SettingsCategory { displays, charge, data, system, developer }

/// Opens the settings menu over the current screen.
///
/// The caller supplies nothing but the context: every pane reaches its own
/// controller or `TelemetryApi`, so the shell does not carry settings state it
/// never displays.
Future<void> showSettingsMenu(BuildContext context) {
  final loc = AppLocalizations.of(context)!;
  return showCategoryMenu<SettingsCategory>(
    context: context,
    barrierLabel: loc.v2SettingsClose,
    initialSelected: SettingsCategory.displays,
    search: CategoryMenuSearch(
      hint: loc.v2SettingsSearch,
      emptyLabel: loc.v2SettingsSearchEmpty,
    ),
    groups: [
      CategoryMenuGroup([
        CategoryMenuEntry(
          value: SettingsCategory.displays,
          label: loc.v2SettingsDisplays,
          icon: Icons.tv,
        ),
        CategoryMenuEntry(
          value: SettingsCategory.charge,
          label: loc.v2SettingsCharge,
          icon: Icons.bolt,
        ),
        CategoryMenuEntry(
          value: SettingsCategory.data,
          label: loc.v2SettingsData,
          icon: Icons.storage,
        ),
        CategoryMenuEntry(
          value: SettingsCategory.system,
          label: loc.v2SettingsSystem,
          icon: Icons.memory,
        ),
      ]),
      // Its own group, behind a rule: everything above is for whoever drives
      // the car, and this is not.
      CategoryMenuGroup([
        CategoryMenuEntry(
          value: SettingsCategory.developer,
          label: loc.v2SettingsDeveloper,
          icon: Icons.code,
        ),
      ]),
    ],
    detailBuilder: (context, category) =>
        SettingsMenuDetail(category: category),
  );
}

/// The right-hand pane of the settings menu.
///
/// A thin dispatch: each category is a pane of its own, holding its own async
/// state, because a single state object for all of them would load the app
/// updater to show a theme switch.
class SettingsMenuDetail extends StatelessWidget {
  const SettingsMenuDetail({required this.category, super.key});

  final SettingsCategory category;

  @override
  Widget build(BuildContext context) {
    return switch (category) {
      SettingsCategory.displays => const DisplaysPane(),
      SettingsCategory.charge => const ChargePane(),
      SettingsCategory.data => const DataPane(),
      SettingsCategory.system => const SystemPane(),
      SettingsCategory.developer => const DeveloperPane(),
    };
  }
}
