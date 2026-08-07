import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 【FEAT-308 暫定実装】リリア (FEAT-305) の `levelUp` / `bossUnlocked` セリフを
/// v1.0 内で動作化するためのローカル state 保持サービス。
///
/// **設計判断 (指示書 §2.1 案 (c) PM 採択)**:
/// - Backend 変更ゼロ (PlayerProfile に `last_level_up_at` 追加せず)
/// - Flutter `SharedPreferences` で前回ギルド入場時の `player.level` を記録
/// - 現在 level > 前回 level なら「Lv UP 直後」判定 → `lastLevelUpAt` を返す
///
/// **v1.1 FEAT-310 (SP/JP 育成) 移行時の廃止予定**:
/// - `PlayerProfile.last_level_up_at` + `previous_level` を Backend に追加
/// - 本サービスは完全廃止、`playerNotifierProvider` から直接読む経路に切替
/// - SharedPreferences の旧キー (`lilia_last_seen_level` 等) は cleanup migration で削除
///
/// 関連:
/// - 機能レビュー `doc/codebase_review/20260525_functional_review.md` §2 懸念点 2
/// - FEAT-305 `guild_reception_view.dart` の `null` 渡し 2 箇所解消
/// - FEAT-308 §2.5 契約テスト 3 件 (`receptionist_state_test.dart`)
class ReceptionistStateService {
  ReceptionistStateService();

  // SharedPreferences キー設計 (指示書 §2.3、`lilia_` prefix 必須 Pre-mortem #1):
  //   lilia_last_seen_level    : int    前回ギルド入場時に観測した player.level
  //   lilia_last_seen_level_at : String 上記を保存した時刻 (ISO8601、5min 判定用)
  static const String _kPrefLastSeenLevel = 'lilia_last_seen_level';
  static const String _kPrefLastSeenAt = 'lilia_last_seen_level_at';

  /// 現在の player.level を受け取り、リリアの `levelUp` / `bossUnlocked` 判定に
  /// 必要なコンテキストを返す。
  ///
  /// 戻り値の `lastLevelUpAt`:
  ///   - 前回観測値より level が上昇している → 保存時刻 DateTime
  ///   - 同 level or 初回 (SharedPreferences 空) → null (= 「default」セリフへ落ちる)
  /// 戻り値の `previousLevel`:
  ///   - 前回観測値 (boss_unlocked 跨ぎ判定 15/25/35 用)
  ///   - 初回 → null
  ///
  /// 本メソッドは **書き込みしない**。書き込みは `markLevelSeen` を別途呼ぶこと
  /// (UI 側でセリフ表示後に呼び出して「祝福済み」状態を作る = 二度祝福防止)。
  Future<LevelUpContext> resolveLevelUpContext(int currentLevel) async {
    final prefs = await SharedPreferences.getInstance();
    final previousLevel = prefs.getInt(_kPrefLastSeenLevel);
    final lastSeenAtRaw = prefs.getString(_kPrefLastSeenAt);

    // 初回 or リセット直後 (Pre-mortem #3): 観測値なし → null コンテキスト
    if (previousLevel == null) {
      return const LevelUpContext(lastLevelUpAt: null, previousLevel: null);
    }

    // 同 level or 下降 (退行ケースは想定外だが防御): 祝福済み or 該当なし
    if (currentLevel <= previousLevel) {
      return LevelUpContext(lastLevelUpAt: null, previousLevel: previousLevel);
    }

    // Lv UP 直後: 保存時刻 + 前回 level を返す
    final lastSeenAt = lastSeenAtRaw != null
        ? DateTime.tryParse(lastSeenAtRaw)
        : null;
    return LevelUpContext(
      lastLevelUpAt: lastSeenAt,
      previousLevel: previousLevel,
    );
  }

  /// 「リリアが現在 level を一度祝福した」状態を SharedPreferences に書き込む。
  ///
  /// ギルド画面が `levelUp` / `bossUnlocked` セリフを表示し終えた後に呼び、
  /// 次回入場時に同じ Lv UP を再発火させない (二度祝福防止)。
  ///
  /// `lilia_last_seen_level` を `currentLevel` に、`lilia_last_seen_level_at` を
  /// `DateTime.now().toIso8601String()` に更新する。
  Future<void> markLevelSeen(int currentLevel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPrefLastSeenLevel, currentLevel);
    await prefs.setString(
        _kPrefLastSeenAt, DateTime.now().toIso8601String());
  }
}

/// `ReceptionistStateService.resolveLevelUpContext` の戻り値。
///
/// `lastLevelUpAt`: Lv UP 直後判定用 (null = 該当なし)
/// `previousLevel`: boss_unlocked 跨ぎ判定 (15/25/35 閾値、null = 初回)
class LevelUpContext {
  const LevelUpContext({
    required this.lastLevelUpAt,
    required this.previousLevel,
  });

  final DateTime? lastLevelUpAt;
  final int? previousLevel;
}

/// Riverpod provider。シンプルな stateless サービスなので Provider で十分。
final receptionistStateServiceProvider =
    Provider<ReceptionistStateService>((ref) => ReceptionistStateService());
