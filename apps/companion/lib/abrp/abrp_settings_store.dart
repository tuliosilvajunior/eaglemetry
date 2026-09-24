import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract class AbrpSettingsStore implements Listenable {
  bool get enabled;
  String? get userToken;

  /// The user's own Iternio API key. Null means the key built into the app.
  /// Iternio rate-limits per key, so a shared key cannot serve every user.
  String? get apiKey;
  int get uploadIntervalSeconds;
  String? get carModel;

  Future<void> setEnabled(bool value);
  Future<void> setUserToken(String? value);
  Future<void> setApiKey(String? value);
  Future<void> setUploadIntervalSeconds(int value);
  Future<void> setCarModel(String? value);
}

/// Persistent ABRP settings backed by a JSON file in the companion app documents directory.
/// In-memory fallback when [directory] is null (used by tests).
class FileAbrpSettingsStore extends ChangeNotifier
    implements AbrpSettingsStore {
  FileAbrpSettingsStore({
    Directory? directory,
    this._enabled = false,
    this._userToken,
    this._apiKey,
    this._uploadIntervalSeconds = 5,
    this._carModel = 'geely:geometry_e:23:39:other',
  }) : _file = directory == null
           ? null
           : File('${directory.path}/abrp_settings.json');

  final File? _file;
  bool _enabled;
  String? _userToken;
  String? _apiKey;
  int _uploadIntervalSeconds;
  String? _carModel;

  @override
  bool get enabled => _enabled;

  @override
  String? get userToken => _userToken;

  @override
  String? get apiKey => _apiKey;

  @override
  int get uploadIntervalSeconds => _uploadIntervalSeconds;

  @override
  String? get carModel => _carModel;

  Future<void> load() async {
    final file = _file;
    if (file == null || !file.existsSync()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        _enabled = decoded['enabled'] == true;
        _userToken = decoded['userToken'] as String?;
        _apiKey = decoded['apiKey'] as String?;
        if (decoded['uploadIntervalSeconds'] is int) {
          _uploadIntervalSeconds = decoded['uploadIntervalSeconds'] as int;
        }
        if (decoded['carModel'] is String) {
          _carModel = decoded['carModel'] as String?;
        }
        notifyListeners();
      }
    } on FormatException {
      // Keep defaults on corrupted format
    }
  }

  Future<void> _persist() async {
    final file = _file;
    if (file == null) return;
    final map = <String, dynamic>{
      'enabled': _enabled,
      'userToken': _userToken,
      'apiKey': _apiKey,
      'uploadIntervalSeconds': _uploadIntervalSeconds,
      'carModel': _carModel,
    };
    try {
      await file.writeAsString(jsonEncode(map), flush: true);
    } catch (e) {
      debugPrint('Failed to persist ABRP settings: $e');
    }
  }

  @override
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _persist();
  }

  @override
  Future<void> setUserToken(String? value) async {
    if (_userToken == value) return;
    _userToken = value;
    notifyListeners();
    await _persist();
  }

  @override
  Future<void> setApiKey(String? value) async {
    final next = (value == null || value.trim().isEmpty) ? null : value.trim();
    if (_apiKey == next) return;
    _apiKey = next;
    notifyListeners();
    await _persist();
  }

  @override
  Future<void> setUploadIntervalSeconds(int value) async {
    if (_uploadIntervalSeconds == value) return;
    _uploadIntervalSeconds = value;
    notifyListeners();
    await _persist();
  }

  @override
  Future<void> setCarModel(String? value) async {
    if (_carModel == value) return;
    _carModel = value;
    notifyListeners();
    await _persist();
  }
}
