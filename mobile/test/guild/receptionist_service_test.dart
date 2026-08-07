// 【FEAT-305 Phase 3】リリア (ギルド受付 NPC) state 判定の契約テスト 6 件。
//
// 指示書 §3 シナリオ (優先順位ロジック §2.3):
//   - A: defeat_just_now が最優先 (敗北 5min 以内なら他条件無視)
//   - B: victory_just_now (勝利 5min 以内、defeat より優先度低だが他より高)
//   - C: boss_unlocked (Lv.15 到達直後 1h 以内)
//   - D: level_up (Lv 変化 5min 以内)
//   - E: consecutive_battles (直近 1h で Battle 5 件以上)
//   - F: default (上記すべて非該当)

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/models/battle_log_entry.dart';
import 'package:sabiowl/features/battle/models/enemy.dart';
import 'package:sabiowl/features/guild/services/receptionist_service.dart';

void main() {
  final now = DateTime(2026, 5, 25, 12, 0, 0);
  final service = ReceptionistService();

  /// テスト用 BattleLogEntry ファクトリ。
  BattleLogEntry makeBattle({
    required String result,
    required DateTime finishedAt,
    int id = 1,
  }) {
    return BattleLogEntry(
      battleId:         id,
      enemyName:        'ゴブリン',
      result:           result,
      summaryText:      '',
      rounds:           5,
      rewardsCoins:     10,
      rewardsExp:       20,
      totalDamageDealt: 60,
      totalDamageTaken: 0,
      createdAt:        finishedAt,
      finishedAt:       finishedAt,
    );
  }

  /// テスト用 EnemyMaster ファクトリ。
  EnemyMaster makeEnemy({required String key, required int unlockLevel}) {
    return EnemyMaster(
      key: key, name: key, spriteKey: 'enemy_$key',
      baseHp: 100, baseAtk: 10, baseSpd: 10,
      levelScaling: 1.0, rewardCoins: 10, rewardExp: 20,
      tier: 'boss', unlockLevel: unlockLevel,
    );
  }

  group('FEAT-305 ReceptionistService.resolveState 優先順位 (8 シナリオ)', () {
    // ── シナリオ A ───────────────────────────────────────────────
    test('シナリオ A: 敗北 5min 以内 → defeatJustNow が最優先 '
        '(rest_day や consecutive_battles より優先)', () {
      // 敗北 + rest_day + 連戦 + first_login すべて重ねても defeat が勝つ
      final battles = [
        makeBattle(result: 'lose', finishedAt: now.subtract(const Duration(minutes: 2))),
        for (int i = 0; i < 4; i++)
          makeBattle(result: 'win', finishedAt: now.subtract(Duration(minutes: 10 + i))),
      ];
      final state = service.resolveState(
        playerLevel:         20,
        playerCreatedAt:     now.subtract(const Duration(hours: 1)), // first_login も該当
        lastLevelUpAt:       null,
        previousPlayerLevel: null,
        isRestDayToday:      true, // rest_day も該当
        recentBattles:       battles,
        enemies:             [],
        now:                 now,
      );
      expect(state, ReceptionistState.defeatJustNow,
          reason: '敗北 5min 以内は最優先（他の条件をすべて無視）');
    });

    // ── シナリオ B ───────────────────────────────────────────────
    test('シナリオ B: 勝利 5min 以内 → victoryJustNow (defeat 該当なし時)', () {
      final battles = [
        makeBattle(result: 'win', finishedAt: now.subtract(const Duration(minutes: 3))),
      ];
      final state = service.resolveState(
        playerLevel:         20,
        playerCreatedAt:     null,
        lastLevelUpAt:       null,
        previousPlayerLevel: null,
        isRestDayToday:      false,
        recentBattles:       battles,
        enemies:             [],
        now:                 now,
      );
      expect(state, ReceptionistState.victoryJustNow);
    });

    // ── シナリオ C ───────────────────────────────────────────────
    test('シナリオ C: Lv.15 到達直後 (boss_unlocked) → bossUnlocked', () {
      // previousLevel=14 → playerLevel=15 (threshold=15) で boss が解禁
      // armored_knight (unlock_level=15) が enemies に含まれることが条件
      final state = service.resolveState(
        playerLevel:         15,
        playerCreatedAt:     null,
        lastLevelUpAt:       now.subtract(const Duration(minutes: 10)),
        previousPlayerLevel: 14,
        isRestDayToday:      false,
        recentBattles:       const [],
        enemies:             [makeEnemy(key: 'armored_knight', unlockLevel: 15)],
        now:                 now,
      );
      expect(state, ReceptionistState.bossUnlocked,
          reason: 'Lv 14 → 15 で threshold=15 を跨ぎ、該当 enemy が存在 → boss_unlocked');
    });

    // ── シナリオ D ───────────────────────────────────────────────
    test('シナリオ D: Lv 変化 5min 以内 (boss threshold 跨がず) → levelUp', () {
      // previousLevel=7 → 8 (threshold 跨がない) で level_up
      final state = service.resolveState(
        playerLevel:         8,
        playerCreatedAt:     null,
        lastLevelUpAt:       now.subtract(const Duration(minutes: 2)),
        previousPlayerLevel: 7,
        isRestDayToday:      false,
        recentBattles:       const [],
        enemies:             const [],
        now:                 now,
      );
      expect(state, ReceptionistState.levelUp);
    });

    // ── シナリオ E ───────────────────────────────────────────────
    test('シナリオ E: 直近 1h で Battle 5 件以上 → consecutiveBattles', () {
      // 5 件、すべて 1h 以内、勝敗混在で finished_at は 5min より古い
      // (defeat / victory just_now 該当しない)
      final battles = [
        for (int i = 0; i < 5; i++)
          makeBattle(
            id: i,
            result: i.isEven ? 'win' : 'lose',
            finishedAt: now.subtract(Duration(minutes: 10 + i * 5)),
          ),
      ];
      final state = service.resolveState(
        playerLevel:         20,
        playerCreatedAt:     null,
        lastLevelUpAt:       null,
        previousPlayerLevel: null,
        isRestDayToday:      false,
        recentBattles:       battles,
        enemies:             [],
        now:                 now,
      );
      expect(state, ReceptionistState.consecutiveBattles);
    });

    // ── シナリオ F ───────────────────────────────────────────────
    test('シナリオ F: 上記すべて非該当 → defaultGreeting', () {
      final state = service.resolveState(
        playerLevel:         20,
        playerCreatedAt:     now.subtract(const Duration(days: 10)), // 24h 超 → first_login 不発火
        lastLevelUpAt:       null,
        previousPlayerLevel: null,
        isRestDayToday:      false,
        recentBattles:       const [],
        enemies:             const [],
        now:                 now,
      );
      expect(state, ReceptionistState.defaultGreeting);
    });
  });

  group('FEAT-305 ReceptionistService.pickMessageKey 動作', () {
    test('level_up state は levelUp 系 ARB key を返す', () {
      final key = service.pickMessageKey(ReceptionistState.levelUp);
      expect(
        ['guildLiliaLevelUp1', 'guildLiliaLevelUp2'].contains(key),
        isTrue,
        reason: 'levelUp state は guildLiliaLevelUp1 か guildLiliaLevelUp2 を返すはず',
      );
    });
  });
}
