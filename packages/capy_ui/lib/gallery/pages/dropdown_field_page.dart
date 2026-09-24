import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class DropdownFieldGalleryPage extends StatefulWidget {
  const DropdownFieldGalleryPage({super.key});

  @override
  State<DropdownFieldGalleryPage> createState() =>
      _DropdownFieldGalleryPageState();
}

class _DropdownFieldGalleryPageState extends State<DropdownFieldGalleryPage> {
  String _scope = 'current';
  final String _locked = 'charge';

  static const _options = [
    DropdownOption(value: 'current', label: 'Current drive'),
    DropdownOption(value: 'previous', label: 'Previous drive'),
    DropdownOption(value: 'charge', label: 'Since last charge'),
  ];

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'DropdownField',
      summary:
          'Controlled selector with a modal menu that matches the field '
          'width.',
      note:
          'The field stays inverse while the menu is open. A new choice '
          'updates the field when the reverse fade starts.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Live',
            subtitle: _options.firstWhere((o) => o.value == _scope).label,
            child: DropdownField<String>(
              value: _scope,
              options: _options,
              onChanged: (value) => setState(() => _scope = value),
              barrierLabel: 'Close drive range menu',
            ),
          ),
          AppCard(
            title: 'Disabled',
            subtitle: 'onChanged is null',
            child: DropdownField<String>(
              value: _locked,
              options: _options,
              onChanged: null,
              barrierLabel: 'Close drive range menu',
            ),
          ),
          AppCard(
            title: 'Fixed width',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownField<String>(
                  width: 280,
                  value: _scope,
                  options: _options,
                  onChanged: (value) => setState(() => _scope = value),
                  barrierLabel: 'Close drive range menu',
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'Leave width null to fill the parent. A fixed width is for '
                  'a toolbar, not a card body.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
