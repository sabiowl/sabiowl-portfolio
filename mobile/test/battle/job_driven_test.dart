// 【FEAT-299 Phase 3】ジョブ駆動設計の統合テスト 2 + 補助シナリオ。
//
// 検証対象:
//   - シナリオ A: warrior の attack_power_modifier=1.3 → ダメージが他キャラより明確に大きい
//   - シナリオ B: mage の on_hit_effect='burn' → 敵に追加ダメージ (max_hp × 0.02 × 3)
//   - 補助 C: cleric の on_hit_effect='heal' → 攻撃のたびに HP 微回復（吸収）
//   - 補助 D: berserker の ult_cost=1 → 1 ターン保留で大技発動可能
//
// 注: Backend API 経由ではなく、Combatant + BattleOrchestrator の純粋ロジック層で
//     ジョブ修飾子の振る舞いを縛る（Backend 契約は test_job_master.py で別途）。
// 【2026-07-25 codebase-functional-review 対応】実時間待機 (`await Future.delayed`)
// から fakeAsync 仮想時間へ移行。旧実装は `orch.start()` 後に実時間を待ち、その間に
// AtbController の実 Timer (tickRate) が何回発火したかでダメージ/ターン数を観測して
// いたため、フル test 実行時の CPU 競合で tick 数が変動し flaky だった
// (シナリオ A が ratio 1.3 期待に対し 1.1375 で確率的に失敗)。
// FakeAsync().run + fake.elapse なら tick 数が厳密に決まり完全決定論になる。
import 'dart:math';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/engine/tactic_resolver.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/services/battle_orchestrator.dart';

void main() {
  group('JobDrivenDesign 統合テスト (FEAT-299 Phase 3)', () {
    // ──────────────────────────────────────────────────────────
    // シナリオ A: warrior の attack_power_modifier=1.3 → ダメージ +30%
    // ──────────────────────────────────────────────────────────
    test('シナリオ A: warrior attackPowerModifier=1.3 → ダメージが 1.3 倍', () {
      // 同条件で attackPowerModifier だけ差を付けた 2 体を比較。
      // 基準: atk=20、HP マシマシ敵で 1 ターン分のダメージを観測。
      // 期待: warrior（1.3）vs default（1.0）で warrior が ~1.3 倍のダメージ。
      FakeAsync().run((fake) {
        int measureDamage({required double atkModifier}) {
          final player = Combatant(
            id: 'player', name: '勇者', spriteKey: 'sabi', jobName: '戦士',
            maxHp: 100, currentHp: 100,
            atk: 20, // 基準 atk
            spd: 100,
            attackPowerModifier: atkModifier,
          );
          final enemy = Combatant(
            id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
            maxHp: 5000, currentHp: 5000, // 死なないように大きく
            atk: 0, // 反撃ダメージなし
            spd: 1, // 遅く
          );
          // 【2026-07-02】Tactic.offense は canUltimate 時に ultimate 自動発動するため、
          // 純粋な attackPowerModifier 効果検証には conserveUltimate (常に normal を返す)
          // を使う。nextBool() を呼ばないため Random シードも不要 (決定論的)。
          final orch = BattleOrchestrator(
            player: player, enemy: enemy,
            tactic: Tactic.conserveUltimate,
            resolver: TacticResolver(random: Random(42)),
          );
          orch.start();
          // 1 ターン分待機（player.spd 100 / tickRate 200 → 2 秒）
          fake.elapse(const Duration(milliseconds: 2400));
          orch.abandon();
          final dealt = orch.state.value.totalDamageDealt;
          orch.dispose();
          return dealt;
        }

        final baseline = measureDamage(atkModifier: 1.0);
        final warrior  = measureDamage(atkModifier: 1.3);

        // warrior は baseline の 1.2-1.4 倍程度（attackPowerModifier 1.3 を反映）。
        // round() による誤差を吸収するため厳密な等式ではなく範囲チェック。
        expect(warrior, greaterThan(baseline),
            reason: 'warrior modifier 1.3 が baseline (1.0) より大きいダメージを出すはず');
        // 1.25-1.35 倍の範囲（normal/strong の混在 + round 誤差を吸収）。
        final ratio = warrior / baseline;
        expect(ratio, greaterThan(1.20));
        expect(ratio, lessThan(1.45));
      });
    });

    // ──────────────────────────────────────────────────────────
    // シナリオ B: mage on_hit_effect='burn' → 敵に追加ダメージ
    // ──────────────────────────────────────────────────────────
    test('シナリオ B: mage on_hit_effect=burn → 敵に追加ダメージ + 🔥 ログ', () {
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: 'ノワール', spriteKey: 'noir', jobName: '魔導士',
          maxHp: 100, currentHp: 100,
          atk: 20, spd: 100,
          onHitEffect: 'burn',
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 5000, currentHp: 5000,
          atk: 0, spd: 1,
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

        // 🔥 burn の追加ダメージログが少なくとも 1 行存在
        final burnLogs = state.logLines.where((l) => l.contains('🔥')).toList();
        expect(burnLogs, isNotEmpty,
            reason: 'on_hit_effect=burn なら攻撃のたびに「🔥 〜 -N HP」ログが追加されるはず');
        // burn の追加ダメージは max_hp × 0.02 × 3 = 5000 × 0.06 = 300。
        // 攻撃が複数回発火していたら累計だが、少なくとも 1 回 = 300 以上の追加ダメージ。
        // 通常攻撃 + burn 合計の totalDamageDealt と、burn なしの baseline を比較
        // するのは難しいので、ここでは burn ログの存在 + 単純 totalDamageDealt の下限のみ確認。
        expect(state.totalDamageDealt, greaterThan(0));
      });
    });

    // ──────────────────────────────────────────────────────────
    // 補助 C: cleric on_hit_effect='heal' → 攻撃時に HP 吸収
    // ──────────────────────────────────────────────────────────
    test('補助 C: cleric on_hit_effect=heal → 攻撃時に HP 吸収 + 💚 ログ', () {
      // 攻撃で HP 吸収できる状態を作るため、player.currentHp を maxHp 未満で開始。
      // 敵に当てる → 「damage × 0.10」を回復 → HP が増える方向に動く。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: 'ルシア', spriteKey: 'lucia', jobName: '僧侶',
          maxHp: 100, currentHp: 50, // 50% から開始（吸収できる余地あり）
          atk: 30, spd: 100,
          onHitEffect: 'heal',
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 5000, currentHp: 5000,
          atk: 0, spd: 1,
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

        // 💚 heal 吸収ログが少なくとも 1 行存在
        final healLogs = state.logLines.where((l) => l.contains('💚')).toList();
        expect(healLogs, isNotEmpty,
            reason: 'on_hit_effect=heal なら攻撃のたびに「💚 〜 +N HP」ログが追加されるはず');
        // 攻撃で HP が 50 より増えている（吸収効果が実値に反映されている）
        expect(state.player.currentHp, greaterThan(50),
            reason: 'HP 吸収で player.currentHp が増加しているはず');
      });
    });

    // ──────────────────────────────────────────────────────────
    // 補助 D: ult_cost 動的化 → berserker は 1 回保留で大技発動
    // ──────────────────────────────────────────────────────────
    test('補助 D: berserker ult_cost=1 → 1 ターン保留で大技発動可能', () {
      // TacticResolver の判定だけテスト（純粋関数）。
      // 【2026-07-02】自動 ultimate 経路が Tactic.conserveUltimate から
      // Tactic.offense に移動したため、tactic を offense に切替えて検証:
      //   - default (ult_cost=3):    canUltimate=false → normal/strong (ultimate ではない)
      //   - berserker (ult_cost=1):  canUltimate=true  → ultimate 自動発動
      final resolver = TacticResolver(random: Random(42));

      final defaultPlayer = Combatant(
        id: 'p1', name: 'P1', spriteKey: 's',
        maxHp: 100, currentHp: 100, atk: 10, spd: 10,
        // ultCost: 3 (default)
      );
      final defaultState = BattleState(
        player: defaultPlayer,
        enemy: Combatant(
          id: 'e', name: 'E', spriteKey: 's',
          maxHp: 100, currentHp: 100, atk: 10, spd: 10,
        ),
        tactic: Tactic.offense,
        status: BattleStatus.running,
        logLines: const [],
        chargedSpecialCount: 1,
      );
      // ult_cost=3 で chargedSpecialCount=1 → canUltimate=false、offense の 50/50 経路
      // (Random(42) の結果に依存せず「ultimate ではない」を主張)
      final defaultAbility = resolver.resolveNextAbility(defaultState);
      expect(defaultAbility.name, isNot('ultimate'),
          reason: 'default ult_cost=3 で chargedSpecialCount=1 なら大技発動しない '
              '(offense の 50% normal / 50% strong)');

      final berserker = Combatant(
        id: 'p2', name: 'P2', spriteKey: 's',
        maxHp: 100, currentHp: 100, atk: 10, spd: 10,
        ultCost: 1, // berserker 即発動
      );
      final berserkerState = BattleState(
        player: berserker,
        enemy: Combatant(
          id: 'e', name: 'E', spriteKey: 's',
          maxHp: 100, currentHp: 100, atk: 10, spd: 10,
        ),
        tactic: Tactic.offense,
        status: BattleStatus.running,
        logLines: const [],
        chargedSpecialCount: 1,
      );
      // ult_cost=1 で chargedSpecialCount=1 → canUltimate=true、offense で自動発動
      final berserkerAbility = resolver.resolveNextAbility(berserkerState);
      expect(berserkerAbility.name, 'ultimate',
          reason: 'berserker ult_cost=1 + Tactic.offense で '
              'chargedSpecialCount=1 なら大技自動発動');
    });

    // ──────────────────────────────────────────────────────────
    // 補助 E: atb_speed_modifier=1.5 (thief) → ATB ゲージ充填が速い
    // ──────────────────────────────────────────────────────────
    test('補助 E: thief atbSpeedModifier=1.5 → ATB が default より速く満タンに', () {
      // 同 spd で modifier だけ差を付けた 2 体で 1 ターン目までの所要時間を比較。
      // baseline (1.0) と thief (1.5) で thief が必ず先に行動するはず。
      FakeAsync().run((fake) {
        int measureFirstActionRounds({required double atbModifier}) {
          final player = Combatant(
            id: 'p', name: 'P', spriteKey: 's',
            maxHp: 1000, currentHp: 1000,
            atk: 10, spd: 50, // 控えめ spd
            atbSpeedModifier: atbModifier,
          );
          final enemy = Combatant(
            id: 'e', name: 'E', spriteKey: 's',
            maxHp: 1000, currentHp: 1000,
            atk: 0, spd: 50,
            atbSpeedModifier: 1.0, // 敵は default
          );
          final orch = BattleOrchestrator(
            player: player, enemy: enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orch.start();
          fake.elapse(const Duration(milliseconds: 1500));
          orch.abandon();
          final rounds = orch.state.value.rounds;
          orch.dispose();
          return rounds;
        }

        final baselineRounds = measureFirstActionRounds(atbModifier: 1.0);
        final thiefRounds    = measureFirstActionRounds(atbModifier: 1.5);

        // thief は同じ時間内により多く行動する
        expect(thiefRounds, greaterThan(baselineRounds),
            reason: 'thief atbSpeedModifier=1.5 で同時間内のターン数が baseline より多いはず '
                    '(baseline=$baselineRounds, thief=$thiefRounds)');
      });
    });
  });
}
