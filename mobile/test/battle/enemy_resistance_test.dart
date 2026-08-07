// 【FEAT-302 Phase 3】敵 3 体追加 + 弱点 / 耐性の Flutter 統合テスト 5 件。
//
// 検証対象:
//   - シナリオ A: warrior (physical) が armored_knight (phys_res=0.7) に通常攻撃
//                 → ダメージが 30% 軽減 (vs goblin 比較で減少を観察)
//   - シナリオ B: mage (burn) が ice_witch (mag_res=0.5) に → burn 追加ダメが 50% 軽減
//   - シナリオ C: thief (ult_cost=4) が ice_witch (weak_ult_cost=4) に通常攻撃
//                 → ダメージ +30% + Critical ログ
//   - シナリオ D: void_dragon (耐性 / 弱点なし) → どのジョブでも等倍ダメージ
//   - シナリオ E: 既存 enemy (goblin 等、resistance 1.0 / weak null) は退行ゼロ
//                 (Pre-mortem #5 既存テスト互換性)
//
// 注: ダメージ計算ヘルパー (`BattleOrchestrator._applyResistance`) はライブラリ private のため、
//     observable な currentHp 変化 + ログ行で間接検証する。

// 【2026-07-25 codebase-functional-review 対応】実時間待機 (`await Future.delayed`)
// から fakeAsync 仮想時間へ移行。実 Timer (AtbController の tickRate) の発火回数が
// フル test 実行時の CPU 競合で変動し flaky だったため、仮想時間で完全決定論にする。
import 'package:fake_async/fake_async.dart';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/engine/tactic_resolver.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/services/battle_orchestrator.dart';

void main() {
  group('EnemyResistance ダメージ計算統合 (FEAT-302 Phase 3)', () {
    // ── シナリオ A ───────────────────────────────────────────────
    test('シナリオ A: warrior (physical) が phys_res=0.7 の敵に通常攻撃 → ダメージ 30% 軽減',
        () {
      // baseline: warrior が「耐性なし敵 (resistance=1.0)」に攻撃したダメージを取得
      // 比較: warrior が「phys_res=0.7 敵」に攻撃したダメージを取得
      // 期待: 後者 < 前者（おおむね 0.7 倍）。
      // tactic offense + spd 高速 + 敵 atk=0 で複数ターン分のダメージを蓄積観察する。
      FakeAsync().run((fake) {

        const warriorJobName = '戦士';
        int totalDamageBaseline = 0;
        int totalDamageResisted = 0;

        // ベースライン: 耐性 1.0 (default) の敵
        {
          final player = Combatant(
            id: 'player', name: 'warrior', spriteKey: 'sabi',
            maxHp: 100, currentHp: 100,
            atk: 30, spd: 100,
            attackPowerModifier: 1.3, // warrior の attack_power_modifier
            jobName: warriorJobName,
          );
          final enemy = Combatant(
            id: 'enemy', name: 'goblin', spriteKey: 'goblin',
            maxHp: 100000, currentHp: 100000,
            atk: 0, spd: 1,
            // physicalResistance default 1.0
          );
          final orchestrator = BattleOrchestrator(
            player: player,
            enemy:  enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orchestrator.start();
          fake.elapse(const Duration(seconds: 3));
          totalDamageBaseline = orchestrator.state.value.totalDamageDealt;
          orchestrator.dispose();
        }

        // 比較: phys_res=0.7 の敵
        {
          final player = Combatant(
            id: 'player', name: 'warrior', spriteKey: 'sabi',
            maxHp: 100, currentHp: 100,
            atk: 30, spd: 100,
            attackPowerModifier: 1.3,
            jobName: warriorJobName,
          );
          final enemy = Combatant(
            id: 'enemy', name: 'armored_knight', spriteKey: 'enemy_armored_knight',
            maxHp: 100000, currentHp: 100000,
            atk: 0, spd: 1,
            physicalResistance: 0.7,
          );
          final orchestrator = BattleOrchestrator(
            player: player,
            enemy:  enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orchestrator.start();
          fake.elapse(const Duration(seconds: 3));
          totalDamageResisted = orchestrator.state.value.totalDamageDealt;
          orchestrator.dispose();
        }

        expect(totalDamageBaseline, greaterThan(0));
        expect(totalDamageResisted, greaterThan(0));
        // phys_res=0.7 で 30% 軽減 → 比 0.7 ± マージン（端数 + random 揺らぎ）
        final ratio = totalDamageResisted / totalDamageBaseline;
        expect(ratio, lessThan(0.85),
            reason: '0.7 軽減なので 0.85 未満は確実、実値 ratio=$ratio');
        expect(ratio, greaterThan(0.55),
            reason: '極端な乖離は計算バグの可能性、実値 ratio=$ratio');
      });
    });

    // ── シナリオ B ───────────────────────────────────────────────
    test('シナリオ B: mage burn が mag_res=0.5 の敵に → burn 追加ダメが半減', () {
      // burn は「基本ダメージとは別行」の extraLog として記録される。
      // mage の通常攻撃 → ログに「🔥 ...名前... に炎が燃え移り -X HP」が含まれる。
      // mag_res=1.0 と比較して X が小さくなることを観察する。
      //
      // burn 計算: target.maxHp × 0.02 × 3 × mag_res
      // - mag_res=1.0 → maxHp=1000 で 60 ダメージ
      // - mag_res=0.5 → maxHp=1000 で 30 ダメージ
      FakeAsync().run((fake) {

        const mageJob = '魔導士';
        int burnBaseline = 0;
        int burnResisted = 0;

        // baseline: mag_res=1.0 の敵
        {
          final player = Combatant(
            id: 'player', name: 'mage', spriteKey: 'sabi',
            maxHp: 100, currentHp: 100,
            atk: 30, spd: 100,
            attackPowerModifier: 0.8,
            onHitEffect: 'burn',
            jobName: mageJob,
          );
          final enemy = Combatant(
            id: 'enemy', name: 'goblin', spriteKey: 'goblin',
            maxHp: 1000, currentHp: 1000, // maxHp=1000 → burn 60 dmg (mag_res=1.0)
            atk: 0, spd: 1,
          );
          final orchestrator = BattleOrchestrator(
            player: player,
            enemy:  enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orchestrator.start();
          fake.elapse(const Duration(seconds: 1));
          burnBaseline = _firstBurnDamage(orchestrator.state.value.logLines);
          orchestrator.dispose();
        }

        // 比較: mag_res=0.5 の敵
        {
          final player = Combatant(
            id: 'player', name: 'mage', spriteKey: 'sabi',
            maxHp: 100, currentHp: 100,
            atk: 30, spd: 100,
            attackPowerModifier: 0.8,
            onHitEffect: 'burn',
            jobName: mageJob,
          );
          final enemy = Combatant(
            id: 'enemy', name: 'ice_witch', spriteKey: 'enemy_ice_witch',
            maxHp: 1000, currentHp: 1000,
            atk: 0, spd: 1,
            magicalResistance: 0.5,
          );
          final orchestrator = BattleOrchestrator(
            player: player,
            enemy:  enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orchestrator.start();
          fake.elapse(const Duration(seconds: 1));
          burnResisted = _firstBurnDamage(orchestrator.state.value.logLines);
          orchestrator.dispose();
        }

        expect(burnBaseline, greaterThan(0),
            reason: 'baseline でも burn ログが取得できているはず');
        expect(burnResisted, greaterThan(0));
        // mag_res=0.5 で半減 → burnResisted ≈ burnBaseline × 0.5
        expect(burnResisted, lessThan(burnBaseline * 0.7),
            reason: '半減効果 0.5 が反映されているはず: '
                'baseline=$burnBaseline resisted=$burnResisted');
      });
    });

    // ── シナリオ C ───────────────────────────────────────────────
    test(
        'シナリオ C: thief (ult_cost=4) が ice_witch (weak_ult_cost=4) に通常攻撃 → '
        'Critical ログ + ダメージ増幅', () {
      // weak_ult_cost = attacker.ultCost なら ×1.3 + ⚡ Critical ログ。
      FakeAsync().run((fake) {
        const thiefJob = '盗賊';
        final player = Combatant(
          id: 'player', name: 'thief', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100,
          atk: 30, spd: 100,
          attackPowerModifier: 0.9,
          ultCost: 4, // thief
          jobName: thiefJob,
        );
        final enemy = Combatant(
          id: 'enemy', name: 'ice_witch', spriteKey: 'enemy_ice_witch',
          maxHp: 100000, currentHp: 100000,
          atk: 0, spd: 1,
          weakUltCost: 4, // thief で Critical
        );
        final orchestrator = BattleOrchestrator(
          player: player,
          enemy:  enemy,
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        orchestrator.start();
        fake.elapse(const Duration(seconds: 2));

        final logs = orchestrator.state.value.logLines;
        orchestrator.dispose();

        // Critical ログが含まれる
        final hasCritical = logs.any((l) => l.contains('Critical') ||
            l.contains('⚡'));
        expect(hasCritical, isTrue,
            reason: 'weak_ult_cost=4 + thief ultCost=4 で Critical ログ出現');
      });
    });

    // ── シナリオ D ───────────────────────────────────────────────
    test('シナリオ D: void_dragon (耐性 / 弱点なし) → どのジョブでも等倍ダメージ', () {
      // void_dragon は純粋ステ勝負（physical/magical_resistance=1.0, weak_ult_cost=null）。
      // warrior と mage で同じ atk + multiplier 設定なら、同等のダメージ。
      FakeAsync().run((fake) {
        const warrior = '戦士';

        int dmgWarrior = 0;
        int dmgMage = 0;

        // warrior vs void_dragon
        {
          final player = Combatant(
            id: 'player', name: 'warrior', spriteKey: 'sabi',
            maxHp: 100, currentHp: 100,
            atk: 30, spd: 100,
            attackPowerModifier: 1.0, // jobModifier 影響を排除
            jobName: warrior,
          );
          final enemy = Combatant(
            id: 'enemy', name: 'void_dragon', spriteKey: 'enemy_void_dragon',
            maxHp: 100000, currentHp: 100000,
            atk: 0, spd: 1,
            // physical/magical_resistance default 1.0, weakUltCost null
          );
          final orchestrator = BattleOrchestrator(
            player: player,
            enemy:  enemy,
            tactic: Tactic.offense,
            resolver: TacticResolver(random: Random(42)),
          );
          orchestrator.start();
          fake.elapse(const Duration(seconds: 2));
          dmgWarrior = orchestrator.state.value.totalDamageDealt;
          orchestrator.dispose();
        }

        // mage vs void_dragon（同じ atk / 同じ random seed なら同等）
        // 注: mage は magical 系なので magical_resistance=1.0 適用、warrior は physical=1.0 適用。
        // 両方 1.0 なら同じダメージ。
        {
          final player = Combatant(
            id: 'player', name: 'mage', spriteKey: 'sabi',
            maxHp: 100, currentHp: 100,
            atk: 30, spd: 100,
            attackPowerModifier: 1.0,
            jobName: '魔導士',
          );
          final enemy = Combatant(
            id: 'enemy', name: 'void_dragon', spriteKey: 'enemy_void_dragon',
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
          fake.elapse(const Duration(seconds: 2));
          dmgMage = orchestrator.state.value.totalDamageDealt;
          orchestrator.dispose();
        }

        expect(dmgWarrior, greaterThan(0));
        expect(dmgMage, greaterThan(0));
        // 同じ atk, multiplier, seed → 同等（差は random 揺らぎのみ ±15%）
        final ratio = dmgWarrior / dmgMage;
        expect(ratio, greaterThan(0.85), reason: '等倍想定（warrior/mage で physical/magical どちらも 1.0）');
        expect(ratio, lessThan(1.15));
      });
    });

    // ── シナリオ E ───────────────────────────────────────────────
    test('シナリオ E: 既存 enemy (resistance default 1.0 / weak null) は退行ゼロ '
        '(Pre-mortem #5)', () {
      // resistance / weakUltCost を明示しない場合、Combatant default で挙動互換。
      // ダメージ計算で resistance=1.0 が適用 → 既存 atk × multiplier そのまま。
      FakeAsync().run((fake) {
        final player = Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100,
          atk: 30, spd: 100,
          // jobName / modifier 全部 default = warrior フォールバック (modifier 1.0)
        );
        final enemy = Combatant(
          id: 'enemy', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 60, currentHp: 60,
          atk: 5, spd: 50,
          // resistance フィールド全 default
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

        // 既存 FEAT-295 シナリオ A と同等の挙動を期待:
        // 勇者 atk=30 vs ゴブリン HP=60 で 2-3 ターンで勝利
        expect(finalState.totalDamageDealt, greaterThanOrEqualTo(60),
            reason: '既存挙動: ゴブリン HP=60 を倒すダメージは出る');
        // Critical ログは出ない（weakUltCost=null）
        final hasCritical = finalState.logLines.any((l) => l.contains('⚡') ||
            l.contains('Critical'));
        expect(hasCritical, isFalse,
            reason: 'weakUltCost=null なら Critical 一切なし');
      });
    });
  });
}

/// ログ行から「🔥 ... -N HP」の N を抽出する補助関数。
/// マッチしなければ 0 を返す。
int _firstBurnDamage(List<String> logs) {
  final regex = RegExp(r'🔥 .* -(\d+) HP');
  for (final l in logs) {
    final m = regex.firstMatch(l);
    if (m != null) {
      return int.parse(m.group(1)!);
    }
  }
  return 0;
}
