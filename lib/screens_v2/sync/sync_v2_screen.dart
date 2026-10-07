import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:capy_ui/capy_ui.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';

import 'package:qr_flutter/qr_flutter.dart';

enum _CompanionPlatform { android, ios, forbidden }

/// How often the screen asks the car what it holds.
///
/// One second, because the code carries a countdown and because the phone
/// completes the pairing over the network: nothing on the car tells this
/// screen that a phone answered, so the only way it learns is by asking.
const _syncPollInterval = Duration(seconds: 1);

/// The pairing surface of the phone companion.
///
/// The car generates a six-digit code and shows it here; the phone types it
/// into its own screen and exchanges it for the shared secret.
class SyncV2Screen extends StatefulWidget {
  const SyncV2Screen({
    required this.title,
    this.telemetryApi,
    this.reachabilityChecker,
    this.androidBetaUrl = '',
    this.iosBetaUrl = '',
    this.forbiddenApkUrl = '',
    super.key,
  });

  final String title;

  /// Where the companion beta builds live, when the publisher configured
  /// one. Empty (the default) means no link is published: the card shows a
  /// placeholder instead of a QR code. Production wires these from
  /// `--dart-define=COMPANION_ANDROID_URL/...` (see README); never hardcode
  /// a personal invite or file link here.
  final String androidBetaUrl;
  final String iosBetaUrl;
  final String forbiddenApkUrl;

  /// Seam for tests. Production passes nothing and gets the shared api through
  /// [TelemetryScope].
  final TelemetryApi? telemetryApi;

  /// Seam for tests. When null the screen builds a default checker that probes
  /// the Supabase base URL via [HttpReachabilityClient].
  final BackendReachabilityChecker? reachabilityChecker;

  /// Visible for testing: builds the checker that the screen's default would
  /// build for the given env values. Keeps the routing/header decision
  /// testable without relying on `String.fromEnvironment` consts.
  @visibleForTesting
  static BackendReachabilityChecker buildReachabilityChecker({
    required String urlEnv,
    required String publishableKey,
  }) {
    final uri = urlEnv.isNotEmpty ? Uri.tryParse(urlEnv) : null;
    final baseUri = uri ?? Uri.parse('https://example.supabase.co');
    final hasKey = publishableKey.isNotEmpty;
    // When a key is configured, probe the authenticated health endpoint
    // that returns 200 (not the bare root which is 404 on Supabase).
    // Without a key, keep today's bare-base-URL behaviour so an
    // unconfigured deployment degrades the same way, not throws.
    final backendUri = hasKey && uri != null
        ? baseUri.replace(path: '/auth/v1/health')
        : baseUri;
    return BackendReachabilityChecker(
      client: HttpReachabilityClient(),
      backendUri: backendUri,
      headers: hasKey ? {'apikey': publishableKey} : null,
    );
  }

  @override
  State<SyncV2Screen> createState() => _SyncV2ScreenState();
}

class _SyncV2ScreenState extends State<SyncV2Screen> {
  _CompanionPlatform _selectedPlatform = _CompanionPlatform.android;

  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  late final BackendReachabilityChecker _checker =
      widget.reachabilityChecker ?? _defaultChecker();

  static BackendReachabilityChecker _defaultChecker() {
    const urlEnv = String.fromEnvironment('SUPABASE_URL');
    // Accept both names: the companion Flutter app uses SUPABASE_PUBLISHABLE_KEY
    // (new Supabase naming), the Android side uses SUPABASE_ANON_KEY. Either
    // names the same publishable/anon key value; one empty falls back to the
    // other so a single .env works for both sides.
    const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    final key = publishableKey.isNotEmpty ? publishableKey : anonKey;
    return SyncV2Screen.buildReachabilityChecker(
      urlEnv: urlEnv,
      publishableKey: key,
    );
  }

  DevicePairingState? _pairingState;
  BackendReachability? _reachability;
  bool _checkingReachability = false;
  bool _busy = false;
  bool _pairingStartFailed = false;
  PollLoop? _pairingPoll;
  Timer? _countdownTimer;

  late final TelemetryQuery<bool> _bleActive = TelemetryQuery(
    read: _api.isBleStreamActive,
    interval: _syncPollInterval,
    debugLabel: 'SyncV2Screen.bleActive',
  );

  late final TelemetryQuery<SyncProgressData> _syncProgress = TelemetryQuery(
    read: _api.getCloudSyncProgress,
    interval: const Duration(seconds: 10),
    debugLabel: 'SyncV2Screen.syncProgress',
  );

  /// The outcome of the last FORCE SYNC press, or null when it was never
  /// pressed. Reports what the car did, never what it hopes happened.
  String? _forceResult;

  /// Whether a cloud upload is running right now. The car call blocks on the
  /// network, so the button shows a spinner instead of accepting more taps.
  bool _forcing = false;

  @override
  void initState() {
    super.initState();
    _bleActive
      ..addListener(_onChanged)
      ..start();
    _syncProgress
      ..addListener(_onChanged)
      ..start();
    // Restore any pending pairing that survived a restart.
    unawaited(_restorePairingState());
    // Ticker for the expiry countdown while pending.
  }

  Future<void> _restorePairingState() async {
    try {
      final current = await _api.getDevicePairingState();
      if (!mounted) return;
      setState(() => _pairingState = current);
      if (current is DevicePairingPending) {
        _startPolling();
        _startCountdown();
      }
    } catch (_) {
      // No state yet — stays idle.
    }
  }

  @override
  void dispose() {
    _pairingPoll?.dispose();
    _countdownTimer?.cancel();
    _bleActive
      ..removeListener(_onChanged)
      ..dispose();
    _syncProgress
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startPairingFlow() async {
    if (_busy || _checkingReachability) return;
    setState(() {
      _checkingReachability = true;
      _reachability = null;
      _pairingStartFailed = false;
    });
    final outcome = await _checker.check();
    if (!mounted) return;
    if (outcome != BackendReachability.reachable) {
      setState(() {
        _checkingReachability = false;
        _reachability = outcome;
      });
      return;
    }
    setState(() {
      _checkingReachability = false;
      _reachability = BackendReachability.reachable;
      _busy = true;
      _pairingStartFailed = false;
    });
    try {
      final state = await _api.startDevicePairing();
      if (!mounted) return;
      setState(() {
        _pairingState = state;
        _busy = false;
        _pairingStartFailed = false;
      });
      if (state is DevicePairingPending) {
        _startPolling();
        _startCountdown();
      } else if (state is DevicePairingApproved) {
        _stopPolling();
        _stopCountdown();
      } else {
        _stopPolling();
        _stopCountdown();
      }
    } catch (e, stack) {
      debugPrint('SyncV2Screen startDevicePairing failed: $e');
      debugPrintStack(
        stackTrace: stack,
        label: 'SyncV2Screen startDevicePairing',
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _pairingStartFailed = true;
        });
      }
    }
  }

  void _startPolling() {
    _pairingPoll?.dispose();
    _pairingPoll = PollLoop(
      interval: _syncPollInterval,
      read: _pollOnce,
      debugLabel: 'SyncV2Screen.pairingPoll',
    )..start();
  }

  void _stopPolling() {
    _pairingPoll?.dispose();
    _pairingPoll = null;
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(_syncPollInterval, (_) {
      if (!mounted) return;
      if (_pairingState is DevicePairingPending) setState(() {});
    });
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  Future<void> _pollOnce() async {
    try {
      final state = await _api.getDevicePairingState();
      if (!mounted) return;
      if (state == null) {
        setState(() => _pairingState = const DevicePairingIdle());
        _stopPolling();
        _stopCountdown();
        return;
      }
      setState(() => _pairingState = state);
      if (state is DevicePairingPending) return;
      // Terminal states stop the loop.
      _stopPolling();
      _stopCountdown();
    } catch (_) {
      // Keep pending on transient failure; next tick retries.
    }
  }

  Future<void> _cancelCode() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _api.cancelDevicePairing();
      if (!mounted) return;
      if (result != null) {
        setState(() => _pairingState = result);
      } else {
        setState(() => _pairingState = const DevicePairingIdle());
      }
      _stopPolling();
      _stopCountdown();
      setState(() => _reachability = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs one cloud upload pass right now, and says what the car did.
  ///
  /// The car call blocks on the network, so this runs with a busy flag the
  /// button reads instead of freezing the UI thread. The result names the
  /// rows that moved, or the failure — never an optimistic "done".
  Future<void> _forceSync(AppLocalizations loc) async {
    if (_busy || _forcing) return;
    setState(() {
      _forcing = true;
      _forceResult = null;
    });
    try {
      final report = await _api.forceCloudSync();
      if (!mounted) return;
      setState(() {
        _forceResult = _describeForceResult(loc, report);
      });
      unawaited(_syncProgress.refresh());
    } finally {
      if (mounted) setState(() => _forcing = false);
    }
  }

  /// States what the upload pass did, in the owner's language.
  ///
  /// A build with cloud sync off says so plainly instead of pretending to
  /// sync and silently doing nothing. A car that is not paired says so too,
  /// never a failure: nothing was attempted.
  String _describeForceResult(AppLocalizations loc, CloudSyncResult report) {
    if (!report.cloudReady) return loc.v2SyncCloudDisabled;
    if (!report.paired) return loc.v2SyncCloudNotPaired;
    if (report.failed) return loc.v2SyncCloudFailed;
    if (report.movedRows == 0) return loc.v2SyncCloudEmpty;
    return loc.v2SyncCloudMoved(report.movedRows);
  }

  /// States how much of the local record still waits for the cloud.
  ///
  /// Rows can wait for two reasons: an upload has not run yet, or the car
  /// clock is not anchored. When both apply, one localized sentence names
  /// both counts, so each locale owns its own word order and separator.
  String _progressStatus(AppLocalizations loc, SyncProgressData progress) {
    if (progress.isUpToDate) return loc.v2SyncProgressUpToDate;
    final dirty = progress.dirtyCount;
    final clock = progress.pendingCount;
    if (dirty > 0 && clock > 0) {
      return loc.v2SyncProgressPendingBoth(dirty, clock);
    }
    if (dirty > 0) return loc.v2SyncProgressPending(dirty);
    return loc.v2SyncProgressPendingClock(clock);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gridGutter),
      child: TwoColumnLayout(
        primary: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _codeCard(loc),
              const SizedBox(height: AppSpacing.gridGutter),
              _cloudSyncCard(loc),
            ],
          ),
        ),
        trailing: _companionBetaCard(loc),
      ),
    );
  }

  Widget _companionBetaCard(AppLocalizations loc) {
    final colors = AppThemeColors.of(context);
    final url = switch (_selectedPlatform) {
      _CompanionPlatform.android => widget.androidBetaUrl,
      _CompanionPlatform.ios => widget.iosBetaUrl,
      _CompanionPlatform.forbidden => widget.forbiddenApkUrl,
    };

    return AppCard(
      title: loc.v2SyncCompanionTitle,
      subtitle: loc.v2SyncCompanionBeta,
      badge: const StatusBadge(icon: Icons.smartphone),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loc.v2SyncCompanionDescription,
              style: AppText.body.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x3),
            Text(
              loc.v2SyncCompanionUpdateHint,
              style: AppText.bodyStrong.copyWith(color: colors.ink),
            ),
            const SizedBox(height: AppSpacing.x4),
            Container(
              decoration: BoxDecoration(
                color: colors.control,
                borderRadius: AppRadii.mdRadius,
              ),
              padding: const EdgeInsets.all(AppSpacing.x1),
              child: Row(
                children: [
                  Expanded(
                    child: _PlatformButton(
                      icon: Icons.android,
                      label: loc.v2SyncCompanionAndroid,
                      selected: _selectedPlatform == _CompanionPlatform.android,
                      onTap: () => setState(
                        () => _selectedPlatform = _CompanionPlatform.android,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x1),
                  Expanded(
                    child: _PlatformButton(
                      icon: Icons.apple,
                      label: loc.v2SyncCompanionIos,
                      selected: _selectedPlatform == _CompanionPlatform.ios,
                      onTap: () => setState(
                        () => _selectedPlatform = _CompanionPlatform.ios,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x1),
                  Expanded(
                    child: _PlatformButton(
                      icon: Icons.help_outline,
                      label: loc.v2SyncCompanionForbidden,
                      selected:
                          _selectedPlatform == _CompanionPlatform.forbidden,
                      onTap: () => setState(
                        () => _selectedPlatform = _CompanionPlatform.forbidden,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.x4),
            Text(
              loc.v2SyncCompanionScanQr,
              style: AppText.label.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x3),
            LayoutBuilder(
              builder: (context, constraints) {
                const padding = AppSpacing.x3;
                final availableWidth = constraints.maxWidth;
                final containerSize = availableWidth > 0
                    ? math.min(availableWidth, 180.0)
                    : 180.0;
                final qrSize = containerSize - (padding * 2);
                return Center(
                  child: Container(
                    width: containerSize,
                    height: containerSize,
                    padding: const EdgeInsets.all(padding),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: AppRadii.lgRadius,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: url.isNotEmpty
                        ? QrImageView(
                            // Keyed by the link, so a test can tell which
                            // link the code carries.
                            key: ValueKey(url),
                            data: url,
                            version: QrVersions.auto,
                            size: qrSize > 0 ? qrSize : null,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Colors.black,
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Colors.black,
                            ),
                          )
                        : SizedBox(
                            width: qrSize > 0 ? qrSize : 120,
                            height: qrSize > 0 ? qrSize : 120,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  switch (_selectedPlatform) {
                                    _CompanionPlatform.android => Icons.android,
                                    _CompanionPlatform.ios => Icons.apple,
                                    _CompanionPlatform.forbidden =>
                                      Icons.help_outline,
                                  },
                                  size: 48,
                                  color: Colors.black54,
                                ),
                                const SizedBox(height: AppSpacing.x1),
                                Text(
                                  'QR Code',
                                  style: AppText.label.copyWith(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.x3),
            Text(
              loc.v2SyncCompanionBetaWarning,
              style: AppText.label.copyWith(color: colors.inkMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bleBadge(AppThemeColors colors, AppLocalizations loc) {
    final isBleActive = _bleActive.value ?? false;
    return Tooltip(
      message: isBleActive ? loc.v2SyncLiveActive : loc.v2SyncLiveIdle,
      child: StatusBadge(
        icon: isBleActive ? Icons.bluetooth_connected : Icons.bluetooth,
        color: isBleActive ? colors.energy.gain : colors.control,
        iconColor: isBleActive ? colors.onSelection : colors.inkSubtle,
      ),
    );
  }

  Widget _codeCard(AppLocalizations loc) {
    final colors = AppThemeColors.of(context);
    final state = _pairingState;

    final bool isPending = state is DevicePairingPending;
    String? code;
    if (state is DevicePairingPending) code = state.userCode;
    final bool showCode = isPending && code != null && code.isNotEmpty;

    final String subtitle = _subtitleForState(loc);
    final String description = _descriptionForState(loc);

    return AppCard(
      title: loc.v2SyncCodeTitle,
      subtitle: subtitle,
      badge: _bleBadge(colors, loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            description,
            style: AppText.body.copyWith(color: colors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.x5),
          Center(
            child: Text(
              showCode ? code : '------',
              style: AppText.metricLg.copyWith(
                color: showCode ? colors.ink : colors.inkSubtle,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          if (isPending) ...[
            Center(
              child: Text(
                _expiryText(loc),
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
            ),
            const SizedBox(height: AppSpacing.x5),
          ] else
            const SizedBox(height: AppSpacing.x5),
          _actionsForState(loc),
        ],
      ),
    );
  }

  String _subtitleForState(AppLocalizations loc) {
    if (_checkingReachability) return loc.v2SyncCheckingConnection;
    if (_reachability == BackendReachability.noNetwork) {
      return loc.v2SyncNoNetwork;
    }
    if (_reachability == BackendReachability.backendUnreachable) {
      return loc.v2SyncServerUnreachable;
    }
    if (_pairingStartFailed) {
      return loc.v2SyncPairingStartFailed;
    }
    final s = _pairingState;
    if (s == null || s is DevicePairingIdle) {
      // cancelled idle may still show idle subtitle; distinguish briefly.
      if (s is DevicePairingIdle && s.cancelled) {
        return loc.v2SyncCodeCancelled;
      }
      return loc.v2SyncNoCode;
    }
    if (s is DevicePairingPending) {
      return _expirySubtitle(loc);
    }
    if (s is DevicePairingApproved) return loc.v2SyncPairedConnected;
    if (s is DevicePairingRegistered) return loc.v2SyncRegisteredSubtitle;
    if (s is DevicePairingRevoked) return loc.v2SyncRevokedSubtitle;
    if (s is DevicePairingExpired) return loc.v2SyncCodeExpired;
    if (s is DevicePairingRejected) return loc.v2SyncPairingRejected;
    if (s is DevicePairingInvalidCode) return loc.v2SyncPairingInvalid;
    return loc.v2SyncNoCode;
  }

  String _descriptionForState(AppLocalizations loc) {
    if (_checkingReachability) {
      return loc.v2SyncCheckingBody;
    }
    if (_reachability == BackendReachability.noNetwork) {
      return loc.v2SyncNoNetworkBody;
    }
    if (_reachability == BackendReachability.backendUnreachable) {
      return loc.v2SyncServerUnreachableBody;
    }
    if (_pairingStartFailed) {
      return loc.v2SyncPairingStartFailed;
    }
    final s = _pairingState;
    if (s is DevicePairingPending) {
      return loc.v2SyncPendingBody;
    }
    if (s is DevicePairingApproved) {
      return loc.v2SyncApprovedBody;
    }
    if (s is DevicePairingRegistered) {
      return loc.v2SyncRegisteredBody;
    }
    if (s is DevicePairingRevoked) {
      return loc.v2SyncRevokedBody;
    }
    if (s is DevicePairingExpired) {
      return loc.v2SyncExpiredBody;
    }
    if (s is DevicePairingRejected) {
      return loc.v2SyncRejectedBody;
    }
    if (s is DevicePairingInvalidCode) {
      return loc.v2SyncInvalidBody;
    }
    // idle
    return loc.v2SyncIdleBody;
  }

  String _expirySubtitle(AppLocalizations loc) {
    final secs = _remainingSeconds();
    if (secs == null) return loc.v2SyncExpiresInMinutes;
    return _expiryClock(loc, secs);
  }

  String _expiryText(AppLocalizations loc) {
    final secs = _remainingSeconds();
    if (secs == null) return loc.v2SyncExpiresInMinutes;
    return _expiryClock(loc, secs);
  }

  String _expiryClock(AppLocalizations loc, int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    if (m > 0) {
      return loc.v2SyncExpiresInClock(m, s.toString().padLeft(2, '0'));
    }
    return loc.v2SyncExpiresInSecs(s);
  }

  int? _remainingSeconds() {
    final s = _pairingState;
    if (s is! DevicePairingPending) return null;
    final raw = s.expiresAt;
    if (raw == null) return null;
    final expiry = DateTime.tryParse(raw);
    if (expiry == null) return null;
    final now = DateTime.now().toUtc();
    final diff = expiry.difference(now).inSeconds;
    return diff > 0 ? diff : 0;
  }

  Widget _actionsForState(AppLocalizations loc) {
    if (_checkingReachability) {
      return const Center(
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_reachability == BackendReachability.noNetwork ||
        _reachability == BackendReachability.backendUnreachable) {
      return Row(
        children: [
          Expanded(
            child: SoftActionTile(
              icon: Icons.refresh,
              label: loc.v2SyncRetry,
              centered: true,
              onPressed: _busy ? null : _startPairingFlow,
            ),
          ),
        ],
      );
    }
    if (_pairingStartFailed) {
      return Row(
        children: [
          Expanded(
            child: SoftActionTile(
              icon: Icons.refresh,
              label: loc.v2SyncRetry,
              centered: true,
              onPressed: _busy ? null : _startPairingFlow,
            ),
          ),
        ],
      );
    }
    final s = _pairingState;
    if (s is DevicePairingPending) {
      return Row(
        children: [
          Expanded(
            child: SoftActionTile(
              icon: Icons.qr_code_2,
              label: loc.v2SyncCreateCode,
              centered: true,
              onPressed: null,
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: SoftActionTile(
              icon: Icons.close,
              label: loc.v2SyncCancelCode,
              centered: true,
              onPressed: _busy ? null : _cancelCode,
            ),
          ),
        ],
      );
    }
    if (s is DevicePairingApproved) {
      return Row(
        children: [
          Expanded(
            child: SoftActionTile(
              icon: Icons.check_circle,
              label: loc.v2SyncPaired,
              centered: true,
              onPressed: null,
            ),
          ),
        ],
      );
    }
    if (s is DevicePairingRegistered) {
      return Row(
        children: [
          Expanded(
            child: SoftActionTile(
              icon: Icons.qr_code_2,
              label: loc.v2SyncCreateCode,
              centered: true,
              onPressed: _busy ? null : _startPairingFlow,
            ),
          ),
        ],
      );
    }
    if (s is DevicePairingExpired ||
        s is DevicePairingRejected ||
        s is DevicePairingInvalidCode ||
        s is DevicePairingRevoked) {
      return Row(
        children: [
          Expanded(
            child: SoftActionTile(
              icon: Icons.qr_code_2,
              label: loc.v2SyncCreateCode,
              centered: true,
              onPressed: _busy ? null : _startPairingFlow,
            ),
          ),
        ],
      );
    }
    // idle
    return Row(
      children: [
        Expanded(
          child: SoftActionTile(
            icon: Icons.qr_code_2,
            label: loc.v2SyncCreateCode,
            centered: true,
            onPressed: _busy ? null : _startPairingFlow,
          ),
        ),
        const SizedBox(width: AppSpacing.x3),
        Expanded(
          child: SoftActionTile(
            icon: Icons.close,
            label: loc.v2SyncCancelCode,
            centered: true,
            onPressed: null,
          ),
        ),
      ],
    );
  }

  /// The one button that uploads to the cloud right now, and what it did.
  ///
  /// Every line here is a fact the car reported. While the upload runs the
  /// button shows a spinner instead of accepting more taps; afterward the
  /// result names the rows that moved, or the failure — never an optimistic
  /// "done".
  Widget _cloudSyncCard(AppLocalizations loc) {
    final colors = AppThemeColors.of(context);
    final bool disabled = _busy || _forcing;
    final progress = _syncProgress.value;
    return AppCard(
      title: loc.v2SyncCloudTitle,
      subtitle: _forcing ? loc.v2SyncCloudRunning : loc.v2SyncCloudSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (progress != null) ...[
            SyncProgressBar(
              progress: progress,
              label: loc.v2SyncProgressLabel,
              statusText: _progressStatus(loc, progress),
              detailText: loc.v2SyncProgressDetail(
                progress.cleanCount,
                progress.totalCount,
              ),
            ),
            const SizedBox(height: AppSpacing.x4),
          ],
          Row(
            children: [
              Expanded(
                child: SoftActionTile(
                  icon: _forcing ? Icons.sync : Icons.cloud_upload,
                  label: _forcing ? loc.v2SyncCloudRunning : loc.v2SyncForce,
                  centered: true,
                  onPressed: disabled ? null : () => _forceSync(loc),
                ),
              ),
            ],
          ),
          if (_forcing) ...[
            const SizedBox(height: AppSpacing.x3),
            const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
          if (_forceResult != null) ...[
            const SizedBox(height: AppSpacing.x2),
            Text(
              _forceResult!,
              style: AppText.label.copyWith(color: colors.ink),
            ),
          ],
          const SizedBox(height: AppSpacing.x2),
          Text(
            loc.v2SyncCloudNote,
            style: AppText.caption.copyWith(color: colors.inkSubtle),
          ),
        ],
      ),
    );
  }
}

class _PlatformButton extends StatelessWidget {
  const _PlatformButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Material(
      color: selected ? colors.selectionFill : Colors.transparent,
      borderRadius: AppRadii.smRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.smRadius,
        // Icon above label: three platforms share a quarter-width card, and
        // side by side the label would be cut to "And…". The label scales
        // down rather than truncating.
        child: Container(
          height: AppSizes.actionRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: AppSizes.iconSm,
                color: selected ? colors.onSelection : colors.ink,
              ),
              const SizedBox(height: AppSpacing.x1),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: AppText.bodyStrong.copyWith(
                    color: selected ? colors.onSelection : colors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
