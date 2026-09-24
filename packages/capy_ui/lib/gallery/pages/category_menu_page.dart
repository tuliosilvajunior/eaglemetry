import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class CategoryMenuGalleryPage extends StatefulWidget {
  const CategoryMenuGalleryPage({super.key});

  @override
  State<CategoryMenuGalleryPage> createState() =>
      _CategoryMenuGalleryPageState();
}

class _CategoryMenuGalleryPageState extends State<CategoryMenuGalleryPage> {
  String _last = 'displays';
  int _appearance = 1;

  static const _groups = [
    CategoryMenuGroup<String>([
      CategoryMenuEntry(
        value: 'guide',
        label: "Owner's guide",
        icon: Icons.menu_book,
      ),
    ]),
    CategoryMenuGroup<String>([
      CategoryMenuEntry(
        value: 'autonomy',
        label: 'Autonomy',
        icon: Icons.battery_charging_full,
      ),
      CategoryMenuEntry(value: 'displays', label: 'Displays', icon: Icons.tv),
      CategoryMenuEntry(
        value: 'lighting',
        label: 'Lighting',
        icon: Icons.lightbulb,
      ),
      CategoryMenuEntry(value: 'access', label: 'Access', icon: Icons.lock),
      CategoryMenuEntry(
        value: 'mirrors',
        label: 'Mirrors and steering wheel',
        icon: Icons.airline_seat_recline_normal,
      ),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'CategoryMenu',
      summary:
          'Full-screen settings rail with grouped entries, search, and '
          'a detail pane.',
      note:
          'A group is the only separator in the rail. Search filters by '
          'label. The last selected category stays selected when you reopen.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Open the menu',
            subtitle: 'Last selected: $_last',
            child: SoftActionTile(
              icon: Icons.tune,
              label: 'Open vehicle settings',
              onPressed: () => showCategoryMenu<String>(
                context: context,
                groups: _groups,
                initialSelected: _last,
                onSelected: (value) => setState(() => _last = value),
                barrierLabel: 'Close vehicle settings',
                search: const CategoryMenuSearch(
                  hint: 'Search',
                  emptyLabel: 'No category matches your search.',
                ),
                detailBuilder: (context, selected) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected,
                        style: AppText.cardTitle.copyWith(
                          color: AppThemeColors.of(context).ink,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.x4),
                      if (selected == 'displays')
                        TrackSegmentedControl<int>(
                          items: const [
                            TabItem(value: 0, label: 'Light'),
                            TabItem(value: 1, label: 'Dark'),
                            TabItem(value: 2, label: 'Auto'),
                          ],
                          selected: _appearance,
                          onSelected: (value) =>
                              setState(() => _appearance = value),
                        )
                      else
                        const GalleryCaption(
                          'A real pane would render the settings for this '
                          'category here.',
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
