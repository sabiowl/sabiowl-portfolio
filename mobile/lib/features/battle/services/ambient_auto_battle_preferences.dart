import 'package:shared_preferences/shared_preferences.dart';

/// 【FEAT-513】Ambient Auto Battle の SharedPreferences ヘルパー。
///
/// キー一覧:
///   ambient_auto_battle_enabled              — bool: オート ON/OFF
///   ambient_auto_battle_preset_{enemyKey}    — int: 敵ごとの試行回数 (0-99)
///   ambient_auto_battle_last_empty_snackbar  — String: 1日1回制御の ISO8601 日付
class AmbientAutoBattlePreferences {
  static const _enabledKey = 'ambient_auto_battle_enabled';
  static const _presetPrefix = 'ambient_auto_battle_preset_';
  static const _lastEmptySnackBarKey = 'ambient_auto_battle_last_empty_snackbar';

  static bool isEnabled(SharedPreferences prefs) =>
      prefs.getBool(_enabledKey) ?? false;

  static Future<void> setEnabled(SharedPreferences prefs, bool value) =>
      prefs.setBool(_enabledKey, value);

  static int getPreset(SharedPreferences prefs, String enemyKey) =>
      prefs.getInt('$_presetPrefix$enemyKey') ?? 0;

  static Future<void> setPreset(
    SharedPreferences prefs,
    String enemyKey,
    int count,
  ) =>
      prefs.setInt('$_presetPrefix$enemyKey', count.clamp(0, 99));

  static Map<String, int> getAllPresets(
    SharedPreferences prefs,
    List<String> enemyKeys,
  ) =>
      {for (final k in enemyKeys) k: getPreset(prefs, k)};

  // 1 日 1 回制御: 異なる日付なら true (表示可)
  static bool shouldShowEmptySnackBar(SharedPreferences prefs) {
    final raw = prefs.getString(_lastEmptySnackBarKey);
    if (raw == null) return true;
    final last = DateTime.tryParse(raw);
    if (last == null) return true;
    final now = DateTime.now();
    return last.year != now.year ||
        last.month != now.month ||
        last.day != now.day;
  }

  static Future<void> markEmptySnackBarShown(SharedPreferences prefs) =>
      prefs.setString(
        _lastEmptySnackBarKey,
        DateTime.now().toIso8601String(),
      );
}
