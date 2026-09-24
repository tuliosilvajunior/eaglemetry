import 'dart:async';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../abrp/abrp_settings_store.dart';
import '../abrp/abrp_telemetry_forwarder.dart';
import '../sync/cloud_migration.dart';
import '../ble/live_telemetry_ble_client.dart';
import '../l10n/app_localizations.dart';
import '../pairing/device_pairing_gateway.dart';
import '../sync/pairing_controller.dart';
import '../sync/sync_controller.dart';
import '../sync/cloud_run_report.dart';
import 'companion_shell.dart';

/// The Sync destination. Unpaired: type the car's 6-digit code. Paired: pull and stream.
///
/// It draws no `Scaffold`. The shell owns the canvas and the pill row, and a
/// destination that painted its own would put a second surface between the two.
/// The one caller that shows this screen alone wraps it itself.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.pairing,
    this.sync,
    this.ble,
    this.abrpForwarder,
    this.abrpSettings,
    this.cloudMigration,
    this.active = true,
    super.key,
  });

  final PairingController pairing;

  /// Absent until the runtime is up, and absent in a test that only exercises
  /// pairing. A screen with no engine behind it must not offer to run one.
  final SyncController? sync;

  /// Optional BLE client for car live telemetry streaming.
  final LiveTelemetryBleClient? ble;

  /// Optional forwarder for ABRP live telemetry.
  final AbrpTelemetryForwarder? abrpForwarder;

  /// The beta switch that gates the live stream. The card is absent while it
  /// is off, because the radio is off with it and there is nothing to show.
  final AbrpSettingsStore? abrpSettings;

  /// One-time migration (Phase 4 Step 2) — plain state the reader can see.
  final CloudMigration? cloudMigration;

  /// Whether this destination is the one the reader is looking at.
  ///
  /// Being mounted is not enough: the shell is a `PageView`, so the
  /// neighbouring page is built before it is shown and stays built after it
  /// is left. The counts are re-read when it becomes the page on screen, so a
  /// reader who opens the tab sees what is true now rather than what was true
  /// at the last run.
  final bool active;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _followActive();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active || oldWidget.sync != widget.sync) {
      _followActive();
    }
  }

  void _followActive() {
    if (!widget.active) return;
    // Reading the database is the whole cost, and it happens once per tab
    // visit rather than on every rebuild.
    widget.sync?.refreshCounts();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pairing = widget.pairing;
    final controller = widget.sync;
    final ble = widget.ble;
    final listenables = <Listenable?>[
      pairing,
      controller,
      ble,
      widget.abrpSettings,
      widget.cloudMigration,
    ].whereType<Listenable>().toList();

    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenTitle(l10n.syncTitle),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x6,
                  0,
                  AppSpacing.x6,
                  AppSpacing.x6,
                ),
                children: [
                  if (pairing.isPaired) ...[
                    if (ble != null &&
                        (widget.abrpSettings?.enabled ?? false)) ...[
                      _BleLiveCard(ble: ble, forwarder: widget.abrpForwarder),
                      const SizedBox(height: AppSpacing.x4),
                    ],
                    if (widget.cloudMigration != null) ...[
                      _CloudMigrationCard(migration: widget.cloudMigration!),
                      const SizedBox(height: AppSpacing.x4),
                    ],
                    if (controller != null) ...[
                      _SyncCard(sync: controller),
                      const SizedBox(height: AppSpacing.x4),
                      _LastSyncCard(sync: controller),
                      const SizedBox(height: AppSpacing.x4),
                      _WipeRow(sync: controller),
                      const SizedBox(height: AppSpacing.x4),
                    ],
                    _PairedCard(pairing: pairing),
                  ] else
                    _PairingCard(pairing: pairing),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PairingCard extends StatefulWidget {
  const _PairingCard({required this.pairing});

  final PairingController pairing;

  @override
  State<_PairingCard> createState() => _PairingCardState();
}

class _PairingCardState extends State<_PairingCard> {
  late final TextEditingController _code;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() {
    return widget.pairing.submit(_code.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final pairing = widget.pairing;
    final String? error;
    final bool showRetry;
    if (pairing.signedOut) {
      error = l10n.pairingSignedOut;
      showRetry = false;
    } else if (pairing.connectivity == BackendReachability.noNetwork) {
      error = l10n.pairingNoNetwork;
      showRetry = true;
    } else if (pairing.connectivity == BackendReachability.backendUnreachable) {
      error = l10n.pairingBackendUnreachable;
      showRetry = true;
    } else if (pairing.error == PairingError.invalidCode) {
      error = l10n.pairingInvalidCode;
      showRetry = false;
    } else {
      final mapped = switch (pairing.lastResult) {
        ClaimNotFound() => l10n.pairingNotFound,
        ClaimExpired() => l10n.pairingExpired,
        ClaimAlreadyClaimed() => l10n.pairingAlreadyClaimed,
        ClaimVehicleAlreadyClaimed() => l10n.pairingVehicleAlreadyClaimed,
        ClaimNetwork() => l10n.pairingNetworkError,
        ClaimUnknown() => l10n.pairingUnknownError,
        ClaimAlreadyOwnedBySelf() => null,
        ClaimSuccessResult() => null,
        null => null,
      };
      error = mapped;
      showRetry = pairing.lastResult is ClaimNetwork;
    }
    return AppCard(
      title: l10n.pairingTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.pairingBody,
            style: AppText.body.copyWith(color: colors.ink),
          ),
          const SizedBox(height: AppSpacing.x4),
          TextField(
            key: const Key('pairing-code-field'),
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            enabled: !pairing.busy,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppText.metricMd.copyWith(color: colors.ink),
            decoration: InputDecoration(
              counterText: '',
              hintText: l10n.pairingCodeHint,
              hintStyle: AppText.metricMd.copyWith(color: colors.inkSubtle),
              filled: true,
              fillColor: colors.control,
              border: OutlineInputBorder(
                borderRadius: AppRadii.mdRadius,
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: pairing.busy ? null : (_) => _submit(),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.x3),
            Text(
              error,
              key: const Key('pairing-error'),
              style: AppText.body.copyWith(color: colors.energy.critical),
            ),
            if (showRetry) ...[
              const SizedBox(height: AppSpacing.x2),
              TextButton(
                key: const Key('pairing-retry'),
                onPressed: pairing.busy ? null : _submit,
                child: Text(l10n.pairingRetry),
              ),
            ],
          ],
          const SizedBox(height: AppSpacing.x4),
          SoftActionTile(
            label: l10n.pairingAction,
            onPressed: pairing.busy ? null : _submit,
          ),
        ],
      ),
    );
  }
}

class _PairedCard extends StatelessWidget {
  const _PairedCard({required this.pairing});

  final PairingController pairing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return AppCard(
      title: l10n.homePairedTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.homePairedBody,
            style: AppText.body.copyWith(color: colors.ink),
          ),
          const SizedBox(height: AppSpacing.x4),
          SoftActionTile(
            label: l10n.pairingForget,
            onPressed: pairing.busy ? null : pairing.unpair,
          ),
        ],
      ),
    );
  }
}

/// One [SyncOutcomeKind] as the line the reader sees.
///
/// A function rather than a `switch` inside `build`, so every kind can be
/// read back in a test. A test build compiles with the cloud gate off, which
/// folds `failed`, `phoneOffline` and `carSilent` into the gate-off reading
/// before a widget ever draws them; through the widget alone those three
/// lines could not be checked at all.
String syncOutcomeLine(
  AppLocalizations l10n,
  SyncOutcomeKind kind,
  SyncRunReport? report,
) {
  return switch (kind) {
    SyncOutcomeKind.neverRun => l10n.syncNeverRun,
    SyncOutcomeKind.completed => l10n.syncResultCompleted(
      report?.ackedRecords ?? 0,
    ),
    // The cloud answered but the car sent nothing: not an empty car, the
    // car has not uploaded. Names the car's link, not this phone's.
    SyncOutcomeKind.carSilent => l10n.syncResultCarSilent,
    SyncOutcomeKind.nothingNew => l10n.syncResultNothing,
    // The build has cloud sync off: there is nothing to pull with.
    // Blaming the car or the connection would send the reader fixing the
    // wrong end.
    SyncOutcomeKind.cloudDisabled => l10n.syncResultCloudDisabled,
    // This phone could not reach the cloud: its own connection, not the car's.
    SyncOutcomeKind.phoneOffline => l10n.syncResultPhoneOffline,
    SyncOutcomeKind.failed => l10n.syncResultFailed,
  };
}

/// Runs one pull and says what the last one did.
class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.sync});

  final SyncController sync;

  /// The order the engine pulls in, stated so all four streams are listed from
  /// the first frame of a run rather than appearing one at a time. A stream
  /// with no page yet is waiting, not missing.
  static const _order = [
    SyncStreamType.sessions,
    SyncStreamType.batteryCycles,
    SyncStreamType.intervals,
    SyncStreamType.events,
    SyncStreamType.tracks,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final report = sync.lastReport;
    final at = sync.lastRunAt;
    final outcome = syncOutcomeLine(l10n, syncOutcomeKind(report), report);
    final pending = sync.pendingCount;
    return AppCard(
      title: l10n.syncTitle,
      subtitle: l10n.syncHolding(sync.tripCount, sync.chargeCount),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            outcome,
            key: const Key('sync-outcome'),
            style: AppText.body.copyWith(color: colors.ink),
          ),
          if (at != null && !sync.busy) ...[
            const SizedBox(height: AppSpacing.x1),
            Text(
              l10n.syncLastRun(TimeOfDay.fromDateTime(at).format(context)),
              style: AppText.label.copyWith(color: colors.inkMuted),
            ),
          ],
          if (sync.busy) ...[
            const SizedBox(height: AppSpacing.x3),
            Column(
              key: const Key('sync-progress'),
              children: [
                for (final stream in _order)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.x3),
                    child: _StreamLine(
                      stream: stream,
                      page: sync.pages[stream],
                    ),
                  ),
              ],
            ),
          ] else ...[
            // What is still to send, in one line the reader can act on. It is
            // the phone's own outbox, not a total the car reported: this phone
            // can always answer it, so the line is never absent and never a
            // guess.
            const SizedBox(height: AppSpacing.x3),
            Text(
              pending > 0 ? l10n.syncPending(pending) : l10n.syncNothingPending,
              key: const Key('sync-pending'),
              style: AppText.body.copyWith(
                color: pending > 0 ? colors.ink : colors.inkMuted,
              ),
            ),
          ],
          if (sync.syncProgress != null) ...[
            const SizedBox(height: AppSpacing.x4),
            SyncProgressBar(
              progress: sync.syncProgress!,
              label: l10n.syncProgressLabel,
              statusText: sync.syncProgress!.isUpToDate
                  ? l10n.syncProgressUpToDate
                  : l10n.syncProgressPending(sync.syncProgress!.dirtyCount),
              detailText: l10n.syncProgressDetail(
                sync.syncProgress!.cleanCount,
                sync.syncProgress!.totalCount,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.x4),
          SoftActionTile(
            key: const Key('sync-now'),
            label: sync.busy ? l10n.syncRunning : l10n.syncAction,
            onPressed: sync.busy ? null : sync.runNow,
          ),
          const SizedBox(height: AppSpacing.x3),
          // The button is a stopgap and says so. Sync runs by itself; the
          // press exists only while the reader still needs to prove it.
          Text(
            l10n.syncAutoNote,
            key: const Key('sync-auto-note'),
            style: AppText.label.copyWith(color: colors.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// One-time cloud migration status — plain text the reader can see.
class _CloudMigrationCard extends StatelessWidget {
  const _CloudMigrationCard({required this.migration});
  final CloudMigration migration;
  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final state = migration.state;
    final label = switch (state) {
      CloudMigrationState.syncing => 'Syncing your history to the cloud...',
      CloudMigrationState.failed =>
        'Cloud migration failed: ${migration.error ?? 'unknown'} — will retry when online.',
      CloudMigrationState.done => 'History synced to cloud.',
      CloudMigrationState.idle => null,
    };
    if (label == null) return const SizedBox.shrink();
    final isFailure = state == CloudMigrationState.failed;
    return AppCard(
      title: 'Cloud migration',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            key: const Key('cloud-migration-status'),
            style: AppText.body.copyWith(
              color: isFailure ? colors.energy.critical : colors.ink,
            ),
          ),
          if (state == CloudMigrationState.syncing) ...[
            const SizedBox(height: AppSpacing.x2),
            ClipRRect(
              borderRadius: AppRadii.smRadius,
              child: const LinearProgressIndicator(minHeight: 5),
            ),
          ],
        ],
      ),
    );
  }
}

/// One stream of the run in flight.
///
/// The bar is drawn only when the car said how much is left. A car built
/// before 2026-08-18 does not send that, and the frames stream never does, so
/// a bar with no denominator would sit full while the transfer is still
/// running — worse than no bar. Those streams get a counter instead.
class _StreamLine extends StatelessWidget {
  const _StreamLine({required this.stream, required this.page});

  final SyncStreamType stream;

  /// Null while the run has not reached this stream. The engine pulls in a
  /// fixed order, so that is "waiting", never "failed".
  final SyncProgress? page;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final name = streamName(l10n, stream);
    final page = this.page;
    final waiting = page == null;
    final remaining = page?.remaining;
    final line = waiting
        ? l10n.syncStreamWaiting
        : remaining == null
        ? l10n.onboardingWritten(page.recordsWritten)
        : l10n.onboardingCounted(
            page.recordsWritten,
            page.recordsWritten + remaining,
          );
    final fraction = page?.fraction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: waiting ? colors.track : colors.selectionFill,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: Text(
                name,
                style: AppText.label.copyWith(
                  color: waiting ? colors.inkSubtle : colors.ink,
                ),
              ),
            ),
            Text(line, style: AppText.label.copyWith(color: colors.inkMuted)),
          ],
        ),
        // Frames carry their own scale. Weighting one bar by record count
        // would leave it near zero for the whole transfer, because a session
        // holds thousands of frames and the summary streams hold dozens.
        if (page?.sessionIndex case final index?)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.x4),
            child: Text(
              l10n.syncProgressSession(index, page!.sessionCount ?? index),
              style: AppText.label.copyWith(color: colors.inkMuted),
            ),
          ),
        if (fraction != null) ...[
          const SizedBox(height: AppSpacing.x2),
          ClipRRect(
            borderRadius: AppRadii.smRadius,
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 5,
              backgroundColor: colors.track,
              color: colors.selectionFill,
            ),
          ),
        ],
      ],
    );
  }
}

/// What the last sync brought down, stream by stream.
///
/// The cloud pull reads every row the account holds and upserts it, so the
/// count beside a stream is what that stream holds in the cloud as well as on
/// this phone — the two are the same list after a run that completed. That is
/// the reading the card states, and it is why it appears only after a run: the
/// phone cannot name a cloud total it has not fetched.
///
/// It replaced a card drawn from the car's own inventory. That number arrived
/// over the local link, which production retired, so the card never drew at
/// all in a real build and the reader could not see what had synced.
class _LastSyncCard extends StatelessWidget {
  const _LastSyncCard({required this.sync});

  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    if (sync.busy || sync.pages.isEmpty) return const SizedBox.shrink();
    final rows = syncedRows(l10n, sync.pages);
    if (rows.isEmpty) return const SizedBox.shrink();
    return AppCard(
      key: const Key('sync-last-run'),
      title: l10n.syncLastRunTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      row.label,
                      style: AppText.body.copyWith(color: colors.ink),
                    ),
                  ),
                  Text(
                    '${row.records}',
                    style: AppText.label.copyWith(color: colors.inkMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Deletes what this phone pulled.
///
/// It sits outside the cards, as a row of its own. Inside the sync card it
/// read as one more thing sync does; the rows it clears are the app's whole
/// content, so it is its own act.
class _WipeRow extends StatelessWidget {
  const _WipeRow({required this.sync});

  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return Material(
      color: colors.surface,
      borderRadius: AppRadii.lgRadius,
      child: InkWell(
        key: const Key('sync-wipe'),
        borderRadius: AppRadii.lgRadius,
        // Asked before it happens, not undone after. The rows are recoverable
        // from the car and the pairing survives, but a full re-pull is minutes
        // of transfer, so the reader gets to say whether that is what they
        // meant.
        onTap: sync.busy ? null : () => _confirmWipe(context, sync),
        child: Container(
          constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: colors.energy.critical),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Text(
                  l10n.syncWipeAction,
                  style: AppText.body.copyWith(color: colors.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _confirmWipe(BuildContext context, SyncController sync) async {
  final l10n = AppLocalizations.of(context)!;
  final colors = AppThemeColors.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        l10n.syncWipeTitle,
        style: AppText.cardTitle.copyWith(color: colors.ink),
      ),
      content: Text(
        l10n.syncWipeBody,
        style: AppText.body.copyWith(color: colors.inkMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.syncWipeCancel),
        ),
        TextButton(
          key: const Key('sync-wipe-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            l10n.syncWipeConfirm,
            style: TextStyle(color: colors.energy.critical),
          ),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await sync.wipe();
}

/// One line of the last run: a name a reader knows, and how much arrived.
class SyncedRow {
  const SyncedRow({required this.label, required this.records});

  final String label;
  final int records;
}

/// The last run's pages as lines, one per name rather than one per stream.
///
/// Five of the car's streams — places, journeys, preferences, session costs
/// and preference proposals — are one thing to a reader, and they are all
/// spelled "Annotations". Drawn per stream, the card listed that word five
/// times with five different counts beside it, which reads as five unrelated
/// things rather than as one. The streams stay separate on the wire, because
/// they are separate cursors and separate acks; only the reading is folded.
List<SyncedRow> syncedRows(
  AppLocalizations l10n,
  Map<SyncStreamType, SyncProgress> pages,
) {
  final rows = <String, SyncedRow>{};
  for (final entry in pages.entries) {
    final label = streamName(l10n, entry.key);
    final records = entry.value.recordsWritten;
    final seen = rows[label];
    rows[label] = SyncedRow(
      label: label,
      records: (seen?.records ?? 0) + records,
    );
  }
  return rows.values.toList();
}

/// The one place a stream is spelled for a reader.
String streamName(AppLocalizations l10n, SyncStreamType stream) {
  return switch (stream) {
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
}

class _BleLiveCard extends StatefulWidget {
  const _BleLiveCard({required this.ble, this.forwarder});

  final LiveTelemetryBleClient ble;
  final AbrpTelemetryForwarder? forwarder;

  @override
  State<_BleLiveCard> createState() => _BleLiveCardState();
}

class _BleLiveCardState extends State<_BleLiveCard> {
  LiveTelemetrySnapshot? _latestSnapshot;
  StreamSubscription<LiveTelemetrySnapshot>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.ble.snapshotStream.listen((snap) {
      if (mounted) {
        setState(() => _latestSnapshot = snap);
      }
    });
  }

  void _triggerConnect() {
    widget.ble.retryNow();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final ble = widget.ble;
    final forwarder = widget.forwarder;
    final snap = _latestSnapshot;

    final (badgeLabel, badgeColor) = switch (ble.state) {
      BleConnectionState.streaming => ('Live', Colors.green),
      BleConnectionState.scanning => ('Scanning...', Colors.orange),
      BleConnectionState.connecting => ('Connecting...', Colors.orange),
      BleConnectionState.error => ('Error', Colors.red),
      BleConnectionState.disconnected => ('Disconnected', colors.inkSubtle),
    };

    return AppCard(
      key: const Key('sync-ble-card'),
      title: 'Bluetooth Live Stream',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.bluetooth, size: 20, color: colors.ink),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Text(
                  'Car Live Telemetry',
                  style: AppText.body.copyWith(color: colors.ink),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x3,
                  vertical: AppSpacing.x1,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: AppRadii.fullRadius,
                ),
                child: Text(
                  badgeLabel,
                  style: AppText.label.copyWith(color: badgeColor),
                ),
              ),
            ],
          ),
          if (snap != null) ...[
            const SizedBox(height: AppSpacing.x4),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4,
                vertical: AppSpacing.x3,
              ),
              decoration: BoxDecoration(
                color: colors.control,
                borderRadius: AppRadii.mdRadius,
              ),
              child: Row(
                children: [
                  if (snap.socPercent != null)
                    Expanded(
                      child: StatColumn(
                        caption: 'Battery',
                        value: snap.socPercent!.toStringAsFixed(1),
                        unit: '%',
                      ),
                    ),
                  if (snap.speedKmh != null) ...[
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: StatColumn(
                        caption: 'Speed',
                        value: '${snap.speedKmh!.round()}',
                        unit: 'km/h',
                      ),
                    ),
                  ],
                  if (snap.powerKw != null) ...[
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: StatColumn(
                        caption: 'Power',
                        value:
                            '${snap.powerKw! > 0 ? "+" : ""}${snap.powerKw!.toStringAsFixed(1)}',
                        unit: 'kW',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (ble.state == BleConnectionState.disconnected ||
              ble.state == BleConnectionState.error) ...[
            const SizedBox(height: AppSpacing.x3),
            SoftActionTile(
              icon: Icons.bluetooth_searching,
              label: 'Connect BLE Live Stream',
              centered: true,
              onPressed: _triggerConnect,
            ),
          ] else if (ble.state == BleConnectionState.scanning) ...[
            const SizedBox(height: AppSpacing.x3),
            Center(
              child: Text(
                'Searching for vehicle Bluetooth signal...',
                style: AppText.caption.copyWith(color: colors.inkMuted),
              ),
            ),
          ],
          if (forwarder != null) ...[
            const SizedBox(height: AppSpacing.x3),
            AnimatedBuilder(
              animation: forwarder,
              builder: (context, _) {
                final status = forwarder.status;
                final text = switch (status.state) {
                  AbrpForwarderState.streaming =>
                    'ABRP Forwarder: Active (posting live data)',
                  AbrpForwarderState.idle =>
                    'ABRP Forwarder: Waiting for car stream',
                  AbrpForwarderState.error =>
                    'ABRP Forwarder: ${status.lastError ?? "Error"}',
                  AbrpForwarderState.disabled =>
                    'ABRP Forwarder: Disabled in Settings',
                };
                return Text(
                  text,
                  style: AppText.caption.copyWith(color: colors.inkMuted),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
