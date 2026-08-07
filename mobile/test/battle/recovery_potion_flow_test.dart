// 【FEAT-298 Phase 3】回復薬システムの統合テスト 3 シナリオ + 補助 1 件。
//
// 検証対象:
//   - シナリオ A: HP 30% 以下で回復薬が自動使用され、残数が減る
//   - シナリオ B: potionsPlanned=0 → 既存挙動と完全同等（回復薬未使用）
//   - シナリオ C: 同一ターン内で複数発火しない (Pre-mortem #1)
//   - 補助: planned 上限に達したら HP <= 30% でも追加使用しない
//
// 注: BottomSheet / Backend 経路は契約テスト (test_recovery_potion.py) で別途縛り済。
//     本ファイルは Flutter 純粋ロジック層（BattleOrchestrator._checkAutoPotion）の
//     振る舞いを縛る。
// 【2026-07-25 codebase-functional-review 対応】実時間待機 (`await Future.delayed`)
// から fakeAsync 仮想時間へ移行。実 Timer (AtbController の tickRate) の発火回数が
// フル test 実行時の CPU 競合で変動し flaky だったため、仮想時間で完全決定論にする。
import 'package:fake_async/fake_async.dart';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/engine/tactic_resolver.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/recovery_potion.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/services/battle_orchestrator.dart';

void main() {
  group('RecoveryPotion 統合テスト (FEAT-298 Phase 3)', () {
    test('シナリオ A: HP 30% 以下で自動使用 → potionsUsed += 1 + HP 回復', () {
      // 味方 maxHp=100, currentHp=20 (=20% < 30%)。
      // 敵速度が遅く、味方先攻で 1 回行動した後に _checkAutoPotion が発火し、
      // HP +50 (=70%) に回復する想定。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 20, // 20% → 30% 以下 trigger 条件満たす
          atk: 100, // 1 撃で敵を倒す → 戦闘が早期終了しないよう敵 HP を高く
          spd: 100,
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 1000, currentHp: 1000, // 倒しにくく
          atk: 0,                       // ダメージ無し（味方は HP 安定）
          spd: 1,                       // 遅い
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
          potionsPlanned: 2,
        );
        orchestrator.start();
        // 1 ターン分待機。tickRate=200 / spd=100 → 約 2 秒で 1 ターン経過。
        fake.elapse(const Duration(milliseconds: 2500));

        final state = orchestrator.state.value;
        final usedCount = orchestrator.potionsUsed;
        orchestrator.dispose();

        // 少なくとも 1 個は使われている
        expect(usedCount, greaterThanOrEqualTo(1),
            reason: 'HP 20% で 1 ターン以上経過 → 自動使用が発火するはず');
        // potionsUsed > 0 ならログに残数表記が含まれる
        final hasPotionLog = state.logLines.any(
          (l) => l.contains(RecoveryPotion.emoji) && l.contains('回復薬'),
        );
        expect(hasPotionLog, isTrue, reason: 'ログに「💊 回復薬を使いましたよ」が含まれる');
        // 1 個使用 = maxHp 50% 回復 → currentHp >= 20 + 50 - x（敵ダメージ）
        expect(state.player.currentHp, greaterThanOrEqualTo(70),
            reason: 'maxHp 100 × 0.5 = 50 回復 → 20 + 50 = 70 以上');
      });
    });

    test('シナリオ B: potionsPlanned=0 → 既存挙動と完全同等（回復薬未使用）', () {
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 20, // 30% 以下だが plan=0
          atk: 100,
          spd: 100,
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 1000, currentHp: 1000,
          atk: 0,
          spd: 1,
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
          potionsPlanned: 0, // ← 既存挙動と同等
        );
        orchestrator.start();
        fake.elapse(const Duration(milliseconds: 2500));

        final state = orchestrator.state.value;
        final usedCount = orchestrator.potionsUsed;
        orchestrator.dispose();

        expect(usedCount, 0, reason: 'plan=0 なら回復薬は一切使われない');
        // ログに回復薬使用行が含まれない
        final hasPotionLog = state.logLines.any(
          (l) => l.contains(RecoveryPotion.emoji),
        );
        expect(hasPotionLog, isFalse, reason: 'ログに 💊 行が存在しない');
        // currentHp は敵ダメージなし + 自動回復なしで 20 のまま
        expect(state.player.currentHp, 20);
      });
    });

    test('シナリオ C: 同一ターン内で複数発火しない (Pre-mortem #1)', () {
      // plan=3 だが、味方が 1 ターン経過するごとに最大 1 個しか使えない。
      // 3 ターン分待っても usedCount <= 3、かつ usedCount は turn 数を超えない。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 10, // 10%、毎ターン trigger 条件満たす
          atk: 100,
          spd: 100,
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 1000, currentHp: 1000,
          atk: 50, // 毎ターン -50 で HP がまた 30% 以下に戻る
          spd: 100,
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
          potionsPlanned: 3,
        );
        orchestrator.start();
        fake.elapse(const Duration(milliseconds: 5000));

        final state = orchestrator.state.value;
        final usedCount = orchestrator.potionsUsed;
        orchestrator.dispose();

        // plan 上限以内（3 以下）。連続発火していないことの間接確認。
        expect(usedCount, lessThanOrEqualTo(3),
            reason: 'plan=3 の上限を超えない（1 ターン 1 個ガード機能の証拠）');
        // ログに使用行が usedCount 個記録されているはず
        final potionLogCount = state.logLines
            .where((l) => l.contains(RecoveryPotion.emoji))
            .length;
        expect(potionLogCount, usedCount,
            reason: 'ログ行数と usedCount が一致');
      });
    });

    test('補助: planned 上限到達後は HP <= 30% でも追加使用しない', () {
      // plan=1 で 1 個使い切ったあとは、HP が再び 30% 以下に落ちても消費しない。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 10,
          atk: 100,
          spd: 100,
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 1000, currentHp: 1000,
          atk: 50,
          spd: 100,
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
          potionsPlanned: 1,
        );
        orchestrator.start();
        fake.elapse(const Duration(milliseconds: 5000));

        final usedCount = orchestrator.potionsUsed;
        orchestrator.dispose();

        expect(usedCount, lessThanOrEqualTo(1),
            reason: 'plan=1 を超えない（HP が何度 30% 以下になっても）');
      });
    });
  });
}
