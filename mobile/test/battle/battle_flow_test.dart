// 【FEAT-295 Phase 1f】バトル統合テスト 3 シナリオ。
//
// 検証対象:
//   - シナリオ A: 戦闘フル PASS (BattleOrchestrator が 1 戦完結まで進行)
//   - シナリオ B: 敗北 (味方 HP 0 で status == lost)
//   - シナリオ C: BattleState の summary_text がログから生成される
//
// 注: Backend API モック化は不要 — 純粋ロジック層 (BattleOrchestrator + AtbController)
//     をテスト。Backend 契約は test_battle_views.py で別途縛り済。
// 【2026-07-25 codebase-functional-review 対応】実時間待機 (`await Future.delayed`)
// から fakeAsync 仮想時間へ移行。実 Timer (AtbController の tickRate) の発火回数が
// フル test 実行時の CPU 競合で変動し flaky だったため、仮想時間で完全決定論にする。
import 'package:fake_async/fake_async.dart';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/engine/tactic_resolver.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/services/battle_orchestrator.dart';

void main() {
  group('BattleOrchestrator 統合テスト (FEAT-295 Phase 1f)', () {
    test('シナリオ A: 攻撃重視で 1 戦完結 → 勝利確定', () {
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100,
          atk: 30,  // 通常 30 / 強 54 で 2〜3 ターンで撃破可能
          spd: 100, // 1 tick で満タン
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 60, currentHp: 60,
          atk: 5, spd: 50,
        );
        // 決定論的: random=42 で再現可能
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orchestrator.start();

        // 最大 3 秒待機（spd=100 なら 1 秒 / 10 ターン 進行可能）
        fake.elapse(const Duration(seconds: 3));

        final finalState = orchestrator.state.value;
        orchestrator.dispose();

        expect(finalState.status, isIn([BattleStatus.won, BattleStatus.lost]),
            reason: '3 秒内に戦闘決着');
        // 勇者が圧倒的有利な数値設定なので勝つはず
        expect(finalState.status, BattleStatus.won,
            reason: '勇者 ATK=30 vs ゴブリン HP=60 → 2-3 ターンで勝利');
        expect(finalState.logLines.isNotEmpty, isTrue,
            reason: 'ログが記録されている');
        expect(finalState.rounds, greaterThan(0));
        expect(finalState.totalDamageDealt, greaterThanOrEqualTo(60));
      });
    });

    test('シナリオ B: 味方が圧倒的不利 → 敗北確定', () {
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 10, currentHp: 10,  // HP 極小 → 1 撃で死ぬ
          atk: 1,
          spd: 1,                     // 遅い
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 100, currentHp: 100,
          atk: 50,                    // 1 撃で 50 ダメージ
          spd: 100,                   // 速い → 先攻
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orchestrator.start();

        fake.elapse(const Duration(seconds: 3));

        final finalState = orchestrator.state.value;
        orchestrator.dispose();

        expect(finalState.status, BattleStatus.lost,
            reason: '敵 spd=100 で先攻 + atk=50、味方 HP=10 で 1 撃で死ぬ');
        expect(finalState.player.currentHp, 0);
      });
    });

    test('シナリオ C: summary_text がログから生成され、リプレイ表示用に使える', () {
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100,
          atk: 30,
          spd: 100,
        );
        final enemy = Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 60, currentHp: 60,
          atk: 5,
          spd: 50,
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orchestrator.start();
        fake.elapse(const Duration(seconds: 3));

        final finalState = orchestrator.state.value;
        final summary = finalState.summaryText;
        orchestrator.dispose();

        expect(summary, isNotEmpty);
        expect(summary, contains('勇者'),
            reason: 'プレイヤー名がログに含まれる');
        expect(summary, contains('ゴブリン'),
            reason: '敵名がログに含まれる');
        expect(summary.split('\n').length, greaterThan(1),
            reason: '複数ターンがそれぞれ別行になる');
        // Backend `/battle/finish/` に送信できる長さ（5000 文字以内）
        expect(summary.length, lessThan(5000));
      });
    });
  });
}
