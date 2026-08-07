import 'package:shared_preferences/shared_preferences.dart';

/// オンボーディング専用のローカル状態を管理するサービス。
///
/// 保存先はすべて SharedPreferences（非機密データのため）。
///
/// FEAT-188: ゲスト基盤がサーバー側に移行したため、ローカルへのゲスト習慣シード
/// (`seedDefaultGuestData`) と `clearGuestData` は廃止。名前・キャラ key は
/// オンボーディング画面で `PATCH /api/player/` / `POST /characters/<id>/select/`
/// を直接叩いてサーバー側に保存される。本サービスは「チュートリアル表示状況」
/// 「初回 ToDo 完了フラグ」「起動回数」「二回目起動案内表示済みフラグ」のみ
/// 担当する。
class OnboardingService {
  // ── キー定数 ────────────────────────────────────────────────────────────
  static const _nameKey              = 'onboarding_player_name';
  static const _characterKey         = 'onboarding_character_key';
  static const _firstTodoKey         = 'first_todo_completed';
  // 【FEAT-221】_launchCountKey / _secondLaunchShownKey は Quest 廃止後の dead UX
  // 「特別なお知らせ」シート完全撤去（2026-05-15）に伴い削除。関連メソッドも除外。
  // 【2026-07-19】_feat426MigratedKey は FEAT-426 移行案内 SnackBar 撤去に伴い削除。

  // ── 名前（参考用キャッシュ。真の値はサーバー側） ───────────────────────

  static Future<void> saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name);
  }

  static Future<String> getName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_nameKey) ?? '勇者';
  }

  // ── キャラクター（参考用キャッシュ） ─────────────────────────────────────

  /// スターターキャラの識別キーを保存
  /// 例: 'aria' / 'beatrix' / 'faye' / 'lucia' / 'noir' / 'cyan' / 'sol' / 'zenon'
  /// 【BUG-103 (2026-06-14)】旧 'rune' → 'cyan' に rename (migration 0137)
  static Future<void> saveCharacterKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_characterKey, key);
  }

  static Future<String?> getCharacterKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_characterKey);
  }

  // ── 初回 ToDo 完了フラグ ────────────────────────────────────────────────

  static Future<bool> isFirstTodoCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_firstTodoKey) ?? false;
  }

  static Future<void> markFirstTodoCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_firstTodoKey, true);
  }

  // 【FEAT-221】起動回数 + 2 回目起動案内系メソッド
  // (`incrementAndGetLaunchCount` / `isSecondLaunchShown` / `markSecondLaunchShown`) は
  // 「特別なお知らせ」シート廃止に伴い削除（2026-05-15）。

  // 【2026-07-19】FEAT-426 移行案内 SnackBar 撤去に伴い、isFeat426Migrated /
  // markFeat426Migrated / _feat426MigratedKey は削除。既存ユーザーへの一度限りの
  // 案内は目的達成済 + 新規ユーザーには不要と判断。
}
