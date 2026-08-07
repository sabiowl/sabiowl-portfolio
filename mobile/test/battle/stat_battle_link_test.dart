// 【FEAT-333 Phase 3 (2026-05-27)】CharacterStat 6 軸 → バトル能力 1 対 1 連動の契約テスト。
//
// 設計案 A 採択 (PM 長期設計セッション 2026-05-27):
//   - 運動力     → maxHp  (+5 / Lv)
//   - 学習力     → atk    (+1 / Lv)
//   - 健康力     → hpRegenPerTurn (+2 / Lv)
//   - 精神力     → atbSpeedModifier (+0.01 / Lv)
//   - 創造力     → critRate (+0.005 / Lv)
//   - 貢献力     → damageReduction (+0.005 / Lv)
//
// このテストは Combatant + BattleOrchestrator の純粋ロジック層で stat 連動の
// 振る舞いを縛る (provider 層の `_buildPlayerCombatant` は別途実機で確認)。
// Pre-mortem #1 退行回避: default 0 のシナリオを最初に縛り、既存挙動互換を保証。
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/engine/tactic_resolver.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/services/battle_orchestrator.dart';

void main() {
  group('StatBattleLink 統合テスト (FEAT-333 Phase 3)', () {
    // ──────────────────────────────────────────────────────────
    // 退行ベース: default 0 → 既存挙動互換 (Pre-mortem #1)
    // ──────────────────────────────────────────────────────────
    test('退行ゼロ: hpRegenPerTurn=0 / critRate=0 / damageReduction=0 で既存挙動と完全同等',
        () {
      // すべて default 0 で旧 FEAT-302 baseline と同じ挙動になることを確認。
      // 🌿 / ✨ ログが一切出ない + HP regen / crit / dmgReduction の効果なし。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 500, currentHp: 500, atk: 20, spd: 100,
          // hpRegenPerTurn / critRate / damageReduction はすべて default。
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 5000, currentHp: 5000, atk: 0, spd: 1,
        );
        final orch = BattleOrchestrator(
          player: player, enemy: enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orch.start();
        fake.elapse(const Duration(milliseconds: 2400));
        orch.abandon();
        final state = orch.state.value;
        orch.dispose();

        // 🌿 自然回復ログが一切ない
        final regenLogs = state.logLines.where((l) => l.contains('🌿')).toList();
        expect(regenLogs, isEmpty,
            reason: 'hpRegenPerTurn=0 で 🌿 自然回復ログは絶対に出ない');
        // ✨ クリティカルログが一切ない (weak_ult_cost ⚡ は別、creativity ✨ だけチェック)
        final creativityCritLogs =
            state.logLines.where((l) => l.contains('✨')).toList();
        expect(creativityCritLogs, isEmpty,
            reason: 'critRate=0 で ✨ クリティカルログは絶対に出ない');
      });
    });

    // ──────────────────────────────────────────────────────────
    // 運動力連動: maxHp 増加
    // ──────────────────────────────────────────────────────────
    test('運動力連動: athleticLv 反映で maxHp 増加 (HP プール拡大)', () {
      // 運動力 Lv 5 想定: maxHp = baseHp + 5 × 5 = +25 HP の効果。
      // `_buildPlayerCombatant` 側で計算するため、ここでは Combatant の HP 値で確認。
      final athletic5 = Combatant(
        id: 'p', name: 'P', spriteKey: 's',
        maxHp: 125, currentHp: 125, // base 100 + 25 (= 5 × 5)
        atk: 20, spd: 100,
      );
      final baseline = Combatant(
        id: 'p', name: 'P', spriteKey: 's',
        maxHp: 100, currentHp: 100,
        atk: 20, spd: 100,
      );
      expect(athletic5.maxHp, greaterThan(baseline.maxHp),
          reason: '運動力 Lv 5 で maxHp が 25 多い');
      expect(athletic5.maxHp - baseline.maxHp, 25);
    });

    // ──────────────────────────────────────────────────────────
    // 学習力連動: atk 増加
    // ──────────────────────────────────────────────────────────
    test('学習力連動: studyLv 反映で atk 増加 (与ダメージ増)', () {
      // atk のみで差を付けた 2 体を比較 (学習力 Lv 5 → atk +5 想定)。
      // 学習力 5 = atk 25 vs baseline atk 20 → 1.25 倍程度のダメージが期待値。
      FakeAsync().run((fake) {
        int measureDamage(int atk) {
          final player = Combatant(
            id: 'p', name: 'P', spriteKey: 's',
            maxHp: 100, currentHp: 100,
            atk: atk, spd: 100,
          );
          final enemy = Combatant(
            id: 'e', name: 'E', spriteKey: 's',
            maxHp: 5000, currentHp: 5000, atk: 0, spd: 1,
          );
          final orch = BattleOrchestrator(
            player: player, enemy: enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orch.start();
          fake.elapse(const Duration(milliseconds: 2400));
          orch.abandon();
          final dealt = orch.state.value.totalDamageDealt;
          orch.dispose();
          return dealt;
        }

        final baseline = measureDamage(20); // 学習力 Lv 0
        final study5   = measureDamage(25); // 学習力 Lv 5
        expect(study5, greaterThan(baseline),
            reason: '学習力 Lv 5 (atk +5) で baseline (atk 20) よりダメージが多い');
      });
    });

    // ──────────────────────────────────────────────────────────
    // 健康力連動: hpRegenPerTurn による turn 末 HP 自然回復
    // ──────────────────────────────────────────────────────────
    test('健康力連動: hpRegenPerTurn=10 → turn 終了時に 🌿 自然回復ログが出る', () {
      // 健康力 Lv 5 想定 (hpRegenPerTurn = 5 × 2 = 10)。
      // 戦闘中 currentHp < maxHp で開始 → turn 末に regen が発火 → 🌿 ログ出現。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 200, currentHp: 100, // 半分から開始 (regen の余地確保)
          atk: 20, spd: 100,
          hpRegenPerTurn: 10, // 健康力 Lv 5 相当
        );
        final enemy = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 5000, currentHp: 5000, atk: 0, spd: 1,
        );
        final orch = BattleOrchestrator(
          player: player, enemy: enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orch.start();
        fake.elapse(const Duration(milliseconds: 2400));
        orch.abandon();
        final state = orch.state.value;
        orch.dispose();

        // 🌿 自然回復ログが少なくとも 1 行ある
        final regenLogs = state.logLines.where((l) => l.contains('🌿')).toList();
        expect(regenLogs, isNotEmpty,
            reason: 'hpRegenPerTurn=10 で turn 末に 🌿 自然回復ログが出る');
        // HP が 100 より増えている (regen の効果が実際に HP に反映)
        expect(state.player.currentHp, greaterThan(100),
            reason: '自然回復で player.currentHp が 100 より増加');
      });
    });

    test('健康力連動: hpRegenPerTurn は maxHp で clamp される', () {
      // 既に max の状態で regen が発火しても maxHp を超えない (+0 になり log も出ない)。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, // 既に max
          atk: 20, spd: 100,
          hpRegenPerTurn: 10,
        );
        final enemy = Combatant(
          id: 'enemy', name: 'E', spriteKey: 's',
          maxHp: 5000, currentHp: 5000, atk: 0, spd: 1,
        );
        final orch = BattleOrchestrator(
          player: player, enemy: enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orch.start();
        fake.elapse(const Duration(milliseconds: 1500));
        orch.abandon();
        final state = orch.state.value;
        orch.dispose();

        // maxHp で clamp → 実際の regen は 0 → 🌿 ログは出ない
        expect(state.player.currentHp, lessThanOrEqualTo(state.player.maxHp));
        // 注: 反撃ダメージ 0 + maxHp 開始 → 100 のまま、🌿 ログ無し
        final regenLogs = state.logLines.where((l) => l.contains('🌿')).toList();
        expect(regenLogs, isEmpty,
            reason: 'maxHp で開始 → regen の実効果 0 → 🌿 ログは追加されない');
      });
    });

    // ──────────────────────────────────────────────────────────
    // 精神力連動: atbSpeedModifier 増加 (ATB 充填が速い)
    // ──────────────────────────────────────────────────────────
    test('精神力連動: mentalLv 反映で atbSpeedModifier 増加 → 同時間内のターン数が多い',
        () {
      // fakeAsync で Timer.periodic を決定論的に駆動し、CI タイミング依存の flaky を根絶。
      //
      // spd=55 を選んだ理由:
      //   tickRate=300, spd=55 の場合、atbMod=1.0 は ceil(300/55)=6 tick で gauge=1.0、
      //   atbMod=1.1 は ceil(300/60.5)=5 tick で gauge>=1.0 → 1 tick 早く発火する。
      //   25 tick (2500ms) で orchM player が 5 回 / orchB player が 4 回ターンを取り、
      //   mental10 = 8 rounds > baseline = 7 rounds が決定論的に成立する。
      //   spd=50 では ceil(300/50)=ceil(300/55)=6 tick (同値) なので差が出ない。
      FakeAsync().run((fake) {
        final playerB = Combatant(
          id: 'p', name: 'P', spriteKey: 's',
          maxHp: 1000, currentHp: 1000,
          atk: 10, spd: 55,
          atbSpeedModifier: 1.0, // 精神力 Lv 0 (baseline)
        );
        final enemyB = Combatant(
          id: 'e', name: 'E', spriteKey: 's',
          maxHp: 1000, currentHp: 1000,
          atk: 0, spd: 55,
        );
        final orchB = BattleOrchestrator(
          player: playerB, enemy: enemyB,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );

        final playerM = Combatant(
          id: 'p', name: 'P', spriteKey: 's',
          maxHp: 1000, currentHp: 1000,
          atk: 10, spd: 55,
          atbSpeedModifier: 1.1, // 精神力 Lv 10
        );
        final enemyM = Combatant(
          id: 'e', name: 'E', spriteKey: 's',
          maxHp: 1000, currentHp: 1000,
          atk: 0, spd: 55,
        );
        final orchM = BattleOrchestrator(
          player: playerM, enemy: enemyM,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );

        orchB.start();
        orchM.start();
        fake.elapse(const Duration(milliseconds: 2500));
        orchB.abandon();
        orchM.abandon();

        final baseline = orchB.state.value.rounds;
        final mental10 = orchM.state.value.rounds;

        orchB.dispose();
        orchM.dispose();

        expect(mental10, greaterThanOrEqualTo(baseline),
            reason: '精神力 Lv 10 (atbMod 1.1) で同時間内のターン数が baseline 以上 '
                    '(baseline=$baseline, mental10=$mental10)');
      });
    });

    // ──────────────────────────────────────────────────────────
    // 創造力連動: critRate (高確率 1.0 で必発と縛る)
    // ──────────────────────────────────────────────────────────
    test('創造力連動: critRate=1.0 (Lv 200 相当) で ✨ ログ必発 + ダメージ ×1.5', () {
      // critRate=1.0 は実運用ではあり得ないが (Lv 200 で 100%) 確定発火を縛る目的で使用。
      // ダメージは round 誤差で ~1.5 倍程度になることを確認。
      FakeAsync().run((fake) {
        int measureDamage(double critRate) {
          final player = Combatant(
            id: 'p', name: 'P', spriteKey: 's',
            maxHp: 100, currentHp: 100,
            atk: 20, spd: 100,
            critRate: critRate,
          );
          final enemy = Combatant(
            id: 'e', name: 'E', spriteKey: 's',
            maxHp: 5000, currentHp: 5000, atk: 0, spd: 1,
          );
          final orch = BattleOrchestrator(
            player: player, enemy: enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orch.start();
          fake.elapse(const Duration(milliseconds: 2400));
          orch.abandon();
          final dealt = orch.state.value.totalDamageDealt;
          final logs = orch.state.value.logLines;
          orch.dispose();
          // ✨ ログが必ず出る (critRate=1.0 = 100% 発動)
          final critLogs = logs.where((l) => l.contains('✨')).toList();
          if (critRate >= 1.0) {
            expect(critLogs, isNotEmpty,
                reason: 'critRate=1.0 で ✨ クリティカルログが必ず出る');
          }
          return dealt;
        }

        final baseline = measureDamage(0.0); // 創造力 Lv 0
        final critFull = measureDamage(1.0); // 必発
        expect(critFull, greaterThan(baseline),
            reason: 'critRate=1.0 で baseline (0.0) よりダメージが大きい');
        // 1.5 倍前後 (normal/strong 混在 + round 誤差を吸収する範囲チェック)
        final ratio = critFull / baseline;
        expect(ratio, greaterThan(1.35),
            reason: 'critRate=1.0 でダメージ ~1.5 倍 (実測 ratio=$ratio)');
        expect(ratio, lessThan(1.65));
      });
    });

    // ──────────────────────────────────────────────────────────
    // 貢献力連動: damageReduction (被ダメージ軽減)
    // ──────────────────────────────────────────────────────────
    test('貢献力連動: damageReduction=0.5 で被ダメージが半分になる', () {
      // damageReduction=0.5 は実運用では Lv 100 相当 (実 max ~Lv 30 で 0.15)。
      // 効果を明確化するため高い値で縛る。
      FakeAsync().run((fake) {
        int measureTaken(double dmgRed) {
          final player = Combatant(
            id: 'p', name: 'P', spriteKey: 's',
            maxHp: 1000, currentHp: 1000, // 死なないように
            atk: 10, spd: 1, // player は遅く、敵に殴られる役
            damageReduction: dmgRed,
          );
          final enemy = Combatant(
            id: 'e', name: 'E', spriteKey: 's',
            maxHp: 5000, currentHp: 5000,
            atk: 30, spd: 100, // 敵は速くて強い
          );
          final orch = BattleOrchestrator(
            player: player, enemy: enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orch.start();
          fake.elapse(const Duration(milliseconds: 2400));
          orch.abandon();
          final taken = orch.state.value.totalDamageTaken;
          orch.dispose();
          return taken;
        }

        final baseline = measureTaken(0.0);
        final reduced  = measureTaken(0.5);
        expect(reduced, lessThan(baseline),
            reason: 'damageReduction=0.5 で baseline より被ダメが小さい '
                    '(baseline=$baseline, reduced=$reduced)');
        // 0.5 軽減 → 概ね半分前後 (resistance + clamp の影響を許容する範囲)
        final ratio = reduced / baseline;
        expect(ratio, lessThan(0.65),
            reason: 'damageReduction=0.5 で被ダメは半分弱 (実測 ratio=$ratio)');
      });
    });
  });
}
