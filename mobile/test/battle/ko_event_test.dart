// 【FEAT-526 (2026-08-21)】KO 演出のモデル層契約テスト。
//
// 「敵を倒した瞬間に一瞬止めて、最後の一撃を強調する」演出の起点は
// `BattleState.koEvent` ただ 1 つ。ここが正しく立つ / 立たないことを縛る。
//
// 🔴 `BattleStatus` に新しい値を足していないことも合わせて縛る (指示書 §4.1)。
// `BattleStatus.running` を見ているガードは orchestrator だけで 6 箇所あり、
// `battle_provider._finishSent` / `ambient_auto_battle_orchestrator` の終了判定 /
// backend への finish payload まで波及するため、値の追加は事故になる。
//
// 実時間待機ではなく fakeAsync を使う (battle_flow_test.dart と同じ理由 ——
// 実 Timer の発火回数がフル test 実行時の CPU 競合で変動して flaky になる)。
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/constants/battle_constants.dart';
import 'package:sabiowl/features/battle/engine/tactic_resolver.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/services/battle_orchestrator.dart';
import 'package:sabiowl/features/battle/widgets/combatant_sprite.dart';

/// 勇者が圧勝する組み合わせ (battle_flow_test シナリオ A と同じ数値)。
BattleOrchestrator _winningBattle() => BattleOrchestrator(
      player: Combatant(
        id: 'player', name: '勇者', spriteKey: 'sabi',
        maxHp: 100, currentHp: 100, atk: 30, spd: 100,
      ),
      enemy: Combatant(
        id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
        maxHp: 60, currentHp: 60, atk: 5, spd: 50,
      ),
      tactic: Tactic.offense,
      resolver: TacticResolver(random: Random(42)),
    );

/// 勇者が確実に負ける組み合わせ (同 シナリオ B)。
BattleOrchestrator _losingBattle() => BattleOrchestrator(
      player: Combatant(
        id: 'player', name: '勇者', spriteKey: 'sabi',
        maxHp: 10, currentHp: 10, atk: 1, spd: 1,
      ),
      enemy: Combatant(
        id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
        maxHp: 100, currentHp: 100, atk: 50, spd: 100,
      ),
      tactic: Tactic.offense,
      resolver: TacticResolver(random: Random(42)),
    );

void main() {
  group('FEAT-526 koEvent — とどめの一撃だけを拾う', () {
    test('status = won になった時点で koEvent が non-null になる', () {
      FakeAsync().run((fake) {
        final o = _winningBattle();
        o.start();
        fake.elapse(const Duration(seconds: 3));
        final s = o.state.value;
        o.dispose();

        expect(s.status, BattleStatus.won);
        expect(s.koEvent, isNotNull, reason: 'とどめの一撃で KO 演出が起動する');
        expect(s.koEvent!.damage, greaterThan(0),
            reason: 'とどめのダメージ量を持つ (演出強度の調整に使える)');
      });
    });

    test('🔴 lost では koEvent が null のまま', () {
      // 「決めた」と「やられた」は演出の意味が逆。敗北演出は別設計が要る
      // (指示書 決定事項 3)。ここが漏れると敗北時に「K.O.」が出て意味が反転する。
      FakeAsync().run((fake) {
        final o = _losingBattle();
        o.start();
        fake.elapse(const Duration(seconds: 5));
        final s = o.state.value;
        o.dispose();

        expect(s.status, BattleStatus.lost);
        expect(s.koEvent, isNull);
      });
    });

    test('戦闘中 (running) は koEvent が立たない', () {
      FakeAsync().run((fake) {
        final o = _winningBattle();
        o.start();
        // 1 tick だけ進める = まだ決着していない
        fake.elapse(const Duration(milliseconds: BattleConstants.tickMs));
        final s = o.state.value;
        expect(s.status, BattleStatus.running);
        expect(s.koEvent, isNull);
        o.dispose();
      });
    });

    test('1 バトルで koEvent は 1 回しか立たない (同一 timestamp のまま変わらない)',
        () {
      // status が一度 won になると running ガードで以降の tick が入らないので、
      // 構造的に 1 回きり。**「演出が 2 回以上出ない」の根拠がここ。**
      FakeAsync().run((fake) {
        final o = _winningBattle();
        final seen = <KoEvent>[];
        o.state.addListener(() {
          final e = o.state.value.koEvent;
          if (e != null && (seen.isEmpty || seen.last != e)) seen.add(e);
        });
        o.start();
        fake.elapse(const Duration(seconds: 10)); // 決着後もしばらく回す
        o.dispose();

        expect(seen.length, 1, reason: '別 timestamp の KoEvent は 2 個目が出ない');
      });
    });

    test('🔴 演出中に次の攻撃処理が進まない (rounds が増えない)', () {
      // ヒットストップの土台は既存の `_atb.pause()`。KO 演出 (650ms) の間に
      // 次のターンが解決されると、**倒したはずの敵がもう一発殴ってくる**。
      FakeAsync().run((fake) {
        final o = _winningBattle();
        o.start();
        fake.elapse(const Duration(seconds: 3));
        expect(o.state.value.status, BattleStatus.won);
        final roundsAtKo = o.state.value.rounds;
        final hpAtKo = o.state.value.player.currentHp;

        // 演出時間 (650ms) を大きく超えて回す
        fake.elapse(const Duration(seconds: 5));
        final s = o.state.value;
        o.dispose();

        expect(s.rounds, roundsAtKo, reason: 'ターンが 1 つも進んでいない');
        expect(s.player.currentHp, hpAtKo, reason: '倒した敵に殴られていない');
      });
    });
  });

  group('FEAT-526 §4.1 BattleStatus に値を足していない', () {
    test('BattleStatus は 5 値のまま (waiting/running/won/lost/abandoned)', () {
      // 出典は attacking → finalHit → hitStop → koZoom → ... の状態遷移を
      // 提案しているが、**表示レイヤーの関心事をモデルに持ち込まない**。
      expect(
        BattleStatus.values.map((e) => e.name).toList(),
        ['waiting', 'running', 'won', 'lost', 'abandoned'],
      );
    });
  });

  group('FEAT-526 §4.5 とどめの姿勢を固定する (A 案)', () {
    test('🔴 KO 後は両者が idle に戻らない', () {
      // `_triggerAttackEffect` の復帰 Timer は素の `Timer` なので
      // `_atb.pause()` では止まらない。KO 演出 (650ms) の途中で発火すると
      // **両者が idle に戻って待機ユラユラが再開する** = 間の抜けた絵になる。
      FakeAsync().run((fake) {
        final o = _winningBattle();
        o.start();
        fake.elapse(const Duration(seconds: 3));
        expect(o.state.value.status, BattleStatus.won);

        // 復帰 Timer の遅延 (500ms) と KO 演出 (650ms) を十分に超えて進める
        fake.elapse(const Duration(seconds: 2));
        final s = o.state.value;
        o.dispose();

        expect(s.playerAction, isNot(SpriteAction.idle),
            reason: 'とどめを刺した側が待機モーションに戻ってはいけない');
        expect(s.enemyAction, isNot(SpriteAction.idle),
            reason: 'やられた側が待機モーションに戻ってはいけない');
      });
    });

    test('とどめのダメージ表示も演出中クリアされない', () {
      // 復帰 Timer (フェーズ 3) は DamageEvent のクリアも兼ねている。
      // KO で張らない副作用として、**とどめの数字が演出中ずっと出ている**。
      FakeAsync().run((fake) {
        final o = _winningBattle();
        o.start();
        fake.elapse(const Duration(seconds: 5));
        final s = o.state.value;
        o.dispose();
        expect(s.status, BattleStatus.won);
        expect(s.enemyDamageEvent, isNotNull);
      });
    });

    test('通常の (KO でない) 攻撃では従来どおり idle に戻る', () {
      // A 案の早期 return と Timer キャンセルが **KO 以外にも効いてしまう** と、
      // 戦闘中ずっと攻撃モーションのまま固まる退行になる。ここが回帰ガード。
      //
      // spd = 10 なので 1 手あたり 300 / 10 = 30 tick = 3 秒。
      // 3.2 秒時点で 1 手目が済んでおり、次の手は 6 秒後 —— この隙間で
      // 復帰 Timer (500ms) が効いていることを確かめる。
      FakeAsync().run((fake) {
        final o = BattleOrchestrator(
          player: Combatant(
            id: 'player', name: '勇者', spriteKey: 'sabi',
            maxHp: 9999, currentHp: 9999, atk: 1, spd: 10,
          ),
          enemy: Combatant(
            id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
            maxHp: 9999, currentHp: 9999, atk: 1, spd: 10,
          ),
          tactic: Tactic.offense,
          resolver: TacticResolver(random: Random(42)),
        );
        o.start();
        fake.elapse(const Duration(milliseconds: 3200));
        expect(o.state.value.status, BattleStatus.running,
            reason: 'HP 9999 vs atk 1 なのでまだ決着しない');
        expect(o.state.value.rounds, greaterThan(0), reason: '攻撃は起きている');

        // 1 手目の復帰 Timer (500ms) が発火し切る位置まで進める
        fake.elapse(const Duration(milliseconds: 700));
        final s = o.state.value;
        o.dispose();
        expect(s.playerAction, SpriteAction.idle);
        expect(s.enemyAction, SpriteAction.idle);
        expect(s.enemyDamageEvent, isNull,
            reason: 'KO でなければ DamageEvent も従来どおりクリアされる');
      });
    });
  });
}
