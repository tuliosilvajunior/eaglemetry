import 'package:flutter/material.dart';

/// Stable semantic colors for the `capy_ui` design system.
///
/// Unlike [AutomotiveColors] in `lib/design_system/`, these semantic values are
/// plain constants. The green and amber data ramps do not change with
/// brightness. Neutral surface and content colors resolve through
/// [AppThemeColors].
///
/// Color roles are deliberately kept apart, because collapsing them is what
/// makes an energy dashboard read as noisy:
///
/// * [selectionFill] (near-black) means *the user picked this*. It also serves
///   as a reference overlay on charts (the power curve drawn over the bars),
///   but it is never one of the categorical series colors.
/// * [energyDraw] (amber) means *energy spent*, [energyGain] (green) means
///   *energy recovered or delivered*. That pairing is the spine of the whole
///   dashboard: consumption bars are amber, regen bars are green, and the
///   charge meters are green because charging is a gain.
///
/// Neither series color is ever used for a selection state.
abstract final class AppColors {
  /// Fully transparent fill for animated control state transitions.
  static const transparent = Color(0x00000000);

  /// Page background behind the cards. Intentionally off-white so that a
  /// [surface] card separates by contrast alone, with no border or shadow.
  static const canvas = Color(0xFFEFEFED);

  /// Card background.
  static const surface = Color(0xFFFFFFFF);

  /// Filled background for controls resting on a [surface] card: action rows,
  /// preset tiles, unselected segments.
  static const control = Color(0xFFEBEBEB);

  /// [control] under press/hover.
  static const controlHigh = Color(0xFFE0E0DE);

  /// Backdrop behind a floating modal surface. It keeps enough of the page
  /// visible to preserve context without competing with the active control.
  static const modalScrim = Color(0x330D0D0D);

  /// Inactive portion of a track (slider, meter) on a [surface] card.
  static const track = Color(0xFFE3E3E1);

  /// Hairline for the rare case a real separator is needed. Prefer separating
  /// with surface contrast instead.
  static const divider = Color(0xFFDEDEDC);

  /// Primary text and iconography.
  static const ink = Color(0xFF0D0D0D);

  /// Secondary text: supporting lines under a metric, unit captions.
  static const inkMuted = Color(0xFF6B6B6B);

  /// Tertiary text: inactive tab labels, disabled glyphs.
  static const inkSubtle = Color(0xFF9A9A9A);

  /// Fill for the selected/active state of a control.
  static const selectionFill = Color(0xFF262626);

  /// Content resting on [selectionFill].
  static const onSelection = Color(0xFFFFFFFF);

  // --- Data series ---------------------------------------------------------
  // Each series is a ramp, not a single color: the donut breaks a series into
  // sub-arcs and the bars stack a base segment, both of which need tints of
  // the same hue rather than a different hue.

  /// Energy recovered or delivered: regen bars, charge progress fills, the
  /// charge-session donut arc.
  static const energyGain = Color(0xFF6DC24B);

  static const energyGainSoft = Color(0xFFB6E0A0);

  static const energyGainSubtle = Color(0xFFDCF0D2);

  /// Energy spent: consumption bars, the drive-session donut arc.
  static const energyDraw = Color(0xFFEFA83A);

  static const energyDrawSoft = Color(0xFFF6D69B);

  static const energyDrawSubtle = Color(0xFFFAEAC9);

  static const warning = Color(0xFFE8A33D);

  static const critical = Color(0xFFD8493C);

  /// Focus ring for keyboard/rotary traversal.
  static const focus = Color(0xFF3B8FD6);

  // --- Inverse surface -----------------------------------------------------

  /// Dark floating surface: chart tooltips, and anything else that has to read
  /// on top of both a card and a data series.
  static const inverseSurface = Color(0xFF1F1F1F);

  static const onInverseSurface = Color(0xFFFFFFFF);

  /// Muted text inside an [inverseSurface] tooltip (the timestamp line).
  static const onInverseSurfaceMuted = Color(0xFFBFBFBF);

  // --- Climate quick-adjust bar ---------------------------------------------
  // Fixed, non-adaptive colors for `ClimateTemperatureBar`. The bar reads
  // these `AppColors` constants directly rather than `AppThemeColors.of
  // (context)`, which is what keeps it identical across every theme — it
  // mirrors the reference head unit's own always-dark climate strip, not the
  // app's chosen theme.

  /// The bar's background, and the bezel the app is inset into while the bar
  /// is shown — see `AppJourneyScaffold.staticBar`.
  ///
  /// One constant for both on purpose. On the reference head unit the strip is
  /// not a bar laid over the app; it is a hole in the app, and what shows
  /// through it is the same field that frames every edge. Give the two
  /// separate values and the bar reads as a panel sitting on the frame instead
  /// of being part of it.
  static const climateBarSurface = Color(0xFF141414);

  /// One zone's pill, floating on [climateBarSurface]. Lifted off the bezel
  /// rather than cut into it, because a pill is a control and the bezel is
  /// not.
  static const climatePillSurface = Color(0xFF2E2E2E);

  /// The reading, its fan glyph and the mode line under them.
  ///
  /// Plain white, and bold. The two chevrons beside it are the only coloured
  /// things on the pill: they carry the direction, so the number does not have
  /// to carry it as well — a tinted reading would read as a warning about the
  /// temperature rather than as the temperature.
  static const climateBarOnSurface = Color(0xFFFFFFFF);

  /// Secondary glyphs on the bar.
  static const climateBarOnSurfaceMuted = Color(0xFFB5B5B5);

  /// The decrease chevron. Cool, against [climateBarWarm] on the other end.
  static const climateBarCool = Color(0xFF3B82F6);

  /// The increase chevron. A warm accent distinct from [critical]: this marks
  /// a normal affirmative action (make it warmer), not a fault.
  static const climateBarWarm = Color(0xFFE8503A);
}

/// The two data hues, and the three alert colors that ride with them.
///
/// This is the part of a theme that carries *meaning*: [gain] is energy
/// recovered or delivered, [draw] is energy spent. A theme may change the hues
/// — that is what the expressive themes are for — but it may never make the
/// two hard to tell apart, and it may never swap their roles. Every reader in
/// the app asks for `gain` or `draw` by name, so a theme that reversed them
/// would relabel every chart in the app at once.
///
/// [soft] and [subtle] are the paler steps of the same hue. They exist because
/// the donut breaks a series into sub-arcs and the bars stack a base segment:
/// both need a tint of the hue, never a different hue.
@immutable
class AppEnergyRamp {
  const AppEnergyRamp({
    required this.gain,
    required this.gainSoft,
    required this.gainSubtle,
    required this.draw,
    required this.drawSoft,
    required this.drawSubtle,
    required this.warning,
    required this.critical,
    required this.focus,
  });

  /// The reference ramp: green for recovered, amber for spent. Every restrained
  /// theme uses it, so those six themes differ in their neutrals alone.
  static const standard = AppEnergyRamp(
    gain: AppColors.energyGain,
    gainSoft: AppColors.energyGainSoft,
    gainSubtle: AppColors.energyGainSubtle,
    draw: AppColors.energyDraw,
    drawSoft: AppColors.energyDrawSoft,
    drawSubtle: AppColors.energyDrawSubtle,
    warning: AppColors.warning,
    critical: AppColors.critical,
    focus: AppColors.focus,
  );

  final Color gain;
  final Color gainSoft;
  final Color gainSubtle;
  final Color draw;
  final Color drawSoft;
  final Color drawSubtle;
  final Color warning;
  final Color critical;
  final Color focus;

  static AppEnergyRamp lerp(AppEnergyRamp a, AppEnergyRamp b, double t) =>
      AppEnergyRamp(
        gain: Color.lerp(a.gain, b.gain, t)!,
        gainSoft: Color.lerp(a.gainSoft, b.gainSoft, t)!,
        gainSubtle: Color.lerp(a.gainSubtle, b.gainSubtle, t)!,
        draw: Color.lerp(a.draw, b.draw, t)!,
        drawSoft: Color.lerp(a.drawSoft, b.drawSoft, t)!,
        drawSubtle: Color.lerp(a.drawSubtle, b.drawSubtle, t)!,
        warning: Color.lerp(a.warning, b.warning, t)!,
        critical: Color.lerp(a.critical, b.critical, t)!,
        focus: Color.lerp(a.focus, b.focus, t)!,
      );
}

/// Brightness-dependent neutral colors for the replacement UI.
///
/// Use [of] in widgets. The light constants in [AppColors] remain available
/// for semantic defaults and painter APIs that are overridden at build time.
@immutable
class AppThemeColors extends ThemeExtension<AppThemeColors> {
  const AppThemeColors({
    required this.canvas,
    required this.surface,
    required this.control,
    required this.controlHigh,
    required this.modalScrim,
    required this.track,
    required this.divider,
    required this.ink,
    required this.inkMuted,
    required this.inkSubtle,
    required this.selectionFill,
    required this.onSelection,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.onInverseSurfaceMuted,
    required this.chartGrid,
    required this.chartAxisLabel,
    required this.chartProjected,
    required this.chartHeld,
    required this.chartNowMarker,
    required this.chartOverlay,
    this.energy = AppEnergyRamp.standard,
  });

  static const light = AppThemeColors(
    canvas: AppColors.canvas,
    surface: AppColors.surface,
    control: AppColors.control,
    controlHigh: AppColors.controlHigh,
    modalScrim: AppColors.modalScrim,
    track: AppColors.track,
    divider: AppColors.divider,
    ink: AppColors.ink,
    inkMuted: AppColors.inkMuted,
    inkSubtle: AppColors.inkSubtle,
    selectionFill: AppColors.selectionFill,
    onSelection: AppColors.onSelection,
    inverseSurface: AppColors.inverseSurface,
    onInverseSurface: AppColors.onInverseSurface,
    onInverseSurfaceMuted: AppColors.onInverseSurfaceMuted,
    chartGrid: AppChartColors.grid,
    chartAxisLabel: AppChartColors.axisLabel,
    chartProjected: AppChartColors.projected,
    chartHeld: AppChartColors.held,
    chartNowMarker: AppChartColors.nowMarker,
    chartOverlay: AppChartColors.overlay,
  );

  /// Blue-petrol surfaces derived from the supplied in-vehicle reference.
  /// Energy green and amber remain in [AppColors] and do not change.
  static const dark = AppThemeColors(
    canvas: Color(0xFF17323E),
    surface: Color(0xFF294854),
    control: Color(0xFF3A5964),
    controlHigh: Color(0xFF496773),
    modalScrim: Color(0x99081419),
    track: Color(0xFF466570),
    divider: Color(0xFF5B7680),
    ink: Color(0xFFF7F7F0),
    inkMuted: Color(0xFFD2DDDA),
    inkSubtle: Color(0xFF9EB2B1),
    selectionFill: Color(0xFFD7E8E5),
    onSelection: Color(0xFF17313B),
    inverseSurface: Color(0xFF0F252E),
    onInverseSurface: Color(0xFFF7F7F0),
    onInverseSurfaceMuted: Color(0xFFB9C9C7),
    chartGrid: Color(0xFF58717A),
    chartAxisLabel: Color(0xFFB2C1BF),
    chartProjected: Color(0xFF3B5965),
    chartHeld: Color(0xFF56737D),
    chartNowMarker: Color(0xFF708992),
    chartOverlay: Color(0xFFF7F7F0),
  );

  /// Near-black cabin view. The canvas is not pure black: a card has to
  /// separate from the page by contrast alone, and nothing is darker than
  /// black to separate against.
  static const midnight = AppThemeColors(
    canvas: Color(0xFF060606),
    surface: Color(0xFF151515),
    control: Color(0xFF232323),
    controlHigh: Color(0xFF2F2F2F),
    modalScrim: Color(0xB3000000),
    track: Color(0xFF2A2A2A),
    divider: Color(0xFF333333),
    ink: Color(0xFFF2F2F2),
    inkMuted: Color(0xFFAFAFAF),
    inkSubtle: Color(0xFF7A7A7A),
    selectionFill: Color(0xFFE8E8E8),
    onSelection: Color(0xFF0A0A0A),
    inverseSurface: Color(0xFF262626),
    onInverseSurface: Color(0xFFF7F7F7),
    onInverseSurfaceMuted: Color(0xFFB5B5B5),
    chartGrid: Color(0xFF2C2C2C),
    chartAxisLabel: Color(0xFF8F8F8F),
    chartProjected: Color(0xFF242424),
    chartHeld: Color(0xFF3A3A3A),
    chartNowMarker: Color(0xFF5A5A5A),
    chartOverlay: Color(0xFFF2F2F2),
  );

  /// Warm paper. The blue is taken out of every neutral, so the amber energy
  /// ramp sits on a background of the same temperature.
  static const sepia = AppThemeColors(
    canvas: Color(0xFFF0E9DC),
    surface: Color(0xFFFBF6EC),
    control: Color(0xFFE9E0CF),
    controlHigh: Color(0xFFDFD4C0),
    modalScrim: Color(0x33231C0F),
    track: Color(0xFFE4DACA),
    divider: Color(0xFFDCD1BE),
    ink: Color(0xFF231C0F),
    inkMuted: Color(0xFF6E6353),
    inkSubtle: Color(0xFF9C9081),
    selectionFill: Color(0xFF3A2F1E),
    onSelection: Color(0xFFFBF6EC),
    inverseSurface: Color(0xFF2C2417),
    onInverseSurface: Color(0xFFFBF6EC),
    onInverseSurfaceMuted: Color(0xFFC7BAA6),
    chartGrid: Color(0xFFE2D8C6),
    chartAxisLabel: Color(0xFF9C9081),
    chartProjected: Color(0xFFE0D6C4),
    chartHeld: Color(0xFFC9BDA9),
    chartNowMarker: Color(0xFFAB9F8C),
    chartOverlay: Color(0xFF231C0F),
  );

  /// Cool slate. A dark view that reads colder than [dark], for a cabin at
  /// night without the petrol cast.
  static const nordic = AppThemeColors(
    canvas: Color(0xFF20242C),
    surface: Color(0xFF2C323C),
    control: Color(0xFF3A414D),
    controlHigh: Color(0xFF48505E),
    modalScrim: Color(0x99131720),
    track: Color(0xFF434B58),
    divider: Color(0xFF525B6A),
    ink: Color(0xFFE7ECF3),
    inkMuted: Color(0xFFB6BFCD),
    inkSubtle: Color(0xFF8792A3),
    selectionFill: Color(0xFFD5DEEB),
    onSelection: Color(0xFF20242C),
    inverseSurface: Color(0xFF171B22),
    onInverseSurface: Color(0xFFE7ECF3),
    onInverseSurfaceMuted: Color(0xFFAAB4C3),
    chartGrid: Color(0xFF4B5462),
    chartAxisLabel: Color(0xFF9AA4B4),
    chartProjected: Color(0xFF363D48),
    chartHeld: Color(0xFF4E5766),
    chartNowMarker: Color(0xFF6B7585),
    chartOverlay: Color(0xFFE7ECF3),
  );

  /// Direct sunlight. Content and background are pushed as far apart as the
  /// panel allows, and every muted tier is darkened so it stays legible
  /// through glare.
  static const daylight = AppThemeColors(
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    control: Color(0xFFE2E2E2),
    controlHigh: Color(0xFFD0D0D0),
    modalScrim: Color(0x66000000),
    track: Color(0xFFD8D8D8),
    divider: Color(0xFF3A3A3A),
    ink: Color(0xFF000000),
    inkMuted: Color(0xFF3D3D3D),
    inkSubtle: Color(0xFF5E5E5E),
    selectionFill: Color(0xFF000000),
    onSelection: Color(0xFFFFFFFF),
    inverseSurface: Color(0xFF000000),
    onInverseSurface: Color(0xFFFFFFFF),
    onInverseSurfaceMuted: Color(0xFFD5D5D5),
    chartGrid: Color(0xFFBDBDBD),
    chartAxisLabel: Color(0xFF3D3D3D),
    chartProjected: Color(0xFFCFCFCF),
    chartHeld: Color(0xFF9E9E9E),
    chartNowMarker: Color(0xFF616161),
    chartOverlay: Color(0xFF000000),
  );

  // --- The expressive themes ----------------------------------------------
  // These three state their own [energy] ramp. The restrained six do not, so
  // they all keep [AppEnergyRamp.standard]. Meaning is unchanged everywhere:
  // `gain` is still energy recovered and `draw` is still energy spent, and the
  // two hues stay far enough apart to be told at a glance in a moving car.

  /// A wet street in Shinjuku at night: near-black violet ground, with the
  /// signage doing all the talking. Cyan is the gain, magenta the draw — the
  /// pair the city itself uses, and about as far apart as two hues get.
  ///
  /// The pale steps go *down* rather than up, because a tint on a dark card
  /// disappears while a shade of the same hue keeps its identity.
  static const tokyoNeon = AppThemeColors(
    canvas: Color(0xFF0B0714),
    surface: Color(0xFF150E24),
    control: Color(0xFF221838),
    controlHigh: Color(0xFF2E2049),
    modalScrim: Color(0xCC05030B),
    track: Color(0xFF251A3C),
    divider: Color(0xFF3A2A5C),
    ink: Color(0xFFF2ECFF),
    inkMuted: Color(0xFFB9A8E0),
    inkSubtle: Color(0xFF7E6BA8),
    selectionFill: Color(0xFFE9DDFF),
    onSelection: Color(0xFF150E24),
    inverseSurface: Color(0xFF070410),
    onInverseSurface: Color(0xFFF2ECFF),
    onInverseSurfaceMuted: Color(0xFFB0A0D6),
    chartGrid: Color(0xFF2B2043),
    chartAxisLabel: Color(0xFF9C8AC8),
    chartProjected: Color(0xFF1E1633),
    chartHeld: Color(0xFF33254F),
    chartNowMarker: Color(0xFF55406F),
    chartOverlay: Color(0xFFF2ECFF),
    energy: AppEnergyRamp(
      gain: Color(0xFF21E7E0),
      gainSoft: Color(0xFF10A3A5),
      gainSubtle: Color(0xFF0C5F66),
      draw: Color(0xFFFF3D9A),
      drawSoft: Color(0xFFB32A75),
      drawSubtle: Color(0xFF6B1B4B),
      warning: Color(0xFFFFC93C),
      critical: Color(0xFFFF4D5E),
      focus: Color(0xFF7A5CFF),
    ),
  );

  /// Dusk on the road home: deep plum ground, mint for what comes back and
  /// coral for what is spent.
  static const sunsetDrive = AppThemeColors(
    canvas: Color(0xFF1B0F1C),
    surface: Color(0xFF2A1728),
    control: Color(0xFF3A2036),
    controlHigh: Color(0xFF4A2A43),
    modalScrim: Color(0xCC0E070F),
    track: Color(0xFF3E2238),
    divider: Color(0xFF55314B),
    ink: Color(0xFFFFEDE4),
    inkMuted: Color(0xFFE0B9AE),
    inkSubtle: Color(0xFFA9807C),
    selectionFill: Color(0xFFFFE0CF),
    onSelection: Color(0xFF2A1728),
    inverseSurface: Color(0xFF150A16),
    onInverseSurface: Color(0xFFFFEDE4),
    onInverseSurfaceMuted: Color(0xFFD6B3A9),
    chartGrid: Color(0xFF3D2337),
    chartAxisLabel: Color(0xFFC29A96),
    chartProjected: Color(0xFF2E1A2B),
    chartHeld: Color(0xFF48283F),
    chartNowMarker: Color(0xFF6B3D5C),
    chartOverlay: Color(0xFFFFEDE4),
    energy: AppEnergyRamp(
      gain: Color(0xFF34D8A6),
      gainSoft: Color(0xFF1E9273),
      gainSubtle: Color(0xFF135347),
      draw: Color(0xFFFF7A5C),
      drawSoft: Color(0xFFC4533C),
      drawSubtle: Color(0xFF7A3226),
      warning: Color(0xFFFFB84D),
      critical: Color(0xFFFF4D6D),
      focus: Color(0xFFC77DFF),
    ),
  );

  /// The one light theme with no restraint in it: pink paper, turquoise gain,
  /// raspberry draw. Kept light so the expressive set is not three dark
  /// themes wearing different neon.
  static const bubblegum = AppThemeColors(
    canvas: Color(0xFFFDF2FA),
    surface: Color(0xFFFFFFFF),
    control: Color(0xFFF7E4F3),
    controlHigh: Color(0xFFEFD3EA),
    modalScrim: Color(0x33301028),
    track: Color(0xFFF3DCEE),
    divider: Color(0xFFEBD0E6),
    ink: Color(0xFF2B1030),
    inkMuted: Color(0xFF7A5478),
    inkSubtle: Color(0xFFA889A6),
    selectionFill: Color(0xFF3D1642),
    onSelection: Color(0xFFFFF5FC),
    inverseSurface: Color(0xFF35123A),
    onInverseSurface: Color(0xFFFFF5FC),
    onInverseSurfaceMuted: Color(0xFFD6B8D3),
    chartGrid: Color(0xFFF0DCEB),
    chartAxisLabel: Color(0xFFA889A6),
    chartProjected: Color(0xFFF0E0EC),
    chartHeld: Color(0xFFD9BFD4),
    chartNowMarker: Color(0xFFB694B2),
    chartOverlay: Color(0xFF2B1030),
    energy: AppEnergyRamp(
      gain: Color(0xFF16BFA6),
      gainSoft: Color(0xFF86E0D2),
      gainSubtle: Color(0xFFD2F4EE),
      draw: Color(0xFFE8398B),
      drawSoft: Color(0xFFF79CC5),
      drawSubtle: Color(0xFFFBDCEA),
      warning: Color(0xFFF2A33C),
      critical: Color(0xFFE23B4B),
      focus: Color(0xFF7A5CFF),
    ),
  );

  static AppThemeColors of(BuildContext context) =>
      Theme.of(context).extension<AppThemeColors>() ?? light;

  final Color canvas;
  final Color surface;
  final Color control;
  final Color controlHigh;
  final Color modalScrim;
  final Color track;
  final Color divider;
  final Color ink;
  final Color inkMuted;
  final Color inkSubtle;
  final Color selectionFill;
  final Color onSelection;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color onInverseSurfaceMuted;
  final Color chartGrid;
  final Color chartAxisLabel;
  final Color chartProjected;
  final Color chartHeld;
  final Color chartNowMarker;
  final Color chartOverlay;

  /// The data hues. Defaults to [AppEnergyRamp.standard], so a theme states a
  /// ramp only when it means to change what the charts look like.
  final AppEnergyRamp energy;

  @override
  AppThemeColors copyWith() => this;

  @override
  AppThemeColors lerp(covariant AppThemeColors? other, double t) {
    if (other == null) return this;
    return AppThemeColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      control: Color.lerp(control, other.control, t)!,
      controlHigh: Color.lerp(controlHigh, other.controlHigh, t)!,
      modalScrim: Color.lerp(modalScrim, other.modalScrim, t)!,
      track: Color.lerp(track, other.track, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      inkSubtle: Color.lerp(inkSubtle, other.inkSubtle, t)!,
      selectionFill: Color.lerp(selectionFill, other.selectionFill, t)!,
      onSelection: Color.lerp(onSelection, other.onSelection, t)!,
      inverseSurface: Color.lerp(inverseSurface, other.inverseSurface, t)!,
      onInverseSurface: Color.lerp(
        onInverseSurface,
        other.onInverseSurface,
        t,
      )!,
      onInverseSurfaceMuted: Color.lerp(
        onInverseSurfaceMuted,
        other.onInverseSurfaceMuted,
        t,
      )!,
      chartGrid: Color.lerp(chartGrid, other.chartGrid, t)!,
      chartAxisLabel: Color.lerp(chartAxisLabel, other.chartAxisLabel, t)!,
      chartProjected: Color.lerp(chartProjected, other.chartProjected, t)!,
      chartHeld: Color.lerp(chartHeld, other.chartHeld, t)!,
      chartNowMarker: Color.lerp(chartNowMarker, other.chartNowMarker, t)!,
      chartOverlay: Color.lerp(chartOverlay, other.chartOverlay, t)!,
      energy: AppEnergyRamp.lerp(energy, other.energy, t),
    );
  }
}

/// Chart-plumbing colors: the parts of a plot that are not a data series.
///
/// Kept apart from [AppColors] so that adding a series later does not tempt
/// anyone into reusing a gridline color as data, or vice versa.
abstract final class AppChartColors {
  /// Horizontal gridlines and the axis rule.
  static const grid = Color(0xFFE6E6E4);

  /// Axis tick labels and inline chart captions.
  static const axisLabel = Color(0xFF9A9A9A);

  /// Bars representing projected/not-yet-measured intervals, drawn in the same
  /// geometry as real bars so the plot keeps its rhythm.
  static const projected = Color(0xFFDCDCDA);

  /// Bars for a charge that has met its limit and is idle on the plug: real
  /// measurements, but not a charge, so they read as neutral beside the energy
  /// colour rather than as another shade of it.
  static const held = Color(0xFFC4C4C2);

  /// The single bar marking "now" inside a run of [projected] bars.
  static const nowMarker = Color(0xFFA8A8A6);

  /// Reference overlay drawn on top of the bars (the actual-power curve) and
  /// the handle dot that rides it.
  static const overlay = AppColors.ink;
}
