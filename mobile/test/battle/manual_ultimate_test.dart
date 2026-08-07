// 【FEAT-301 Phase 3】手動必殺ボタンの契約テスト 6 シナリオ。
//
// 検証対象:
//   - シナリオ A: UltGauge 未満タンで tryQueueUltimate → notEnoughCharge + state 不変
//   - シナリオ B: 押下冪等性 (連打しても 2 回目以降は alreadyQueued or 同結果、Pre-mortem #4)
//   - シナリオ C: queue 後、次の player turn で ultimate 発動 → queueUltimate=false +
//                 log に「大技」行が含まれる
//   - シナリオ D: 戦闘終了済 (lost) で押下 → notRunning + dispose で例外なし
//   - シナリオ E: Tactic.offense でも queue 有効 → Resolver が ultimate を返さない作戦でも
//                 queue が上書きして大技ログが出る (Pre-mortem #3 Tactic 非依存性)
//   - シナリオ F: ジョブ別 ultCost (berserker=1) で発動条件が正しく評価される
//                 (Pre-mortem #5 ジョブ駆動退行回避)
//
// 注: ロジック層 (BattleOrchestrator.tryQueueUltimate / _handlePlayerTurn 改修) を
//     縛る。UI 層 (UltimateButton widget) はビジュアル / SnackBar / Tooltip 主体。
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
  group('UltimateButton 手動キュー契約 (FEAT-301 Phase 3)', () {
    // ── シナリオ A ───────────────────────────────────────────────
    test('シナリオ A: UltGauge 未満タンで押下 → notEnoughCharge + state 不変', () {
      // spd 遅い → start() 直後は chargedSpecialCount=0 のまま。
      // ultCost default 3 で 0 < 3 → notEnoughCharge を期待。
      final player = Combatant(
        id: 'player', name: '勇者', spriteKey: 'sabi',
        maxHp: 100, currentHp: 100,
        atk: 10, spd: 1,
      );
      final enemy = Combatant(
        id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
        maxHp: 100, currentHp: 100,
        atk: 0, spd: 1,
      );
      final orchestrator = BattleOrchestrator(
        player: player,
        enemy:  enemy,
        tactic: Tactic.offense,
        resolver: TacticResolver(random: Random(42)),
      );
      orchestrator.start();

      final result = orchestrator.tryQueueUltimate();
      final stateAfter = orchestrator.state.value;
      orchestrator.dispose();

      expect(result, UltimateQueueResult.notEnoughCharge,
          reason: 'UltGauge 未満タンでは queue されない');
      expect(stateAfter.queueUltimate, isFalse,
          reason: 'state 不変（queueUltimate=false のまま）');
    });

    // ── シナリオ B ───────────────────────────────────────────────
    test('シナリオ B: 押下冪等性 (連打しても 2 回目以降は同結果、Pre-mortem #4)', () {
      // 未満タン状態で 3 回連続押下 → どの試行も notEnoughCharge、state 不変。
      // tryQueueUltimate 自体に副作用が起きないことを契約として縛る。
      final player = Combatant(
        id: 'player', name: '勇者', spriteKey: 'sabi',
        maxHp: 100, currentHp: 100,
        atk: 10, spd: 1,
      );
      final enemy = Combatant(
        id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
        maxHp: 100, currentHp: 100,
        atk: 0, spd: 1,
      );
      final orchestrator = BattleOrchestrator(
        player: player,
        enemy:  enemy,
        tactic: Tactic.offense,
        resolver: TacticResolver(random: Random(42)),
      );
      orchestrator.start();

      final r1 = orchestrator.tryQueueUltimate();
      final r2 = orchestrator.tryQueueUltimate();
      final r3 = orchestrator.tryQueueUltimate();
      final stateAfter = orchestrator.state.value;
      orchestrator.dispose();

      expect(r1, UltimateQueueResult.notEnoughCharge);
      expect(r2, UltimateQueueResult.notEnoughCharge);
      expect(r3, UltimateQueueResult.notEnoughCharge);
      expect(stateAfter.queueUltimate, isFalse,
          reason: '連打しても queue 立たない（副作用ゼロ）');
    });

    // ── シナリオ C ───────────────────────────────────────────────
    test('シナリオ C: queue 後の player turn で ultimate 発動 → queueUltimate=false '
        '+ log に「大技」行', () {
      // conserveUltimate で進めて chargedSpecialCount を満タンに → queue → 次撃発動。
      // 敵 HP を高めにして戦闘継続、ログ蓄積を確実にする。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100,
          atk: 10, spd: 100, // 約 0.2 秒 / ターン (tickRate=200 / spd=100 = 0.5/tick * 2 tick)
        );
        final enemy = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 100000, currentHp: 100000, // 倒さない
          atk: 0, spd: 1,
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.conserveUltimate, // 確実に蓄積（normal 連打）
          resolver: TacticResolver(random: Random(42)),
        );

        // queue 状態を一度だけ true→false に遷移したことを観察するためのリスナー。
        bool queueClearedObserved = false;
        bool ultLogObserved = false;
        orchestrator.state.addListener(() {
          final v = orchestrator.state.value;
          if (v.queueUltimate == false && v.chargedSpecialCount == 0) {
            // 直近で ultimate が発火した可能性が高い瞬間
          }
          if (!ultLogObserved && v.logLines.any((l) => l.contains('大技'))) {
            ultLogObserved = true;
          }
        });

        orchestrator.start();

        // 蓄積待ち。【2026-07-02】仕様変更後の conserveUltimate は resolver から
        // 常に normal を返す (自動発動なし) ため、chargedSpecialCount は
        // ultCost に到達しても resolver は ultimate を返さない = 手動 queue 経路の
        // 純粋テストとして機能する (自動発動との race が構造的に消えた)。
        // とにかく 1 秒以内に chargedSpecialCount >= ultCost に到達するのを待つ。
        for (int i = 0; i < 50; i++) {
          fake.elapse(const Duration(milliseconds: 50));
          if (orchestrator.state.value.chargedSpecialCount >= player.ultCost) {
            break;
          }
        }
        expect(orchestrator.state.value.chargedSpecialCount, player.ultCost,
            reason: '1 秒以内に conserveUltimate で chargedSpecialCount 満タン到達');

        // queue → 次撃で発動を観察
        final queueResult = orchestrator.tryQueueUltimate();
        expect(queueResult, UltimateQueueResult.queued);
        expect(orchestrator.state.value.queueUltimate, isTrue);

        // 1 ターン分待機 (~0.2-0.4 秒)。Wait は短めにして
        // ultimate 発動 → queueUltimate=false を観察する。
        for (int i = 0; i < 20; i++) {
          fake.elapse(const Duration(milliseconds: 50));
          if (!orchestrator.state.value.queueUltimate) {
            queueClearedObserved = true;
            break;
          }
        }

        final s = orchestrator.state.value;
        orchestrator.dispose();

        expect(queueClearedObserved, isTrue,
            reason: 'queue が消費されて queueUltimate=false になった瞬間が観察された');
        expect(ultLogObserved || s.logLines.any((l) => l.contains('大技')), isTrue,
            reason: 'ログに「大技」行が含まれる（ultimate が少なくとも 1 回発動）');
      });
    });

    // ── シナリオ D ───────────────────────────────────────────────
    test('シナリオ D: 戦闘終了済 (lost) で押下 → notRunning + dispose で例外なし', () {
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 10, currentHp: 10,
          atk: 10, spd: 1,
        );
        final enemy = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 100, currentHp: 100,
          atk: 100, spd: 100, // 即死
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orchestrator.start();
        // 敵が 1 撃で味方を倒すまで待つ
        fake.elapse(const Duration(seconds: 3));

        final result = orchestrator.tryQueueUltimate();
        final st = orchestrator.state.value;
        // dispose で例外が出ないことを確認
        expect(() => orchestrator.dispose(), returnsNormally);

        expect(st.status, BattleStatus.lost,
            reason: '味方 HP=10 vs 敵 atk=100 で敗北');
        expect(result, UltimateQueueResult.notRunning,
            reason: '戦闘終了済 → notRunning（押下無効扱い）');
      });
    });

    // ── シナリオ E ───────────────────────────────────────────────
    test('シナリオ E: Tactic.offense + queue 有効 → Resolver が ultimate を返さない作戦でも '
        'queue が上書きして大技が出る (Pre-mortem #3 Tactic 非依存性 + BUG-75 strong 蓄積契約)', () {
      // offense は normal/strong しか返さない → 通常は ultimate 発動しない。
      // queue 立てると _handlePlayerTurn が Resolver を上書きして ultimate を発動する。
      // chargedSpecialCount は FEAT-300 hotfix + 【BUG-75 修正 (2026-05-29)】で
      // Ability.normal だけでなく Ability.strong でも +1 蓄積する。
      // → Tactic.offense (50% strong) でも全攻撃でゲージが貯まる UX 整合性を確保。
      // 旧: Ability.normal のみ +1 (strong/heal は維持) → Tactic.offense の 50% は貯まらない UX 破綻
      // 新: Ability.normal || Ability.strong で +1 (heal/ultimate のみ例外) → 攻撃すれば貯まる直感維持
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100,
          atk: 10, spd: 100,
        );
        final enemy = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 100000, currentHp: 100000,
          atk: 0, spd: 1,
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense, // ← ultimate を返さない作戦
          resolver: TacticResolver(random: Random(42)),
        );

        // offense は normal/strong 50/50 なので chargedSpecialCount 満タンに時間がかかる。
        // 最大 5 秒待機。
        orchestrator.start();
        for (int i = 0; i < 100; i++) {
          fake.elapse(const Duration(milliseconds: 50));
          if (orchestrator.state.value.chargedSpecialCount >= player.ultCost) {
            break;
          }
        }
        // この時点で必ず満タン到達しているはず（random=42 で再現性あり）
        expect(orchestrator.state.value.chargedSpecialCount, player.ultCost,
            reason: 'offense でも FEAT-300 hotfix で chargedSpecialCount は蓄積する');

        // queue 立ててから「大技」ログが出るまでを観察
        final queueResult = orchestrator.tryQueueUltimate();
        expect(queueResult, UltimateQueueResult.queued);

        bool ultLogObserved = false;
        for (int i = 0; i < 30; i++) {
          fake.elapse(const Duration(milliseconds: 50));
          if (orchestrator.state.value.logLines.any((l) => l.contains('大技'))) {
            ultLogObserved = true;
            break;
          }
        }
        orchestrator.dispose();

        expect(ultLogObserved, isTrue,
            reason: 'Tactic.offense でも queue 経路で大技ログが出る = Tactic 非依存性確認');
      });
    });

    // ── シナリオ F ───────────────────────────────────────────────
    test('シナリオ F: berserker ultCost=1 で 1 回 normal だけで queue 可能 '
        '(Pre-mortem #5 ジョブ駆動退行回避)', () {
      // berserker は ultCost=1 → normal 1 回で chargedSpecialCount 満タン → queue 可能。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '狂戦士', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100,
          atk: 10, spd: 100,
          ultCost: 1,
          jobName: '狂戦士',
        );
        final enemy = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 100000, currentHp: 100000,
          atk: 0, spd: 1,
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orchestrator.start();

        // 0.5 秒以内に normal が 1 回 出れば chargedSpecialCount=1 = ultCost=1 で満タン。
        for (int i = 0; i < 30; i++) {
          fake.elapse(const Duration(milliseconds: 50));
          if (orchestrator.state.value.chargedSpecialCount >= 1) break;
        }
        expect(orchestrator.state.value.chargedSpecialCount, greaterThanOrEqualTo(1),
            reason: 'berserker (ultCost=1): 1 ターンで満タン到達');

        final result = orchestrator.tryQueueUltimate();
        orchestrator.dispose();

        expect(result, UltimateQueueResult.queued,
            reason: 'ultCost=1 動的評価で queue 成功');
      });
    });
  });
}
