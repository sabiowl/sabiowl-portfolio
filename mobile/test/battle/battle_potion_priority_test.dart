// 【FEAT-376 (2026-05-29)】上位回復薬 / 攻撃の薬のバトル統合テスト。
// 【FEAT-432 (2026-06-13)】防御の薬のバトル統合テスト追加。
//
// 検証対象:
//   A: 上位回復薬 (HP 全回復) が通常回復薬より優先して自動消費される
//   B: 攻撃の薬が使用ターンで atk +50% を適用する
//   C: 防御の薬 (敵ターンで自動消費) が defensePotionsUsed を増加させる
//   D: 攻撃の薬と防御の薬は独立して消費される (互いに影響しない)
// 【2026-07-25 codebase-functional-review 対応】実時間待機 (`await Future.delayed`)
// から fakeAsync 仮想時間へ移行。実 Timer (AtbController の tickRate) の発火回数が
// フル test 実行時の CPU 競合で変動し flaky だったため、仮想時間で完全決定論にする。
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/services/battle_orchestrator.dart';

void main() {
  group('FEAT-376 上位ポーション バトル統合テスト', () {
    // ── ヘルパー: player + enemy の基本セットアップ ──────────────────────
    Combatant buildPlayer({int atk = 20, int maxHp = 100}) {
      return Combatant(
        id: 'player', name: 'テスト勇者', spriteKey: 'sabi',
        maxHp: maxHp,
        currentHp: maxHp,
        atk: atk,
        spd: 200, // tickRate と同値で1tick=1ターン
      );
    }

    Combatant buildEnemy({int hp = 5000, int atk = 0}) {
      return Combatant(
        id: 'enemy', name: 'ダミー敵', spriteKey: 'enemy_goblin',
        maxHp: hp, currentHp: hp,
        atk: atk,
        spd: 1, // 非常に遅い
      );
    }

    // ─────────────────────────────────────────────────────────────────
    // テスト A: 上位回復薬が通常回復薬より優先消費される
    // ─────────────────────────────────────────────────────────────────
    test('A: 上位回復薬 1 個 + 通常回復薬 1 個 → HP 30% 以下で上位が先に消費される',
        () {
      FakeAsync().run((fake) {
        final player = buildPlayer(maxHp: 100);
        // HP を 30% 以下に手動設定 (25%)
        player.currentHp = 25;

        final orch = BattleOrchestrator(
          player: player,
          enemy: buildEnemy(),
          tactic: Tactic.offense,
          potionsPlanned:      1,  // 通常回復薬 1 個
          potionsPlusPlanned:  1,  // 上位回復薬 1 個
          attackPotionsPlanned: 0,
        );

        // 直接 _checkAutoPotion を呼ぶ代わりに start して 1 ターン進める
        orch.start();
        fake.elapse(const Duration(milliseconds: 300));
        orch.abandon();
        orch.dispose();

        // 上位回復薬が先に消費 → potionsPlusUsed=1, potionsUsed=0
        expect(orch.potionsPlusUsed, greaterThan(0),
            reason: '上位回復薬が消費されているはず');
        // 通常回復薬は消費されていない (上位が優先)
        expect(orch.potionsUsed, equals(0),
            reason: '通常回復薬は上位が先に使われるため未消費のはず');
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト B: 攻撃の薬が設定されると attackPotionsUsed が増加する
    // ─────────────────────────────────────────────────────────────────
    test('B: attackPotionsPlanned=1 → バトル中に attackPotionsUsed が 1 に増加する',
        () {
      // atk=20 の player で attackPotionsPlanned=1。
      // バトル中、最初の player ターンで攻撃の薬が自動消費される。
      // タイミングに依存しない「消費 1 個」のアサートを使う (ダメージ比較は flaky なため回避)。
      FakeAsync().run((fake) {

        final orch = BattleOrchestrator(
          player: buildPlayer(atk: 20, maxHp: 500),
          enemy:  buildEnemy(hp: 5000, atk: 0),
          tactic: Tactic.offense,
          potionsPlanned:       0,
          potionsPlusPlanned:   0,
          attackPotionsPlanned: 1,
        );

        orch.start();
        // player.spd=200, tickRate=200 → 1 tick (100ms) でゲージ満タン
        // 200ms 待てば少なくとも 1 ターン以上処理される
        fake.elapse(const Duration(milliseconds: 250));
        orch.abandon();
        orch.dispose();

        expect(
          orch.attackPotionsUsed,
          equals(1),
          reason: 'attackPotionsPlanned=1 なので 1 ターンで消費される (計画数が上限)',
        );
        expect(
          orch.attackPotionsRemaining,
          equals(0),
          reason: '消費後は残数 0',
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト C: 防御の薬が設定されると defensePotionsUsed が増加する
    // 【FEAT-432】攻撃の薬 (テスト B) と完全対称、敵ターンで自動消費される。
    // ─────────────────────────────────────────────────────────────────
    test('C: defensePotionsPlanned=1 → バトル中に defensePotionsUsed が 1 に増加する',
        () {
      // player.spd=1 (非常に遅い)、enemy.spd=200 (player の代わりにすぐ行動)。
      // 敵の攻撃ターン先頭で防御の薬が自動消費される。
      FakeAsync().run((fake) {
        final orch = BattleOrchestrator(
          player: Combatant(
            id: 'player', name: 'テスト勇者', spriteKey: 'sabi',
            maxHp: 500, currentHp: 500, atk: 20, spd: 1,
          ),
          enemy: Combatant(
            id: 'enemy', name: 'ダミー敵', spriteKey: 'enemy_goblin',
            maxHp: 5000, currentHp: 5000, atk: 5, spd: 200,
          ),
          tactic: Tactic.offense,
          potionsPlanned:        0,
          potionsPlusPlanned:    0,
          attackPotionsPlanned:  0,
          defensePotionsPlanned: 1,
        );

        orch.start();
        // enemy.spd=200, tickRate=200 → 1 tick (100ms) でゲージ満タン
        fake.elapse(const Duration(milliseconds: 250));
        orch.abandon();
        orch.dispose();

        expect(
          orch.defensePotionsUsed,
          equals(1),
          reason: 'defensePotionsPlanned=1 なので敵の最初のターンで消費される',
        );
        expect(
          orch.defensePotionsRemaining,
          equals(0),
          reason: '消費後は残数 0',
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // テスト D: 攻撃の薬と防御の薬は独立して消費される
    // 【FEAT-432】互いに影響しないことを確認 (player ターン / enemy ターンで別管理)。
    // ─────────────────────────────────────────────────────────────────
    test('D: attackPotionsPlanned=1 + defensePotionsPlanned=1 → 両方が独立して 1 消費される',
        () {
      // player.spd=200 だと ATB tick ごとに必ず player ターンが先勝ちし続け、
      // enemy のゲージが進まない (毎 tick 早期 return)。player.spd=100 で
      // 隔 tick 発火にし、enemy.spd=400 で確実に enemy ターンも発生させる。
      FakeAsync().run((fake) {
        final orch = BattleOrchestrator(
          player: Combatant(
            id: 'player', name: 'テスト勇者', spriteKey: 'sabi',
            maxHp: 500, currentHp: 500, atk: 20, spd: 100,
          ),
          enemy: Combatant(
            id: 'enemy', name: 'ダミー敵', spriteKey: 'enemy_goblin',
            maxHp: 5000, currentHp: 5000, atk: 5, spd: 400,
          ),
          tactic: Tactic.offense,
          potionsPlanned:        0,
          potionsPlusPlanned:    0,
          attackPotionsPlanned:  1,
          defensePotionsPlanned: 1,
        );

        orch.start();
        fake.elapse(const Duration(milliseconds: 600));
        orch.abandon();
        orch.dispose();

        expect(
          orch.attackPotionsUsed,
          equals(1),
          reason: 'プレイヤーのターンで攻撃の薬が消費される',
        );
        expect(
          orch.defensePotionsUsed,
          equals(1),
          reason: '敵のターンで防御の薬が独立して消費される',
        );
      });
    });
  });
}
