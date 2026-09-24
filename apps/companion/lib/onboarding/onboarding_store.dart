import 'dart:convert';
import 'dart:io';

/// Whether this phone has already been through the first-run journey.
///
/// One flag, written once. It is deliberately not the pairing record: a reader
/// who forgets the car has not forgotten the app, and showing the three intro
/// slides again after an unpair would answer a question nobody asked.
///
/// Memory when [directory] is null, which is what a test gets.
class OnboardingStore {
  OnboardingStore({Directory? directory})
    : _file = directory == null
          ? null
          : File('${directory.path}/onboarding.json');

  final File? _file;

  bool _seen = false;

  bool get seen => _seen;

  /// Reads the flag. A file that cannot be parsed counts as never seen: the
  /// journey is short and repeating it costs the reader less than skipping a
  /// pairing step they never reached.
  Future<void> load() async {
    final file = _file;
    if (file == null || !file.existsSync()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      _seen = decoded is Map && decoded['seen'] == true;
    } on FormatException {
      _seen = false;
    }
  }

  Future<void> markSeen() async {
    _seen = true;
    await _file?.writeAsString(jsonEncode({'seen': true}), flush: true);
  }
}
