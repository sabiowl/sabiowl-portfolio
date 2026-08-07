import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences キー定数集。
///
/// アプリ全体で使用する SharedPreferences のキー文字列をここに一元管理する。
/// 散在によるキー名の誤りと重複を防ぐ。

// ── 【FEAT-399 (2026-05-31)】BackupPromptSheet マイルストーン抑制 ─────────────────

/// BackupPromptSheet を最後に表示したプレイヤーレベルを保存するキー。
///
/// 同一レベルで 2 回目以降の表示を抑制するために使用する
/// (例: Lv 5 で一度表示後、同 Lv でのリトライ起動では表示しない)。
/// 値がない (初回) は 0 として扱う。
const String kPrefsLastBackupSheetShownLevel = 'last_backup_sheet_shown_level';

/// BackupPromptSheet を発火するマイルストーン Lv セット。
///
/// このレベルに到達したとき、ゲストユーザーにバックアップを促す
/// BackupPromptSheet が表示される。毎レベルアップでは表示しない (FEAT-399 抑制)。
const Set<int> kBackupSheetMilestoneLevels = {5, 10, 20, 30};

/// BackupPromptSheet を表示すべきか判定する。
///
/// [level] が [kPrefsLastBackupSheetShownLevel] に保存された値より大きい場合のみ `true`。
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ (テスト時に渡してモック化可能)。
Future<bool> shouldShowBackupPromptSheet(int level, {SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  final lastLevel = p.getInt(kPrefsLastBackupSheetShownLevel) ?? 0;
  return level > lastLevel;
}

/// BackupPromptSheet を表示済みとして [kPrefsLastBackupSheetShownLevel] に [level] を保存する。
///
/// 表示 **前** に呼ぶことで同一レベルでの二重表示を防ぐ。
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ (テスト時に渡してモック化可能)。
Future<void> markBackupPromptSheetShown(int level, {SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setInt(kPrefsLastBackupSheetShownLevel, level);
}

// ── 【FEAT-462 (2026-06-22)】バトル戻るボタン初回ヒント ─────────────────────────

/// バトル戻るボタンの初回ヒント (「戻ってもバトルは続きますよ」) を
/// 表示済みかどうかを保存するキー。
///
/// 初回バトル時に 1 度だけ吹き出しを表示し、以降は表示しない。
/// 値がない (初回) は false として扱う。
const String kPrefsBattleBackHintShown = 'battle_back_hint_shown';

/// バトル戻るボタンの初回ヒントを表示すべきか判定する。
///
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ
/// (テスト時に渡してモック化可能)。
Future<bool> shouldShowBattleBackHint({SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  return !(p.getBool(kPrefsBattleBackHintShown) ?? false);
}

/// バトル戻るボタンの初回ヒントを表示済みとしてマークする。
///
/// 表示 **前** に呼ぶことで二重表示を防ぐ (Pre-mortem #1)。
/// [prefs] は省略すると `SharedPreferences.getInstance()` を呼ぶ。
Future<void> markBattleBackHintShown({SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setBool(kPrefsBattleBackHintShown, true);
}
