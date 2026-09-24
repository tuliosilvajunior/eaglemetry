import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import '../sync/journey_store.dart';
import 'history_format.dart';

/// Shows a bottom sheet / modal to create or edit a [Journey].
Future<Journey?> showJourneyEditorSheet({
  required BuildContext context,
  required TelemetryStore store,
  required JourneyStore journeyStore,
  Journey? existing,
  int? initialStartMillis,
  int? initialEndMillis,
}) {
  return showModalBottomSheet<Journey>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _JourneyEditorSheet(
      store: store,
      journeyStore: journeyStore,
      existing: existing,
      initialStartMillis: initialStartMillis,
      initialEndMillis: initialEndMillis,
    ),
  );
}

class _JourneyEditorSheet extends StatefulWidget {
  const _JourneyEditorSheet({
    required this.store,
    required this.journeyStore,
    this.existing,
    this.initialStartMillis,
    this.initialEndMillis,
  });

  final TelemetryStore store;
  final JourneyStore journeyStore;
  final Journey? existing;
  final int? initialStartMillis;
  final int? initialEndMillis;

  @override
  State<_JourneyEditorSheet> createState() => _JourneyEditorSheetState();
}

class _JourneyEditorSheetState extends State<_JourneyEditorSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _noteController;

  late DateTime _startDate;
  late TimeOfDay _startTime;
  late DateTime _endDate;
  late TimeOfDay _endTime;

  int _previewTripCount = 0;
  int _previewChargeCount = 0;
  bool _loadingPreview = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _noteController = TextEditingController(text: existing?.note ?? '');

    final now = DateTime.now();
    final startMillis =
        existing?.startedAtUtcMillis ??
        widget.initialStartMillis ??
        now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final endMillis =
        existing?.endedAtUtcMillis ??
        widget.initialEndMillis ??
        now.millisecondsSinceEpoch;

    final startDt = DateTime.fromMillisecondsSinceEpoch(startMillis);
    final endDt = DateTime.fromMillisecondsSinceEpoch(endMillis);

    _startDate = DateTime(startDt.year, startDt.month, startDt.day);
    _startTime = TimeOfDay(hour: startDt.hour, minute: startDt.minute);
    _endDate = DateTime(endDt.year, endDt.month, endDt.day);
    _endTime = TimeOfDay(hour: endDt.hour, minute: endDt.minute);

    _updatePreview();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  DateTime get _startDateTime => DateTime(
    _startDate.year,
    _startDate.month,
    _startDate.day,
    _startTime.hour,
    _startTime.minute,
  );

  DateTime get _endDateTime => DateTime(
    _endDate.year,
    _endDate.month,
    _endDate.day,
    _endTime.hour,
    _endTime.minute,
  );

  int get _startMillis => _startDateTime.millisecondsSinceEpoch;
  int get _endMillis => _endDateTime.millisecondsSinceEpoch;

  Future<void> _updatePreview() async {
    if (!mounted) return;
    setState(() => _loadingPreview = true);

    try {
      final filter = SessionFilter(
        fromUtcMillis: _startMillis,
        toUtcMillis: _endMillis,
      );
      final page = await widget.store.listSessions(
        filter: filter,
        page: const PageRequest(limit: 500),
      );

      var trips = 0;
      var charges = 0;
      for (final s in page.sessions) {
        if (s.kind == SessionKind.trip) trips++;
        if (s.kind == SessionKind.charge) charges++;
      }

      if (mounted) {
        setState(() {
          _previewTripCount = trips;
          _previewChargeCount = charges;
          _loadingPreview = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingPreview = false);
      }
    }
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    setState(() => _startDate = picked);
    _updatePreview();
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );
    if (picked == null || !mounted) return;
    setState(() => _startTime = picked);
    _updatePreview();
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    setState(() => _endDate = picked);
    _updatePreview();
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );
    if (picked == null || !mounted) return;
    setState(() => _endTime = picked);
    _updatePreview();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Informe um nome para a jornada');
      return;
    }
    if (_endMillis < _startMillis) {
      setState(
        () => _error = 'A data de fim não pode ser anterior à data de início',
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final note = _noteController.text.trim();
      final existing = widget.existing;
      final Journey result;

      if (existing != null) {
        result = await widget.journeyStore.update(
          existing,
          name: name,
          startedAtUtcMillis: _startMillis,
          endedAtUtcMillis: _endMillis,
          note: note.isEmpty ? null : note,
        );
      } else {
        result = await widget.journeyStore.create(
          name: name,
          startedAtUtcMillis: _startMillis,
          endedAtUtcMillis: _endMillis,
          note: note.isEmpty ? null : note,
        );
      }

      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final mediaQuery = MediaQuery.of(context);

    return Container(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppSpacing.x4),
                  decoration: BoxDecoration(
                    color: colors.inkSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Title
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.existing == null
                        ? l10n.journeysNew
                        : l10n.journeyEdit,
                    style: AppText.cardTitle.copyWith(color: colors.ink),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: colors.inkMuted,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x4),

              // Name Field
              Text(
                l10n.journeyName,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.x1),
              TextField(
                controller: _nameController,
                style: AppText.body.copyWith(color: colors.ink),
                decoration: InputDecoration(
                  hintText: l10n.journeyNameHint,
                  hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
                  filled: true,
                  fillColor: colors.surface,
                  border: OutlineInputBorder(
                    borderRadius: AppRadii.mdRadius,
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x4,
                    vertical: AppSpacing.x3,
                  ),
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: AppSpacing.x4),

              // Note Field
              Text(
                l10n.journeyNote,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.x1),
              TextField(
                controller: _noteController,
                style: AppText.body.copyWith(color: colors.ink),
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: l10n.journeyNoteHint,
                  hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
                  filled: true,
                  fillColor: colors.surface,
                  border: OutlineInputBorder(
                    borderRadius: AppRadii.mdRadius,
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x4,
                    vertical: AppSpacing.x3,
                  ),
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: AppSpacing.x4),

              // Date Range Section
              Text(
                l10n.journeyStartDate,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.x1),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: SoftActionTile(
                      label: formatDateTime(
                        _startDate.millisecondsSinceEpoch,
                      ).split(',').first,
                      icon: Icons.calendar_today,
                      onPressed: _pickStartDate,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    flex: 2,
                    child: SoftActionTile(
                      label:
                          '${_startTime.hour.toString().padLeft(2, '0')}:${_startTime.minute.toString().padLeft(2, '0')}',
                      icon: Icons.access_time,
                      onPressed: _pickStartTime,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x3),

              Text(
                l10n.journeyEndDate,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.x1),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: SoftActionTile(
                      label: formatDateTime(
                        _endDate.millisecondsSinceEpoch,
                      ).split(',').first,
                      icon: Icons.calendar_today,
                      onPressed: _pickEndDate,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    flex: 2,
                    child: SoftActionTile(
                      label:
                          '${_endTime.hour.toString().padLeft(2, '0')}:${_endTime.minute.toString().padLeft(2, '0')}',
                      icon: Icons.access_time,
                      onPressed: _pickEndTime,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x4),

              // Live session preview
              Container(
                padding: const EdgeInsets.all(AppSpacing.x3),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: AppRadii.mdRadius,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 18,
                      color: colors.energy.focus,
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: _loadingPreview
                          ? Text(
                              'Calculando viagens...',
                              style: AppText.label.copyWith(
                                color: colors.inkMuted,
                              ),
                            )
                          : Text(
                              l10n.journeySessionsCount(
                                _previewTripCount,
                                _previewChargeCount,
                              ),
                              style: AppText.label.copyWith(color: colors.ink),
                            ),
                    ),
                  ],
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: AppSpacing.x3),
                Text(
                  _error!,
                  style: AppText.label.copyWith(color: colors.energy.critical),
                ),
              ],

              const SizedBox(height: AppSpacing.x6),

              // Save Button
              SizedBox(
                height: AppSizes.minTouchTarget,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.energy.focus,
                    foregroundColor: colors.canvas,
                    shape: RoundedRectangleBorder(
                      borderRadius: AppRadii.mdRadius,
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          l10n.journeySave,
                          style: AppText.bodyStrong.copyWith(
                            color: colors.canvas,
                          ),
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
