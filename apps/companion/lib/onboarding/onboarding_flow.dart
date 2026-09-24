import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../auth/account_gateway.dart';
import '../auth/auth_controller.dart';
import '../l10n/app_localizations.dart';
import '../pairing/device_pairing_gateway.dart';
import '../sync/pairing_controller.dart';
import '../sync/sync_controller.dart';
import '../sync/cloud_run_report.dart';

/// Where the first-run journey is.
///
/// The steps are the things that have to happen before the app can answer
/// anything: the reader learns what it is, the phone learns who the reader is
/// and which car, the car sends what it holds, and the phone says what
/// arrived.
///
/// [login] and [welcome] are skipped whole when this build carries no account
/// server, or when a session from an earlier run is still good. A step that
/// cannot run must not be drawn.
enum OnboardingStep { intro, login, welcome, pair, syncing, done }

/// First-run journey: three intro slides, pairing, the first pull, and the
/// result of it.
///
/// It drives the same [PairingController] and [SyncController] the Sync tab
/// drives. Nothing here talks to the car by itself, so a pairing rule changed
/// in one place cannot mean two things.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    required this.pairing,
    required this.onFinished,
    this.auth,
    this.sync,
    this.accountOnly = false,
    super.key,
  });

  final PairingController pairing;

  /// The account form. Absent when this build carries no account server, and
  /// absent in a test that only exercises the car half of the journey: no
  /// controller, no login step.
  final AuthController? auth;

  /// Absent in a test that only exercises the intro. Without it the journey
  /// ends at pairing: a screen with no engine behind it must not draw a
  /// transfer.
  final SyncController? sync;

  /// Called once, when the reader leaves the journey for the shell.
  final VoidCallback onFinished;

  /// Whether the journey exists only to open an account.
  ///
  /// This is the door a reader meets again after signing out. They have
  /// already seen the slides and the car is still paired, so the flow opens on
  /// the form and ends the moment the account is open — walking them through
  /// pairing a car they never unpaired would be the app forgetting, not the
  /// reader.
  final bool accountOnly;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  static const _slideCount = 3;

  /// The order the engine pulls in. It is stated here as well because the
  /// cards are drawn before the first page lands, and a list that appeared
  /// one card at a time would read as a car that keeps finding more work.
  static const _streamOrder = [
    SyncStreamType.sessions,
    SyncStreamType.batteryCycles,
    SyncStreamType.intervals,
    SyncStreamType.events,
    SyncStreamType.tracks,
  ];

  late OnboardingStep _step = widget.accountOnly
      ? OnboardingStep.login
      : OnboardingStep.intro;
  int _slide = 0;

  /// Whether the login form is creating an account rather than opening one.
  /// One form, two verbs: the fields are the same pair, and a second screen
  /// for them would only differ in its button.
  bool _registering = false;

  /// The highest stream reached in this run, so completed streams stay marked done.
  int _highestActiveIndex = -1;

  /// The last page of each stream, kept per stream rather than per run.
  /// [SyncController.progress] holds only the page in flight, so a finished
  /// stream would lose its count the moment the next one started.
  final Map<SyncStreamType, SyncProgress> _pages = {};

  SyncRunReport? _report;

  static int _streamOrderIndex(SyncStreamType stream) {
    return switch (stream) {
      SyncStreamType.sessions => 0,
      SyncStreamType.batteryCycles => 1,
      SyncStreamType.intervals => 2,
      SyncStreamType.events => 3,
      SyncStreamType.tracks => 4,
      SyncStreamType.places ||
      SyncStreamType.preferences ||
      SyncStreamType.sessionCosts ||
      SyncStreamType.preferenceProposals ||
      SyncStreamType.journeys => 5,
      SyncStreamType.telemetryFrames => 5,
    };
  }

  @override
  void initState() {
    super.initState();
    widget.sync?.addListener(_onSyncTick);
    widget.auth?.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.sync?.removeListener(_onSyncTick);
    widget.auth?.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// The session arrived without the form being submitted.
  ///
  /// This is the confirmation link landing: the reader tapped it in their mail
  /// client, the phone handed the app back the callback, and the sign-in
  /// finished with no press. The journey has to move on its own, or the reader
  /// comes back to the very form they already filled in and is asked to fill
  /// it again.
  void _onAuthChanged() async {
    if (!mounted) return;
    final auth = widget.auth;
    if (auth == null) return;
    if (_step != OnboardingStep.login) {
      setState(() {});
      return;
    }
    if (!auth.isSignedIn) {
      setState(() {});
      return;
    }
    // Same restore as the form submit: the link signed the reader in.
    await widget.pairing.restore();
    if (!mounted) return;
    if (widget.accountOnly) {
      widget.onFinished();
      return;
    }
    setState(() => _step = OnboardingStep.welcome);
  }

  void _onSyncTick() {
    final progress = widget.sync?.progress;
    if (progress == null) return;
    final stream = progress.stream;
    final idx = _streamOrderIndex(stream);
    if (idx > _highestActiveIndex) {
      _highestActiveIndex = idx;
    }
    setState(() {
      _pages[stream] = progress;
    });
  }

  void _goToSlide(int index) => setState(() => _slide = index);

  void _next() {
    if (_slide < _slideCount - 1) {
      setState(() => _slide += 1);
      return;
    }
    _afterIntro();
  }

  void _skip() => _afterIntro();

  /// The account step, or straight to the car when there is no account to
  /// open. A reader who signed in on an earlier run is not asked again: the
  /// gateway keeps the session, and asking would be the app forgetting rather
  /// than the reader.
  void _afterIntro() {
    final auth = widget.auth;
    setState(() {
      _step = auth == null || auth.isSignedIn
          ? OnboardingStep.pair
          : OnboardingStep.login;
    });
  }

  void _backToIntro() {
    setState(() {
      _step = OnboardingStep.intro;
      _slide = _slideCount - 1;
    });
  }

  void _backFromPair() {
    final auth = widget.auth;
    if (auth != null && auth.isSignedIn) {
      setState(() => _step = OnboardingStep.welcome);
      return;
    }
    _backToIntro();
  }

  Future<void> _submitAccount(String email, String password) async {
    final auth = widget.auth;
    if (auth == null) return;
    if (_registering) {
      await auth.signUp(email, password);
    } else {
      await auth.signIn(email, password);
    }
    if (!mounted) return;
    // An accepted sign-up on a project that confirms by mail is not a session.
    // The reader stays on the form with the notice, because the next thing
    // they have to do is open their mail, not pair a car.
    if (!auth.isSignedIn) {
      // The address has to answer its mail first. Leave the form in sign-in
      // mode with the address still in it, because that is the state the
      // reader comes back to: the account exists now, so a second sign-up on
      // it would only be refused.
      if (_registering) setState(() => _registering = false);
      return;
    }
    // Fresh install: the local file is gone but the cloud still names this
    // account's car. Restore it so the pair step shows the linked car.
    // Awaited: the welcome step only draws after the lookup settles.
    await widget.pairing.restore();
    if (!mounted) return;
    if (widget.accountOnly) {
      widget.onFinished();
      return;
    }
    setState(() => _step = OnboardingStep.welcome);
  }

  void _toggleRegistering() {
    setState(() => _registering = !_registering);
  }

  Future<void> _pair(String code) async {
    await widget.pairing.submit(code);
    if (!mounted) return;
    final isSuccess =
        widget.pairing.isPaired ||
        widget.pairing.lastResult is ClaimAlreadyOwnedBySelf;
    if (!isSuccess) return;
    final sync = widget.sync;
    if (sync == null) {
      widget.onFinished();
      return;
    }
    setState(() {
      _step = OnboardingStep.syncing;
      _highestActiveIndex = -1;
      _pages.clear();
      _report = null;
    });
    await sync.runNow();
    if (!mounted) return;
    setState(() {
      _report = sync.lastReport;
      _step = OnboardingStep.done;
    });
  }

  Future<void> _continueAlreadyPaired() async {
    if (!mounted) return;
    final sync = widget.sync;
    if (sync == null) {
      widget.onFinished();
      return;
    }
    setState(() {
      _step = OnboardingStep.syncing;
      _highestActiveIndex = -1;
      _pages.clear();
      _report = null;
    });
    await sync.runNow();
    if (!mounted) return;
    setState(() {
      _report = sync.lastReport;
      _step = OnboardingStep.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([widget.pairing, widget.auth]),
          builder: (context, _) => switch (_step) {
            OnboardingStep.intro => _IntroStep(
              key: ValueKey('intro-$_slide'),
              index: _slide,
              count: _slideCount,
              onSlide: _goToSlide,
              onSkip: _skip,
              onNext: _next,
            ),
            OnboardingStep.login => _LoginStep(
              key: const Key('onboarding-login'),
              auth: widget.auth!,
              registering: _registering,
              onBack: widget.accountOnly ? null : _backToIntro,
              onToggleMode: _toggleRegistering,
              onSubmit: _submitAccount,
            ),
            OnboardingStep.welcome => _WelcomeStep(
              key: const Key('onboarding-welcome'),
              email: widget.auth?.session?.email ?? '',
              onContinue: () => setState(() => _step = OnboardingStep.pair),
            ),
            OnboardingStep.pair =>
              widget.pairing.isPaired
                  ? _AlreadyPairedStep(
                      key: const Key('onboarding-pair'),
                      pairing: widget.pairing,
                      onBack: _backFromPair,
                      onContinue: _continueAlreadyPaired,
                    )
                  : _PairStep(
                      key: const Key('onboarding-pair'),
                      pairing: widget.pairing,
                      onBack: _backFromPair,
                      onSubmit: _pair,
                    ),
            OnboardingStep.syncing => _SyncingStep(
              key: const Key('onboarding-syncing'),
              order: _streamOrder,
              pages: _pages,
              active: widget.sync?.progress?.stream,
              highestIndex: _highestActiveIndex,
            ),
            OnboardingStep.done => _DoneStep(
              key: const Key('onboarding-done'),
              report: _report,
              onContinue: widget.onFinished,
            ),
          },
        ),
      ),
    );
  }
}

/// One intro slide, its dots and its action.
class _IntroStep extends StatelessWidget {
  const _IntroStep({
    required this.index,
    required this.count,
    required this.onSlide,
    required this.onSkip,
    required this.onNext,
    super.key,
  });

  final int index;
  final int count;
  final ValueChanged<int> onSlide;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final title = switch (index) {
      0 => l10n.onboardingSlide1Title,
      1 => l10n.onboardingSlide2Title,
      _ => l10n.onboardingSlide3Title,
    };
    final body = switch (index) {
      0 => l10n.onboardingSlide1Body,
      1 => l10n.onboardingSlide2Body,
      _ => l10n.onboardingSlide3Body,
    };
    // One mood per slide. The mascot carries the tone the slide is written
    // in, which is what the expression set is for; a Material glyph beside
    // the same three sentences said nothing the words did not.
    final mood = switch (index) {
      0 => CapyMood.happy,
      1 => CapyMood.surprised,
      _ => CapyMood.winking,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        AppSpacing.x4,
        AppSpacing.x6,
        AppSpacing.x6,
      ),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('onboarding-skip'),
              onPressed: onSkip,
              child: Text(
                l10n.onboardingSkip,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CapyBadge(diameter: 196, mood: mood),
                  const SizedBox(height: AppSpacing.x8),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppText.metricSm.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      body,
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(color: colors.inkMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < count; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () => onSlide(i),
                    child: AnimatedContainer(
                      duration: AppMotion.base,
                      curve: AppMotion.curve,
                      width: i == index ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == index
                            ? colors.selectionFill
                            : colors.divider,
                        borderRadius: AppRadii.fullRadius,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x6),
          SoftActionTile(
            key: const Key('onboarding-next'),
            label: index == count - 1
                ? l10n.onboardingStart
                : l10n.onboardingNext,
            centered: true,
            selected: true,
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

/// The 6-digit code. Code-only now; no host field.
class _PairStep extends StatefulWidget {
  const _PairStep({
    required this.pairing,
    required this.onBack,
    required this.onSubmit,
    super.key,
  });

  final PairingController pairing;
  final VoidCallback onBack;
  final Future<void> Function(String code) onSubmit;

  @override
  State<_PairStep> createState() => _PairStepState();
}

class _PairStepState extends State<_PairStep> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String? _messageForPairing(PairingController pairing, AppLocalizations l10n) {
    if (pairing.signedOut) {
      return 'Sign in first to pair a car. Your account links this phone to the vehicle.';
    }
    if (pairing.connectivity == BackendReachability.noNetwork) {
      return 'No network connection. Check your Wi-Fi or mobile data and try again.';
    }
    if (pairing.connectivity == BackendReachability.backendUnreachable) {
      return 'Can\u2019t reach the server. Check your connection and try again.';
    }
    if (pairing.error == PairingError.invalidCode) {
      return l10n.pairingInvalidCode;
    }
    final result = pairing.lastResult;
    if (result != null) {
      return switch (result) {
        ClaimNotFound _ =>
          'That code was not found. Check the car screen and try again.',
        ClaimExpired _ =>
          'That code has expired. Generate a new code on the car and try again.',
        ClaimAlreadyClaimed _ =>
          'That code was already used. Make a new code on the car and try again.',
        ClaimVehicleAlreadyClaimed _ =>
          'This car is already paired with another account. Sign in with that account to pair it.',
        ClaimNetwork _ =>
          'Can\u2019t reach the server. Check your connection and try again.',
        ClaimUnknown _ => 'Something went wrong. Try again.',
        ClaimAlreadyOwnedBySelf _ =>
          'This phone is already paired with that car.',
        ClaimSuccessResult _ => null,
      };
    }
    // Fallback for legacy error without distinct result (e.g. null gateway).
    return switch (pairing.error) {
      PairingError.rejected => 'The car refused this code.',
      PairingError.carMissing =>
        'Can\u2019t reach the server. Check your connection and try again.',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final pairing = widget.pairing;
    final message = _messageForPairing(pairing, l10n);
    final isConnectivityError =
        pairing.connectivity == BackendReachability.noNetwork ||
        pairing.connectivity == BackendReachability.backendUnreachable;
    // alreadyOwnedBySelf is success-equivalent; do not show as critical error.
    final isAlreadyOwnedBySelf = pairing.lastResult is ClaimAlreadyOwnedBySelf;
    final showRetryAction = isConnectivityError;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        AppSpacing.x4,
        AppSpacing.x6,
        AppSpacing.x6,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            key: const Key('onboarding-back'),
            onPressed: pairing.busy ? null : widget.onBack,
            style: IconButton.styleFrom(backgroundColor: colors.control),
            icon: Icon(Icons.arrow_back, color: colors.ink),
            tooltip: l10n.onboardingBack,
          ),
        ),
        const SizedBox(height: AppSpacing.x6),
        Text(
          l10n.onboardingPairTitle,
          style: AppText.cardTitle.copyWith(color: colors.ink),
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          l10n.onboardingPairBody,
          style: AppText.body.copyWith(color: colors.inkMuted),
        ),
        const SizedBox(height: AppSpacing.x6),
        _FieldLabel(l10n.onboardingCodeLabel),
        TextField(
          key: const Key('onboarding-code-field'),
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          enabled: !pairing.busy,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: AppText.metricSm.copyWith(color: colors.ink),
          decoration: _fieldDecoration(colors, l10n.pairingCodeHint),
        ),
        if (message != null) ...[
          const SizedBox(height: AppSpacing.x3),
          Text(
            message,
            key: const Key('onboarding-pairing-message'),
            style: AppText.body.copyWith(
              color: isAlreadyOwnedBySelf ? colors.ink : colors.energy.critical,
            ),
          ),
        ],
        if (showRetryAction) ...[
          const SizedBox(height: AppSpacing.x3),
          SoftActionTile(
            key: const Key('onboarding-pair-retry'),
            label: 'Retry',
            centered: true,
            selected: true,
            onPressed: pairing.busy ? null : () => widget.onSubmit(_code.text),
          ),
        ],
        const SizedBox(height: AppSpacing.x6),
        SoftActionTile(
          key: const Key('onboarding-pair-submit'),
          label: pairing.busy ? l10n.onboardingPairing : l10n.pairingAction,
          centered: true,
          selected: true,
          onPressed: pairing.busy ? null : () => widget.onSubmit(_code.text),
        ),
      ],
    );
  }

  InputDecoration _fieldDecoration(AppThemeColors colors, String hint) {
    return InputDecoration(
      counterText: '',
      hintText: hint,
      hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
      filled: true,
      fillColor: colors.control,
      border: const OutlineInputBorder(
        borderRadius: AppRadii.mdRadius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: AppRadii.mdRadius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: AppRadii.mdRadius,
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _AlreadyPairedStep extends StatelessWidget {
  const _AlreadyPairedStep({
    required this.pairing,
    required this.onBack,
    required this.onContinue,
    super.key,
  });

  final PairingController pairing;
  final VoidCallback onBack;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        AppSpacing.x4,
        AppSpacing.x6,
        AppSpacing.x6,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            key: const Key('onboarding-back'),
            onPressed: pairing.busy ? null : onBack,
            style: IconButton.styleFrom(backgroundColor: colors.control),
            icon: Icon(Icons.arrow_back, color: colors.ink),
            tooltip: l10n.onboardingBack,
          ),
        ),
        const SizedBox(height: AppSpacing.x6),
        Text(
          l10n.onboardingPairTitle,
          style: AppText.cardTitle.copyWith(color: colors.ink),
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          'This phone is already paired with your car.',
          key: const Key('onboarding-already-paired-message'),
          style: AppText.body.copyWith(color: colors.ink),
        ),
        const SizedBox(height: AppSpacing.x6),
        SoftActionTile(
          key: const Key('onboarding-paired-continue'),
          label: l10n.onboardingContinue,
          centered: true,
          selected: true,
          onPressed: onContinue,
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x2),
      child: Text(text, style: AppText.label.copyWith(color: colors.inkMuted)),
    );
  }
}

/// One card per stream, in the order the engine pulls them.
class _SyncingStep extends StatelessWidget {
  const _SyncingStep({
    required this.order,
    required this.pages,
    required this.active,
    this.highestIndex = -1,
    super.key,
  });

  final List<SyncStreamType> order;
  final Map<SyncStreamType, SyncProgress> pages;

  /// The stream the page in flight belongs to, or null between pages.
  final SyncStreamType? active;

  final int highestIndex;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final activeIndex = active == null
        ? -1
        : _OnboardingFlowState._streamOrderIndex(active!);
    final effectiveIndex = activeIndex > highestIndex
        ? activeIndex
        : highestIndex;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        AppSpacing.x10,
        AppSpacing.x6,
        AppSpacing.x6,
      ),
      children: [
        Text(
          l10n.onboardingSyncingTitle,
          style: AppText.cardTitle.copyWith(color: colors.ink),
        ),
        const SizedBox(height: AppSpacing.x2),
        Text(
          l10n.onboardingSyncingBody,
          style: AppText.body.copyWith(color: colors.inkMuted),
        ),
        const SizedBox(height: AppSpacing.x6),
        for (var i = 0; i < order.length; i++) ...[
          _StreamCard(
            stream: order[i],
            page: pages[order[i]],
            // A stream the run has moved past is done, whether or not its
            // last page reported a total. The engine's order is what states
            // that, not a count the car may never have sent.
            done: effectiveIndex > i,
            running: activeIndex == i,
          ),
          if (i != order.length - 1) const SizedBox(height: AppSpacing.x3),
        ],
      ],
    );
  }
}

class _StreamCard extends StatelessWidget {
  const _StreamCard({
    required this.stream,
    required this.page,
    required this.done,
    required this.running,
  });

  final SyncStreamType stream;
  final SyncProgress? page;
  final bool done;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final name = switch (stream) {
      SyncStreamType.sessions => l10n.syncStreamTrips,
      SyncStreamType.batteryCycles => l10n.syncStreamCycles,
      SyncStreamType.intervals => l10n.syncStreamIntervals,
      SyncStreamType.events => l10n.syncStreamEvents,
      SyncStreamType.telemetryFrames => l10n.syncStreamFrames,
      SyncStreamType.tracks => l10n.syncStreamTracks,
      SyncStreamType.places ||
      SyncStreamType.preferences ||
      SyncStreamType.sessionCosts ||
      SyncStreamType.preferenceProposals ||
      SyncStreamType.journeys => l10n.syncStreamAnnotations,
    };
    final started = done || running || page != null;
    final remaining = page?.remaining;
    final line = page == null
        ? (done ? l10n.onboardingWritten(0) : l10n.onboardingStreamWaiting)
        : remaining == null
        ? l10n.onboardingWritten(page!.recordsWritten)
        : l10n.onboardingCounted(
            page!.recordsWritten,
            page!.recordsWritten + remaining,
          );
    // The bar needs a denominator the car sent. Frames never carry one, and a
    // bar with no total would sit full for the whole transfer.
    final fraction = page?.fraction == null
        ? null
        : (done ? 1.0 : page!.fraction);
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? colors.energy.gain
                      : running
                      ? colors.selectionFill
                      : colors.divider,
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Text(
                  name,
                  style: AppText.bodyStrong.copyWith(
                    color: started ? colors.ink : colors.inkSubtle,
                  ),
                ),
              ),
              if (done)
                Icon(
                  Icons.check_circle,
                  size: AppSizes.iconSm,
                  color: colors.energy.gain,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(line, style: AppText.label.copyWith(color: colors.inkMuted)),
          // Frames carry their own scale: one session holds thousands of them,
          // so the position in the session list is the reading, not a count.
          if (page?.sessionIndex case final index?) ...[
            const SizedBox(height: AppSpacing.x1),
            Text(
              l10n.syncProgressSession(index, page!.sessionCount ?? index),
              style: AppText.label.copyWith(color: colors.inkMuted),
            ),
          ],
          if (fraction != null) ...[
            const SizedBox(height: AppSpacing.x3),
            ClipRRect(
              borderRadius: AppRadii.smRadius,
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: colors.track,
                color: colors.selectionFill,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What the first pull left behind.
///
/// A run that failed says so here rather than at the next screen. The pairing
/// still holds — the car answered the code — so the reader is told where to
/// try again instead of being sent back through the journey.
class _DoneStep extends StatelessWidget {
  const _DoneStep({required this.report, required this.onContinue, super.key});

  final SyncRunReport? report;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final kind = syncOutcomeKind(report);
    // An empty answer from the path that ran is still success: only the
    // kinds that name something to fix get the worried face.
    final ok = switch (kind) {
      SyncOutcomeKind.neverRun ||
      SyncOutcomeKind.completed ||
      SyncOutcomeKind.nothingNew => true,
      _ => false,
    };
    final line = switch (kind) {
      SyncOutcomeKind.completed => l10n.onboardingPairedBody(
        report!.ackedRecords,
      ),
      // Gate off in this build: the failure below is the build, not the car.
      SyncOutcomeKind.cloudDisabled => l10n.onboardingSyncCloudDisabled,
      // This phone never reached the cloud: its connection, not the car's.
      SyncOutcomeKind.phoneOffline => l10n.onboardingSyncPhoneOffline,
      // The cloud answered but the car sent nothing: the car has not
      // uploaded (offline, or its own gate off), not "nothing to send".
      SyncOutcomeKind.carSilent => l10n.onboardingSyncCarSilent,
      SyncOutcomeKind.nothingNew => l10n.onboardingPairedNothing,
      // No run happened (no controller was wired): nothing failed, so this
      // keeps the old delighted reading rather than crying failure.
      SyncOutcomeKind.neverRun => l10n.onboardingPairedNothing,
      _ => l10n.onboardingSyncFailed,
    };
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.x6),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CapyBadge(
                    diameter: 120,
                    mood: ok ? CapyMood.delighted : CapyMood.worried,
                    badge: ok ? Icons.check_circle : Icons.error_outline,
                    badgeColor: ok ? colors.energy.gain : colors.energy.warning,
                  ),
                  const SizedBox(height: AppSpacing.x6),
                  Text(
                    l10n.onboardingPairedTitle,
                    textAlign: TextAlign.center,
                    style: AppText.cardTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: AppSpacing.x2),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      line,
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(color: colors.inkMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SoftActionTile(
            key: const Key('onboarding-continue'),
            label: l10n.onboardingContinue,
            centered: true,
            selected: true,
            onPressed: onContinue,
          ),
        ],
      ),
    );
  }
}

/// The account form: one pair of fields, and the verb the reader chose.
///
/// The two links under the button are the two other things a reader can want
/// here. Neither is decoration: `Create account` swaps the verb of this same
/// form, and `Forgot password?` sends the reset mail to the address already
/// typed above.
class _LoginStep extends StatefulWidget {
  const _LoginStep({
    required this.auth,
    required this.registering,
    required this.onBack,
    required this.onToggleMode,
    required this.onSubmit,
    super.key,
  });

  final AuthController auth;
  final bool registering;

  /// Null when there is nothing behind this screen. The door a reader meets
  /// after signing out has no back: the app has nothing else to show them.
  final VoidCallback? onBack;
  final VoidCallback onToggleMode;
  final Future<void> Function(String email, String password) onSubmit;

  @override
  State<_LoginStep> createState() => _LoginStepState();
}

class _LoginStepState extends State<_LoginStep> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final auth = widget.auth;
    final registering = widget.registering;
    final error = _errorText(l10n, auth.error);
    final notice = _noticeText(l10n, auth.notice);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        AppSpacing.x4,
        AppSpacing.x6,
        AppSpacing.x6,
      ),
      children: [
        if (widget.onBack != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: const Key('onboarding-login-back'),
              onPressed: auth.busy ? null : widget.onBack,
              style: IconButton.styleFrom(backgroundColor: colors.control),
              icon: Icon(Icons.arrow_back, color: colors.ink),
              tooltip: l10n.onboardingBack,
            ),
          ),
          const SizedBox(height: AppSpacing.x6),
        ],
        Row(
          children: [
            const CapyBadge(diameter: 52, mood: CapyMood.happy),
            const SizedBox(width: AppSpacing.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    registering
                        ? l10n.onboardingCreateTitle
                        : l10n.onboardingLoginTitle,
                    style: AppText.cardTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    registering
                        ? l10n.onboardingCreateBody
                        : l10n.onboardingLoginBody,
                    style: AppText.label.copyWith(color: colors.inkMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x8),
        _FieldLabel(l10n.onboardingEmailLabel),
        TextField(
          key: const Key('onboarding-email-field'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enabled: !auth.busy,
          style: AppText.body.copyWith(color: colors.ink),
          decoration: _accountFieldDecoration(colors, l10n.onboardingEmailHint),
        ),
        const SizedBox(height: AppSpacing.x4),
        _FieldLabel(l10n.onboardingPasswordLabel),
        TextField(
          key: const Key('onboarding-password-field'),
          controller: _password,
          obscureText: _obscure,
          enabled: !auth.busy,
          style: AppText.body.copyWith(color: colors.ink),
          decoration: _accountFieldDecoration(colors, '••••••••').copyWith(
            suffixIcon: IconButton(
              key: const Key('onboarding-password-toggle'),
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure ? Icons.visibility : Icons.visibility_off,
                color: colors.inkMuted,
                size: AppSizes.iconSm,
              ),
              tooltip: _obscure
                  ? l10n.onboardingShowPassword
                  : l10n.onboardingHidePassword,
            ),
          ),
        ),
        if (registering && error == null) ...[
          const SizedBox(height: AppSpacing.x2),
          Text(
            l10n.accountWeakPassword(AuthController.minPasswordLength),
            key: const Key('onboarding-password-hint'),
            style: AppText.label.copyWith(color: colors.inkMuted),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: AppSpacing.x3),
          Text(
            error,
            key: const Key('onboarding-account-error'),
            style: AppText.body.copyWith(color: colors.energy.critical),
          ),
        ],
        if (notice != null) ...[
          const SizedBox(height: AppSpacing.x3),
          Text(
            notice,
            key: const Key('onboarding-account-notice'),
            style: AppText.body.copyWith(color: colors.ink),
          ),
        ],
        const SizedBox(height: AppSpacing.x6),
        SoftActionTile(
          key: const Key('onboarding-account-submit'),
          label: auth.busy
              ? (registering
                    ? l10n.onboardingCreating
                    : l10n.onboardingLoggingIn)
              : (registering
                    ? l10n.onboardingCreateAccount
                    : l10n.onboardingLogIn),
          centered: true,
          selected: true,
          onPressed: auth.busy
              ? null
              : () => widget.onSubmit(_email.text, _password.text),
        ),
        const SizedBox(height: AppSpacing.x4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              key: const Key('onboarding-forgot-password'),
              onPressed: auth.busy
                  ? null
                  : () => auth.sendPasswordReset(_email.text),
              child: Text(
                l10n.onboardingForgotPassword,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
            ),
            TextButton(
              key: const Key('onboarding-toggle-mode'),
              onPressed: auth.busy ? null : widget.onToggleMode,
              child: Text(
                registering
                    ? l10n.onboardingHaveAccount
                    : l10n.onboardingCreateAccount,
                style: AppText.label.copyWith(color: colors.ink),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

InputDecoration _accountFieldDecoration(AppThemeColors colors, String hint) {
  const border = OutlineInputBorder(
    borderRadius: AppRadii.mdRadius,
    borderSide: BorderSide.none,
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
    filled: true,
    fillColor: colors.control,
    border: border,
    enabledBorder: border,
    focusedBorder: border,
    disabledBorder: border,
  );
}

/// The line for a refused account action.
///
/// Every case has its own sentence. The provider's own message is never shown:
/// it is server text, in the server's language, and it changes between
/// releases of the service.
String? _errorText(AppLocalizations l10n, AccountError? error) {
  return switch (error) {
    AccountError.invalidEmail => l10n.accountInvalidEmail,
    AccountError.weakPassword => l10n.accountWeakPassword(
      AuthController.minPasswordLength,
    ),
    AccountError.wrongCredentials => l10n.accountWrongCredentials,
    AccountError.emailNotConfirmed => l10n.accountEmailNotConfirmed,
    AccountError.alreadyRegistered => l10n.accountAlreadyRegistered,
    AccountError.rateLimited => l10n.accountRateLimited,
    AccountError.network => l10n.accountNetwork,
    AccountError.unconfigured => l10n.accountUnconfigured,
    AccountError.unknown => l10n.accountUnknown,
    null => null,
  };
}

String? _noticeText(AppLocalizations l10n, AccountNotice? notice) {
  return switch (notice) {
    AccountNotice.confirmEmail => l10n.accountConfirmEmail,
    AccountNotice.resetSent => l10n.accountResetSent,
    null => null,
  };
}

/// The account is open. It says who, and what the next step is.
///
/// It names the car as the next thing on purpose: signing in changed nothing
/// about where the data comes from, and a screen that stopped here would read
/// as an app that is now ready.
class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({
    required this.email,
    required this.onContinue,
    super.key,
  });

  final String email;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.x6),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CapyBadge(
                    diameter: 120,
                    mood: CapyMood.delighted,
                    badge: Icons.check_circle,
                  ),
                  const SizedBox(height: AppSpacing.x6),
                  Text(
                    l10n.onboardingWelcomeTitle,
                    textAlign: TextAlign.center,
                    style: AppText.cardTitle.copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: AppSpacing.x2),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      l10n.onboardingWelcomeBody(email),
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(color: colors.inkMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SoftActionTile(
            key: const Key('onboarding-continue-to-pairing'),
            label: l10n.onboardingContinueToPairing,
            centered: true,
            selected: true,
            onPressed: onContinue,
          ),
        ],
      ),
    );
  }
}
