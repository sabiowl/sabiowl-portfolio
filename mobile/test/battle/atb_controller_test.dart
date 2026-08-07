// 【FEAT-295 Phase 1a】ATB エンジン基礎の契約テスト 8 件。
//
// 検証対象:
//   - ゲージ 1.0 で onTurnReady 発火
//   - 発火後 atbGauge = 0.0 にリセット可能（resetGauge）
//   - pause() で tick 停止
//   - resume() で再開
//   - dispose() 後の tick が defunct を起こさない
//   - 攻撃重視作戦 × 50 回試行で normal/strong がほぼ 50/50
//   - 回復重視作戦 × HP 25% で heal 発火
//   - 大技温存作戦 × chargedSpecialCount=3 で ultimate 発火
// 【2026-07-25 codebase-functional-review 対応】実時間待機 (`await Future.delayed`)
// から fakeAsync 仮想時間へ移行。実 Timer (AtbController の tickRate) の発火回数が
// フル test 実行時の CPU 競合で変動し flaky だったため、仮想時間で完全決定論にする。
import 'package:fake_async/fake_async.dart';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/constants/battle_constants.dart';
import 'package:sabiowl/features/battle/engine/atb_controller.dart';
import 'package:sabiowl/features/battle/engine/tactic_resolver.dart';
import 'package:sabiowl/features/battle/models/ability.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';

// 【FEAT-297】tickRate を 100 → 200 に変更（戦闘体感速度調整）したため、
// ゲージ満タン到達に要する時間は spd / tickRate に依存する。
// テストは「常に 1 tick = 1.0/spd で満タン」となるよう
// spd = tickRate.toInt() を使い、time 待機は `BattleConstants.tickMs + マージン`
// で記述する（tickRate がさらに変わっても破綻しない）。
final int _fillIn1TickSpd = BattleConstants.tickRate.toInt();
const _waitOneTickMs = BattleConstants.tickMs * 2;  // 1 tick + マージン

void main() {
  group('AtbController (Pre-mortem #1: dispose race 防止)', () {
    test('ゲージが 1.0 に達した瞬間 onTurnReady が発火する', () {
      FakeAsync().run((fake) {
        final p = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, atk: 10, spd: _fillIn1TickSpd,
        );
        final e = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
          maxHp: 50, currentHp: 50, atk: 5, spd: 1,
        );

        Combatant? actor;
        final atb = AtbController(
          player: p,
          enemy:  e,
          onTurnReady: (a) => actor = a,
        );
        atb.start();

        // spd == tickRate → 1.0/tick → 1 tick でゲージ満タン
        fake.elapse(const Duration(milliseconds: _waitOneTickMs));
        atb.dispose();

        expect(actor, equals(p), reason: '高速 spd のプレイヤーが先にターン到達');
      });
    });

    test('resetGauge(actor) で atbGauge が 0.0 にリセットされる', () {
      final p = Combatant(
        id: 'player', name: '勇者', spriteKey: 'sabi',
        maxHp: 100, currentHp: 100, atk: 10, spd: 10,
        atbGauge: 1.0,
      );
      final e = Combatant(
        id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
        maxHp: 50, currentHp: 50, atk: 5, spd: 1,
      );
      final atb = AtbController(player: p, enemy: e, onTurnReady: (_) {});
      atb.resetGauge(p);
      expect(p.atbGauge, 0.0);
      atb.dispose();
    });

    test('pause() で tick 停止、ゲージは進行しない', () {
      FakeAsync().run((fake) {
        final p = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, atk: 10, spd: _fillIn1TickSpd ~/ 2,
        );
        final e = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
          maxHp: 50, currentHp: 50, atk: 5, spd: 1,
        );
        final atb = AtbController(player: p, enemy: e, onTurnReady: (_) {});
        atb.start();
        // tickMs × 0.5 で pause（1 tick 走る前後）
        fake.elapse(const Duration(milliseconds: BattleConstants.tickMs ~/ 2));
        atb.pause();
        final pausedGauge = p.atbGauge;
        fake.elapse(const Duration(milliseconds: BattleConstants.tickMs * 3));
        expect(p.atbGauge, pausedGauge, reason: 'pause 中はゲージ不変');
        expect(atb.isRunning, isFalse);
        atb.dispose();
      });
    });

    test('resume() で tick 再開', () {
      FakeAsync().run((fake) {
        final p = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, atk: 10, spd: _fillIn1TickSpd,
        );
        final e = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
          maxHp: 50, currentHp: 50, atk: 5, spd: 1,
        );
        bool fired = false;
        final atb = AtbController(
          player: p, enemy: e, onTurnReady: (_) => fired = true,
        );
        atb.start();
        // tickMs × 0.5 で一旦止めて、resume 後に十分待つ
        fake.elapse(const Duration(milliseconds: BattleConstants.tickMs ~/ 2));
        atb.pause();
        atb.resume();
        // resume 後、spd == tickRate → 1 tick で残りも満タン
        fake.elapse(const Duration(milliseconds: _waitOneTickMs));
        atb.dispose();
        expect(fired, isTrue, reason: 'resume 後にゲージ満タン → onTurnReady 発火');
      });
    });

    test('dispose() 後の tick callback が defunct を起こさない', () {
      FakeAsync().run((fake) {
        final p = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, atk: 10, spd: _fillIn1TickSpd,
        );
        final e = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
          maxHp: 50, currentHp: 50, atk: 5, spd: _fillIn1TickSpd,
        );
        var fireCount = 0;
        final atb = AtbController(
          player: p, enemy: e, onTurnReady: (_) => fireCount++,
        );
        atb.start();
        // start 直後に dispose（Timer が pending）
        atb.dispose();
        // 100ms 以上待っても callback は起きない
        fake.elapse(const Duration(milliseconds: 250));
        expect(fireCount, 0,
            reason: 'dispose 後の Timer callback は早期 return で何もしない');
      });
    });
  });

  group('TacticResolver (3 作戦の優先順位ロジック)', () {
    Combatant makeCombatant({int hp = 100, int maxHp = 100}) {
      return Combatant(
        id: 'player', name: '勇者', spriteKey: 'sabi',
        maxHp: maxHp, currentHp: hp, atk: 10, spd: 10,
      );
    }

    Combatant makeEnemy() => Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
          maxHp: 50, currentHp: 50, atk: 5, spd: 10,
        );

    test('攻撃重視 × 50 回試行で normal/strong がほぼ 50/50', () {
      final resolver = TacticResolver(random: Random(42));
      final state = BattleState(
        player:   makeCombatant(),
        enemy:    makeEnemy(),
        tactic:   Tactic.offense,
        status:   BattleStatus.running,
        logLines: [],
      );

      int normalCount = 0;
      int strongCount = 0;
      for (var i = 0; i < 100; i++) {
        final ability = resolver.resolveNextAbility(state);
        if (ability == Ability.normal) normalCount++;
        if (ability == Ability.strong) strongCount++;
      }
      expect(normalCount + strongCount, 100,
          reason: 'attack 系のみ発火、heal/ultimate は出ない');
      // 50/50 の理論値、±15% 許容（試行回数 100 で標準偏差 ~5）
      expect(normalCount, greaterThanOrEqualTo(35));
      expect(normalCount, lessThanOrEqualTo(65));
    });

    test('回復重視 × HP 25% で heal 発火', () {
      final resolver = TacticResolver(random: Random(42));
      final state = BattleState(
        player:   makeCombatant(hp: 25, maxHp: 100),  // 25%
        enemy:    makeEnemy(),
        tactic:   Tactic.recovery,
        status:   BattleStatus.running,
        logLines: [],
      );
      final ability = resolver.resolveNextAbility(state);
      expect(ability, Ability.heal, reason: 'HP < 30% で heal 確定');
    });

    test('回復重視 × HP 80% で normal 発火', () {
      final resolver = TacticResolver(random: Random(42));
      final state = BattleState(
        player:   makeCombatant(hp: 80, maxHp: 100),  // 80%
        enemy:    makeEnemy(),
        tactic:   Tactic.recovery,
        status:   BattleStatus.running,
        logLines: [],
      );
      final ability = resolver.resolveNextAbility(state);
      expect(ability, Ability.normal, reason: 'HP > 50% で normal');
    });

    // 【2026-07-02】仕様変更: 自動発動経路が Tactic.conserveUltimate から
    // Tactic.offense へ移動、conserveUltimate は手動発動のみ許可の仕様に変更。
    // テストの意味論を新仕様に合わせて再定義する。
    test('攻撃重視作戦 × chargedSpecialCount=3 で ultimate 自動発火', () {
      final resolver = TacticResolver(random: Random(42));
      final state = BattleState(
        player:   makeCombatant(),
        enemy:    makeEnemy(),
        tactic:   Tactic.offense,
        status:   BattleStatus.running,
        logLines: [],
        chargedSpecialCount: 3,
      );
      final ability = resolver.resolveNextAbility(state);
      expect(ability, Ability.ultimate,
          reason: 'Tactic.offense で canUltimate → ultimate 自動発動');
    });

    test('大技温存作戦 × chargedSpecialCount=3 でも自動発動しない (手動 queue のみ)', () {
      final resolver = TacticResolver(random: Random(42));
      final state = BattleState(
        player:   makeCombatant(),
        enemy:    makeEnemy(),
        tactic:   Tactic.conserveUltimate,
        status:   BattleStatus.running,
        logLines: [],
        chargedSpecialCount: 3,
      );
      final ability = resolver.resolveNextAbility(state);
      expect(ability, Ability.normal,
          reason: 'conserveUltimate は canUltimate でも自動発動なし、常に normal');
      expect(resolver.shouldReserveForUltimate(state), isTrue,
          reason: 'shouldReserveForUltimate は tactic == conserveUltimate で常に true');
    });
  });

  // 【FEAT-416 (2026-06-01)】倍速モード: AtbController.speedMultiplier 検証
  group('FEAT-416 倍速モード', () {
    test('speedMultiplier=2.0 で 1/2 の tick 数で発火', () {
      // spd を _fillIn1TickSpd の半分にして、倍速 2.0 で 1 tick 到達を確認。
      // 1x なら 2 tick 必要なところ、2x で 1 tick で到達する契約。
      FakeAsync().run((fake) {
        final p = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, atk: 10,
          spd: _fillIn1TickSpd ~/ 2,
        );
        final e = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
          maxHp: 50, currentHp: 50, atk: 5, spd: 1,
        );
        Combatant? actor;
        final atb = AtbController(
          player: p, enemy: e,
          onTurnReady: (a) => actor = a,
          speedMultiplier: 2.0,
        );
        atb.start();
        fake.elapse(const Duration(milliseconds: _waitOneTickMs));
        atb.dispose();
        expect(actor, equals(p), reason: '2 倍速なら spd/2 でも 1 tick で発火');
      });
    });

    test('setSpeedMultiplier 直後に atbGauge は不変 (次 tick から加速)', () {
      // pause 中に setSpeedMultiplier を呼んでも atbGauge は変化しない。
      // ゲージ加速は次回 tick (_onTick) から反映される設計。
      FakeAsync().run((fake) {
        final p = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, atk: 10,
          spd: _fillIn1TickSpd ~/ 4,
        );
        final e = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'goblin',
          maxHp: 50, currentHp: 50, atk: 5, spd: 1,
        );
        final atb = AtbController(
          player: p, enemy: e, onTurnReady: (_) {},
          speedMultiplier: 1.0,
        );
        atb.start();
        fake.elapse(const Duration(milliseconds: _waitOneTickMs));
        atb.pause();
        final beforeGauge = p.atbGauge;
        atb.setSpeedMultiplier(2.0);
        expect(p.atbGauge, beforeGauge,
            reason: 'setSpeedMultiplier は atbGauge を変更しない (次 tick から加速)');
        atb.dispose();
      });
    });
  });
}
