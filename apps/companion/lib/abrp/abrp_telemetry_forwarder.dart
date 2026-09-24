import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'abrp_client.dart';
import 'abrp_settings_store.dart';

enum AbrpForwarderState { disabled, idle, streaming, error }

class AbrpForwarderStatus {
  final AbrpForwarderState state;
  final int? lastUploadedUtcMillis;
  final String? lastError;

  const AbrpForwarderStatus({
    required this.state,
    this.lastUploadedUtcMillis,
    this.lastError,
  });

  static const AbrpForwarderStatus initial = AbrpForwarderStatus(
    state: AbrpForwarderState.disabled,
  );
}

typedef AbrpSender =
    Future<AbrpSendResult> Function(
      LiveTelemetrySnapshot snapshot,
      String userToken,
    );

/// Coordinates rate-limited live telemetry forwarding to ABRP.
class AbrpTelemetryForwarder extends ChangeNotifier {
  final AbrpSettingsStore settingsStore;
  final AbrpSender clientSender;

  AbrpForwarderStatus _status = AbrpForwarderStatus.initial;
  AbrpForwarderStatus get status => _status;

  int? _lastPostedUtcMillis;
  bool _inFlight = false;

  AbrpTelemetryForwarder({
    required this.settingsStore,
    required this.clientSender,
  }) {
    settingsStore.addListener(_onSettingsChanged);
    _onSettingsChanged();
  }

  /// Factory constructing forwarder with a live [AbrpClient].
  factory AbrpTelemetryForwarder.create({
    required AbrpSettingsStore settingsStore,
    AbrpClient? client,
  }) {
    final effectiveClient = client ?? AbrpClient();
    return AbrpTelemetryForwarder(
      settingsStore: settingsStore,
      clientSender: (snapshot, token) => effectiveClient.sendTelemetry(
        userToken: token,
        snapshot: snapshot,
        carModel: settingsStore.carModel,
        apiKeyOverride: settingsStore.apiKey,
      ),
    );
  }

  void _onSettingsChanged() {
    if (!settingsStore.enabled) {
      _updateStatus(
        const AbrpForwarderStatus(state: AbrpForwarderState.disabled),
      );
    } else if (settingsStore.userToken == null ||
        settingsStore.userToken!.trim().isEmpty) {
      _updateStatus(
        const AbrpForwarderStatus(
          state: AbrpForwarderState.disabled,
          lastError: 'ABRP user token not configured',
        ),
      );
    } else if (settingsStore.apiKey == null ||
        settingsStore.apiKey!.trim().isEmpty) {
      _updateStatus(
        const AbrpForwarderStatus(
          state: AbrpForwarderState.disabled,
          lastError: AbrpClient.missingApiKeyError,
        ),
      );
    } else if (_status.state == AbrpForwarderState.disabled) {
      _updateStatus(const AbrpForwarderStatus(state: AbrpForwarderState.idle));
    }
  }

  @override
  void dispose() {
    settingsStore.removeListener(_onSettingsChanged);
    super.dispose();
  }

  /// Processes an incoming snapshot received from the car.
  Future<void> onSnapshotReceived(LiveTelemetrySnapshot snapshot) async {
    if (_inFlight) return;

    if (!settingsStore.enabled) {
      _updateStatus(
        const AbrpForwarderStatus(state: AbrpForwarderState.disabled),
      );
      return;
    }

    final token = settingsStore.userToken;
    if (token == null || token.trim().isEmpty) {
      _updateStatus(
        const AbrpForwarderStatus(
          state: AbrpForwarderState.disabled,
          lastError: 'ABRP user token not configured',
        ),
      );
      return;
    }

    final apiKey = settingsStore.apiKey;
    if (apiKey == null || apiKey.trim().isEmpty) {
      _updateStatus(
        const AbrpForwarderStatus(
          state: AbrpForwarderState.disabled,
          lastError: AbrpClient.missingApiKeyError,
        ),
      );
      return;
    }

    final intervalMillis = settingsStore.uploadIntervalSeconds * 1000;
    final lastUpload = _lastPostedUtcMillis;
    if (lastUpload != null &&
        (snapshot.utcMillis - lastUpload) < intervalMillis) {
      // Rate-limited, skip upload.
      return;
    }

    _inFlight = true;
    try {
      final result = await clientSender(snapshot, token);
      if (result.isSuccess) {
        _lastPostedUtcMillis = snapshot.utcMillis;
        _updateStatus(
          AbrpForwarderStatus(
            state: AbrpForwarderState.streaming,
            lastUploadedUtcMillis: snapshot.utcMillis,
          ),
        );
      } else {
        _updateStatus(
          AbrpForwarderStatus(
            state: AbrpForwarderState.error,
            lastUploadedUtcMillis: _lastPostedUtcMillis,
            lastError: result.errorMessage,
          ),
        );
      }
    } finally {
      _inFlight = false;
    }
  }

  void _updateStatus(AbrpForwarderStatus newStatus) {
    _status = newStatus;
    notifyListeners();
  }
}
