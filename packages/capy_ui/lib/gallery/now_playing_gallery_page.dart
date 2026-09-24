import 'package:flutter/material.dart';

import '../capy_ui.dart';

/// Calibration surface for [NowPlayingBar].
///
/// Demo copy only — this page never ships. It exists so the pill can be
/// judged on its own canvas, in more than one theme and width, without the
/// climate strip.
class NowPlayingGalleryPage extends StatefulWidget {
  const NowPlayingGalleryPage({super.key});

  @override
  State<NowPlayingGalleryPage> createState() => _NowPlayingGalleryPageState();
}

enum _NowPlayingState { playing, idle, muted, disabled }

class _NowPlayingGalleryPageState extends State<NowPlayingGalleryPage> {
  AppThemeId _themeId = AppThemeId.light;
  _NowPlayingState _state = _NowPlayingState.playing;
  int _volume = 12;
  int _track = 0;

  static const _tracks = <(String, String)>[
    ('Night Drive', 'Low Tide'),
    ('Coastal', 'June Harbour'),
    ('Second Shift', 'Red Platform'),
  ];

  static const _volumeMin = 0;
  static const _volumeMax = 30;

  static const _themes = <AppThemeId>[
    AppThemeId.light,
    AppThemeId.dark,
    AppThemeId.midnight,
    AppThemeId.tokyoNeon,
  ];

  String _stateName(_NowPlayingState state) => switch (state) {
    _NowPlayingState.playing => 'Playing',
    _NowPlayingState.idle => 'Idle',
    _NowPlayingState.muted => 'Muted',
    _NowPlayingState.disabled => 'No write',
  };

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.forId(_themeId),
      child: Builder(
        builder: (context) {
          final colors = AppThemeColors.of(context);
          final l10n =
              Localizations.of<CapyUiL10n>(context, CapyUiL10n) ??
              lookupCapyUiL10n(
                Localizations.maybeLocaleOf(context) ?? const Locale('en'),
              );
          return ColoredBox(
            key: const Key('now-playing-gallery-canvas'),
            color: colors.canvas,
            child: ListView(
              padding: AppSpacing.screenPadding,
              children: [
                Text(
                  'Now playing',
                  style: AppText.cardTitle.copyWith(color: colors.ink),
                ),
                const SizedBox(height: AppSpacing.x1),
                Text(
                  'Themed 64 px pill. Drag sideways for volume. Next track swaps the sleeve.',
                  style: AppText.body.copyWith(color: colors.inkMuted),
                ),
                const SizedBox(height: AppSpacing.x5),
                TrackSegmentedControl<AppThemeId>(
                  items: [
                    for (final id in _themes)
                      TabItem(value: id, label: appThemeName(id, l10n)),
                  ],
                  selected: _themeId,
                  onSelected: (id) => setState(() => _themeId = id),
                ),
                const SizedBox(height: AppSpacing.x3),
                TrackSegmentedControl<_NowPlayingState>(
                  items: [
                    for (final state in _NowPlayingState.values)
                      TabItem(value: state, label: _stateName(state)),
                  ],
                  selected: _state,
                  onSelected: (state) => setState(() {
                    _state = state;
                    if (state == _NowPlayingState.muted) _volume = _volumeMin;
                    if (state == _NowPlayingState.playing &&
                        _volume == _volumeMin) {
                      _volume = 12;
                    }
                  }),
                ),
                const SizedBox(height: AppSpacing.x6),
                _hero(colors),
                const SizedBox(height: AppSpacing.x6),
                _statesRow(),
                const SizedBox(height: AppSpacing.x6),
                _widthsRow(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _hero(AppThemeColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '64 px · $_volume / $_volumeMax',
          style: AppText.label.copyWith(color: colors.inkMuted),
        ),
        const SizedBox(height: AppSpacing.x2),
        _barFor(_state, artwork: true),
        const SizedBox(height: AppSpacing.x3),
        SoftActionTile(
          icon: Icons.skip_next,
          label: 'Next track',
          onPressed: () => setState(() {
            _track = (_track + 1) % _tracks.length;
            _state = _NowPlayingState.playing;
          }),
        ),
        const SizedBox(height: AppSpacing.x4),
        Text(
          'Long title',
          style: AppText.label.copyWith(color: colors.inkMuted),
        ),
        const SizedBox(height: AppSpacing.x2),
        NowPlayingBar(
          title: 'A title long enough to force the ellipsis on the pill',
          artist: 'A band name that also runs past the end of this row',
          isPlaying: true,
          idleLabel: 'Nothing playing',
          volume: _volume,
          volumeMin: _volumeMin,
          volumeMax: _volumeMax,
          artwork: _DemoArtwork(seed: _track + 2),
          onVolumeChanged: (next) => setState(() => _volume = next),
        ),
      ],
    );
  }

  Widget _statesRow() {
    return _Row(
      children: [
        for (final state in _NowPlayingState.values)
          Expanded(
            child: AppCard(
              title: _stateName(state),
              child: _barFor(state, artwork: state == _NowPlayingState.playing),
            ),
          ),
      ],
    );
  }

  Widget _widthsRow() {
    return _Row(
      children: [
        Expanded(
          flex: 2,
          child: AppCard(
            title: 'Wide',
            subtitle: 'Two-thirds',
            child: _barFor(_NowPlayingState.playing, artwork: true),
          ),
        ),
        Expanded(
          child: AppCard(
            title: 'Narrow',
            subtitle: 'One-third',
            child: _barFor(_NowPlayingState.playing, artwork: true),
          ),
        ),
      ],
    );
  }

  Widget _barFor(_NowPlayingState state, {required bool artwork}) {
    final playing = state == _NowPlayingState.playing;
    final idle = state == _NowPlayingState.idle;
    final muted = state == _NowPlayingState.muted;
    final track = _tracks[_track];
    return NowPlayingBar(
      title: idle ? null : (muted ? 'Engine Off' : track.$1),
      artist: idle ? null : (muted ? 'Cabin' : track.$2),
      isPlaying: playing,
      idleLabel: 'Nothing playing',
      volume: muted ? _volumeMin : _volume,
      volumeMin: _volumeMin,
      volumeMax: _volumeMax,
      artwork: artwork ? _DemoArtwork(seed: _track + 1) : null,
      onVolumeChanged: state == _NowPlayingState.disabled
          ? null
          : (next) => setState(() {
              _volume = next;
              if (next > _volumeMin && _state == _NowPlayingState.muted) {
                _state = _NowPlayingState.playing;
              }
            }),
    );
  }
}

/// Stand-in sleeve. A real caller passes album art; the gallery needs a
/// shape to judge against the type, not a downloaded image.
class _DemoArtwork extends StatelessWidget {
  const _DemoArtwork({required this.seed});

  final int seed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return ColoredBox(
      color: seed.isOdd ? colors.selectionFill : colors.controlHigh,
      child: Icon(
        Icons.album,
        color: seed.isOdd ? colors.onSelection : colors.inkMuted,
        size: AppSizes.iconLg,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.gridGutter),
            children[i],
          ],
        ],
      ),
    );
  }
}
