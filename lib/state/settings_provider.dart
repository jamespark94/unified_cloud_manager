import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  final String defaultDownloadPath;
  final bool askDownloadPathEveryTime;

  const AppSettings({
    required this.defaultDownloadPath,
    required this.askDownloadPathEveryTime,
  });

  AppSettings copyWith({
    String? defaultDownloadPath,
    bool? askDownloadPathEveryTime,
  }) {
    return AppSettings(
      defaultDownloadPath: defaultDownloadPath ?? this.defaultDownloadPath,
      askDownloadPathEveryTime: askDownloadPathEveryTime ?? this.askDownloadPathEveryTime,
    );
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  static const String _keyDefaultPath = 'setting_default_download_path';
  static const String _keyAskEveryTime = 'setting_ask_download_path_every_time';

  SettingsNotifier() : super(const AppSettings(defaultDownloadPath: '', askDownloadPathEveryTime: true)) {
    loadSettings();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedPath = prefs.getString(_keyDefaultPath);
    if (savedPath == null || savedPath.isEmpty) {
      try {
        final docDir = await getApplicationDocumentsDirectory();
        savedPath = docDir.path;
      } catch (_) {
        savedPath = '';
      }
    }
    final askEveryTime = prefs.getBool(_keyAskEveryTime) ?? true;

    state = AppSettings(
      defaultDownloadPath: savedPath,
      askDownloadPathEveryTime: askEveryTime,
    );
  }

  Future<void> setDefaultDownloadPath(String path) async {
    state = state.copyWith(defaultDownloadPath: path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultPath, path);
  }

  Future<void> setAskDownloadPathEveryTime(bool ask) async {
    state = state.copyWith(askDownloadPathEveryTime: ask);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAskEveryTime, ask);
  }
}
