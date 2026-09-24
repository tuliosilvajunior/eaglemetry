import 'package:flutter/material.dart';

import '../../core/telemetry_format.dart';

/// A clock time as `HH:mm`, or `--` when the car never recorded one.
String historyClock(int? millis) {
  final value = dateTimeFromMillis(millis);
  if (value == null) return '--';
  return '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}

/// A moment as the head unit's own clock writes it, so an axis label and a
/// tooltip cannot disagree about 24-hour time.
String historyClockLabel(BuildContext context, DateTime value) {
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(value),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}

/// A charge chart plots seconds from the start of the window, not clock times.
DateTime historyOffset(DateTime start, double seconds) =>
    start.add(Duration(milliseconds: (seconds * 1000).round()));
