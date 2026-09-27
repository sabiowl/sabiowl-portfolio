// 【FEAT-526 (2026-08-22 ユーザー確定)】額縁 (アンビエント) でも KO 演出を出す。
//
// 当初の決定事項 2 は「バトル画面だけ」だったが、実機を見たユーザー判断で変更。
// ただし全画面の値をそのまま持ち込むと、額縁 (約 344 x 240px) に対して
// 「K.O.」64pt がはみ出し、暗転も既存の暗幕 55% と合わせてほぼ真っ黒になるため
// **縮小版** ([KoEffectStyle.ambient]) を使う。
//
// 縛る内容:
//   A. 額縁でとどめが入ると演出が出て、終わると元に戻る
//   B. 演出中は敵が消えない / 演出後に消える
//   C. 🔴 前のバトルの `koEvent` では発火しない（battle_page と同じ事故を額縁で繰り返さない）
//   D. 縮小版の値が全画面より小さい

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/constants/battle_constants.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/widgets/combatant_sprite.dart';
import 'package:sabiowl/features/battle/widgets/ko_effect_overlay.dart';
import 'package:sabiowl/features/battle/widgets/mini_battle_arena.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

class _FakeSessionNotifier extends BattleSessionNotifier {
  _FakeSessionNotifier(super.ref);
  void push(BattleSession session) => state = session;
}

Combatant _player() => Combatant(
      id: 'player', name: '勇者', spriteKey: 'sabi',
      maxHp: 100, currentHp: 100, atk: 10, spd: 10,
    );

Combatant _enemy({required int hp}) => Combatant(
      id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
      maxHp: 60, currentHp: hp, atk: 5, spd: 10,
    );

BattleState _running() => BattleState(
      player: _player(), enemy: _enemy(hp: 60), tactic: Tactic.offense,
      status: BattleStatus.running, logLines: const ['戦闘開始'],
      startedAt: DateTime(2026, 8, 22),
    );

BattleState _wonWithKo() => BattleState(
      player: _player(), enemy: _enemy(hp: 0), tactic: Tactic.offense,
      status: BattleStatus.won, logLines: const ['倒した'],
      startedAt: DateTime(2026, 8, 22),
      enemyAction: SpriteAction.recoil,
      koEvent: KoEvent(damage: 24, isCritical: false),
    );

SpriteAction _enemySpriteAction(WidgetTester tester) =>
    tester.widgetList<CombatantSprite>(find.byType(CombatantSprite)).first.action;

/// KO 演出が終わり切るまで進める。
///
/// ⚠️ `pumpAndSettle` は使えない (`CombatantSprite` の待機ユラユラが永久ループ)。
Future<void> _finishKoEffect(WidgetTester tester) async {
  await tester
      .pump(BattleConstants.koTotalDuration + const Duration(milliseconds: 80));
}

Future<void> _pumpToKoLabel(WidgetTester tester) async {
  await tester.pump(BattleConstants.koHitStopDuration +
      BattleConstants.koZoomInDuration +
      const Duration(milliseconds: 80));
}

Future<({ProviderContainer container, _FakeSessionNotifier notifier})> _pump(
  WidgetTester tester, {
  BattleSession? initialSession,
  void Function(KoEvent)? onKoDone,
}) async {
  late _FakeSessionNotifier notifier;
  final container = ProviderContainer(overrides: [
    battleSessionProvider.overrideWith((ref) {
      notifier = _FakeSessionNotifier(ref);
      return notifier;
    }),
  ]);
  addTearDown(container.dispose);
  container.read(battleSessionProvider.notifier);
  if (initialSession != null) notifier.push(initialSession);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('ja'),
      // 額縁の実寸に近い箱に入れる (344 x 240)
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 344,
            height: 240,
            child: MiniBattleArena(onKoDone: onKoDone),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return (container: container, notifier: notifier);
}

void main() {
  testWidgets('A: 額縁でとどめが入ると「K.O.」が出て、終わると消える',
      (tester) async {
    final h = await _pump(tester);
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();
    expect(find.byType(KoLabel), findsNothing);

    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();
    await _pumpToKoLabel(tester);
    expect(find.byType(KoLabel), findsOneWidget);

    await _finishKoEffect(tester);
    expect(find.byType(KoLabel), findsNothing, reason: '演出後は元に戻る');
  });

  testWidgets('B: 演出中は敵が消えず、演出後に消える', (tester) async {
    final h = await _pump(tester);
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();

    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();
    expect(_enemySpriteAction(tester), isNot(SpriteAction.fadeOut),
        reason: 'ズームする対象が残っていること');

    await _pumpToKoLabel(tester);
    expect(_enemySpriteAction(tester), isNot(SpriteAction.fadeOut));

    await _finishKoEffect(tester);
    expect(_enemySpriteAction(tester), SpriteAction.fadeOut);
  });

  testWidgets('🔴 C: 前のバトルの koEvent では発火しない', (tester) async {
    // battle_page で実際に起きた事故 (2026-08-22) と同型。額縁でも繰り返さない。
    await _pump(
      tester,
      initialSession: BattleSession(state: _wonWithKo(), finishCompleted: true),
    );
    await tester.pump();
    await _pumpToKoLabel(tester);
    expect(find.byType(KoLabel), findsNothing,
        reason: '前のバトルの KO をここで流してはいけない');
    expect(_enemySpriteAction(tester), SpriteAction.fadeOut,
        reason: 'ゲートも閉じたままにならない');
  });

  group('D: 縮小版の値', () {
    test('額縁の値はすべて全画面より小さい', () {
      const full = KoEffectStyle.fullscreen;
      const ambient = KoEffectStyle.ambient;
      expect(ambient.maxZoom, lessThan(full.maxZoom));
      expect(ambient.dimOpacity, lessThan(full.dimOpacity));
      expect(ambient.labelFontSize, lessThan(full.labelFontSize));
      expect(ambient.shakeAmplitude, lessThan(full.shakeAmplitude));
      expect(ambient.impactSize, lessThan(full.impactSize));
    });

    test('🔴 時間は共通 (空間方向だけを縮める)', () {
      // 画面ごとにテンポが変わると「同じ演出」だと認識できなくなる。
      // KoEffectStyle が Duration を持っていないことで構造的に保証する。
      const ambient = KoEffectStyle.ambient;
      expect(ambient.toString(), isNot(contains('Duration')));
      // 額縁専用の長さが増えていないこと (数値そのものは
      // `ko_speed_scaling_test.dart` が縛る)。
      expect(BattleConstants.koTotalDuration,
          BattleConstants.koHitStopDuration +
              BattleConstants.koZoomInDuration +
              BattleConstants.koLabelDuration +
              BattleConstants.koZoomOutDuration);
    });

    test('「K.O.」が額縁幅に収まる文字サイズであること', () {
      // 28pt x 4 文字 + letterSpacing ≒ 90px。額縁幅 344px に十分収まる。
      // 全画面の 64pt だと 4 文字で ~230px、ズーム 1.20 を掛けると 276px で
      // 額縁からはみ出す。
      expect(BattleConstants.koAmbientLabelFontSize, lessThanOrEqualTo(32));
    });
  });

  // ── 【2026-08-22 実機報告】額縁の KO 演出が一度も出ていなかった ──────────
  //
  // 🔴 真因は額縁側ではなく **ホスト (`WorldFrameSection`) の出し入れ条件**。
  // 旧実装は「戦闘中 = `status == running`」で額縁を出しており、KO 演出は
  // **`status` が `won` になるのと同じ state 更新**で始まるため、
  // 演出の開始と同時に `MiniBattleArena` ごと unmount されていた。
  //
  // 直し方は「子が『畳んでよい』と言うまでホストが残す」。その合図が
  // [MiniBattleArena.onKoDone] なので、ここでは **合図が必ず来ること**を縛る。
  // 来ないと今度は逆に**額縁が世界の絵に戻らなくなる**。
  group('E: KO 演出の後片付け合図 (onKoDone)', () {
    testWidgets('演出が終わると、その KoEvent で 1 回だけ呼ばれる', (tester) async {
      final calls = <KoEvent>[];
      final h = await _pump(tester, onKoDone: calls.add);
      h.notifier.push(BattleSession(state: _running()));
      await tester.pump();
      expect(calls, isEmpty, reason: '戦闘中に畳ませてはいけない');

      final ko = _wonWithKo();
      h.notifier.push(BattleSession(state: ko));
      await tester.pump();
      expect(calls, isEmpty, reason: '演出が終わる前に畳ませてはいけない');

      await _finishKoEffect(tester);
      expect(calls, [ko.koEvent], reason: '演出が終わったら必ず合図する');

      // 同じ event で二度目が来ない (親の setState が無駄に走らない)
      h.notifier.push(BattleSession(state: ko, finishCompleted: true));
      await tester.pump();
      expect(calls.length, 1);
    });

    testWidgets('🔴 敗北 (koEvent なし) では呼ばれない = 従来どおり即畳む',
        (tester) async {
      final calls = <KoEvent>[];
      final h = await _pump(tester, onKoDone: calls.add);
      h.notifier.push(BattleSession(
        state: BattleState(
          player: _player(), enemy: _enemy(hp: 30), tactic: Tactic.offense,
          status: BattleStatus.lost, logLines: const ['やられた'],
          startedAt: DateTime(2026, 8, 22),
        ),
      ));
      await tester.pump();
      await _finishKoEffect(tester);
      expect(calls, isEmpty);
    });
  });


  // ── 【2026-08-22 実機報告 2】額縁が決着後の絵のまま貼り付いた ────────────
  //
  // 🔴 ホストは「`onKoDone` が来るまで畳まない」ので、**演出を出さない経路でも
  // 必ず返す**必要がある。返していなかった経路は 2 つ。
  //
  //   1. 全画面 BattlePage が上に乗っている (`isCurrent` が false)
  //   2. 決着**後**に額縁が組まれた (listener が一度も呼ばれない)
  //
  // どちらも「再生しないが、畳んでよい」が正解。**再生してはいけない** ——
  // 決着済みの koEvent をここで流すと「前のバトルの KO」が出る。
  group('F: 演出を出さない経路でも必ず畳ませる', () {
    testWidgets('🔴 決着後に mount された額縁は、再生せず即 onKoDone を返す',
        (tester) async {
      final calls = <KoEvent>[];
      final ko = _wonWithKo();
      // **mount 前に**決着済み session を仕込む = 全画面で勝ってホームに戻る経路
      await _pump(
        tester,
        initialSession: BattleSession(state: ko, finishCompleted: true),
        onKoDone: calls.add,
      );
      await tester.pump();

      expect(calls, [ko.koEvent], reason: '返さないと額縁が世界に貼り付く');

      await _pumpToKoLabel(tester);
      expect(find.byType(KoLabel), findsNothing,
          reason: '決着済みの KO をここで再生してはいけない');
    });

    testWidgets('一度返した KoEvent は二度返さない', (tester) async {
      final calls = <KoEvent>[];
      final ko = _wonWithKo();
      final h = await _pump(
        tester,
        initialSession: BattleSession(state: ko),
        onKoDone: calls.add,
      );
      await tester.pump();
      h.notifier.push(BattleSession(state: ko, finishCompleted: true));
      await tester.pump();
      expect(calls.length, 1);
    });
  });

}
