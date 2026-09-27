// 【FEAT-526 (2026-08-21)】KO 演出ゲートの統合テスト —— BattlePage を実際に描画する。
//
// 指示書 §4.4 が「最も壊れやすい」と名指しした 2 点を、**実画面で**縛る。
//
//   1. 演出完了前は敵が `fadeOut` に入らない
//      (旧実装は死んだ瞬間に 500ms かけて消え始めていた = ズームする対象が残らない)
//   2. 演出完了前は報酬モーダルが出ない
//      (`_sendFinish` は `status = won` で即発火する。API が 300ms で返れば
//       **演出の途中でモーダルが乗る**。ローカルの速い backend ほど再現しやすく、
//       本番で初めて直るように見える種類のバグ —— 指示書 Pre-mortem #1)
//
// `BattleSessionNotifier` を継承した fake で state を直接押し込み、
// orchestrator も Backend も通さずに「画面がどう反応するか」だけを見る。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/constants/preferences_keys.dart';
import 'package:sabiowl/features/battle/constants/battle_constants.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/pages/battle_page.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/widgets/combatant_sprite.dart';
import 'package:sabiowl/features/battle/widgets/ko_effect_overlay.dart';
import 'package:sabiowl/features/battle/widgets/ultimate_hit_effect_overlay.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// fake — Backend も orchestrator も通さない
// ─────────────────────────────────────────────────────────────────────────────

class _FakeSessionNotifier extends BattleSessionNotifier {
  _FakeSessionNotifier(super.ref);

  /// `startBattle` は Backend を叩くので潰す。state は push で外から与える。
  @override
  Future<void> startBattle({String? enemyKey, bool ambient = false}) async {}

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
      player: _player(),
      enemy: _enemy(hp: 60),
      tactic: Tactic.offense,
      status: BattleStatus.running,
      logLines: const ['戦闘開始'],
      startedAt: DateTime(2026, 8, 21),
    );

/// とどめが入った直後の state (KO 演出が走るべき状態)。
BattleState _wonWithKo() => BattleState(
      player: _player(),
      enemy: _enemy(hp: 0),
      tactic: Tactic.offense,
      status: BattleStatus.won,
      logLines: const ['戦闘開始', 'ゴブリンを倒した'],
      startedAt: DateTime(2026, 8, 21),
      endedAt: DateTime(2026, 8, 21, 0, 1),
      enemyAction: SpriteAction.recoil,
      playerAction: SpriteAction.slash,
      koEvent: KoEvent(damage: 24, isCritical: false),
    );


/// とどめが **必殺技** だった state (KO 演出と撃墜エフェクトが同時に来る)。
BattleState _wonWithKoByUltimate() => BattleState(
      player: _player(),
      enemy: _enemy(hp: 0),
      tactic: Tactic.offense,
      status: BattleStatus.won,
      logLines: const ['戦闘開始', '必殺で倒した'],
      startedAt: DateTime(2026, 8, 21),
      endedAt: DateTime(2026, 8, 21, 0, 1),
      enemyAction: SpriteAction.recoil,
      playerAction: SpriteAction.slash,
      koEvent: KoEvent(damage: 40, isCritical: true),
      ultimateHitEvent: UltimateHitEvent(damage: 40, isCritical: true),
    );

/// 必殺が当たったがまだ倒せていない state。
BattleState _runningWithUltimate() => BattleState(
      player: _player(),
      enemy: _enemy(hp: 20),
      tactic: Tactic.offense,
      status: BattleStatus.running,
      logLines: const ['戦闘開始', '必殺が当たった'],
      startedAt: DateTime(2026, 8, 21),
      ultimateHitEvent: UltimateHitEvent(damage: 40, isCritical: true),
    );

/// 撃墜エフェクトの**白フラッシュ**が画面に出ているか。
///
/// 白フラッシュは `Container(color: Colors.white.withValues(alpha: ...))` で、
/// KO 演出の暗転は黒、速度チップは `decoration` 経由なので `color` は null。
/// **画面上で白い Container はこれだけ**である。
bool _ultimateFlashVisible(WidgetTester tester) =>
    find.byKey(ultimateHitFlashKey).evaluate().isNotEmpty;

/// 敵 sprite に渡っている `SpriteAction`。
SpriteAction _enemySpriteAction(WidgetTester tester) {
  final sprites = tester.widgetList<CombatantSprite>(find.byType(CombatantSprite));
  // battle_page は 左 = 敵 / 右 = 味方 の順で組む (_buildBattleArena)
  return sprites.first.action;
}

/// `initState` が張る「戻るヒント」の 1.5 秒 Timer を流し切る。
///
/// 各テストの末尾で呼ぶこと。残したまま tree を捨てると
/// `A Timer is still pending even after the widget tree was disposed.` で落ちる
/// —— KO 演出とは無関係な既存の Timer だが、BattlePage を丸ごと描画する以上
/// 面倒を見る必要がある。
Future<void> _drainBackHintTimer(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
}

/// KO 演出が終わり切るまで進める。
///
/// ⚠️ **`pumpAndSettle` は使えない。** `CombatantSprite` の待機ユラユラ
/// (`idleSwayDuration` の `repeat()`) が永久に回っているのでいつまでも settle
/// せず、素直に書くと「pumpAndSettle timed out」で全滅する。
Future<void> _finishKoEffect(WidgetTester tester) async {
  await tester
      .pump(BattleConstants.koTotalDuration + const Duration(milliseconds: 80));
}

/// 「K.O.」ラベルが出ている頃まで進める。
Future<void> _pumpToKoLabel(WidgetTester tester) async {
  await tester.pump(BattleConstants.koHitStopDuration +
      BattleConstants.koZoomInDuration +
      const Duration(milliseconds: 80));
}

/// `showDialog` の postFrameCallback + ルート遷移を終わらせる。
Future<void> _settleDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// [initialSession] を渡すと **BattlePage を mount する前に** session を仕込める。
/// 「前のバトルの決着済み state が残ったままページに入る」経路の再現に使う。
Future<({ProviderContainer container, _FakeSessionNotifier notifier})> _pump(
  WidgetTester tester, {
  BattleSession? initialSession,
}) async {
  // ヒントを「表示済み」にしておく (本 FEAT の検証と関係ない吹き出しを出さない)
  SharedPreferences.setMockInitialValues({kPrefsBattleBackHintShown: true});
  late _FakeSessionNotifier notifier;
  final container = ProviderContainer(overrides: [
    battleSessionProvider.overrideWith((ref) {
      notifier = _FakeSessionNotifier(ref);
      return notifier;
    }),
  ]);
  addTearDown(container.dispose);

  // 縦に長い viewport にして、戦闘エリアと下半分の両方を build させる
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  container.read(battleSessionProvider.notifier); // notifier の生成を強制
  if (initialSession != null) notifier.push(initialSession);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: BattlePage(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('ja'),
    ),
  ));
  await tester.pump();
  return (container: container, notifier: notifier);
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト本体
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  testWidgets('KO 演出は戦闘エリアだけを wrap している (§4.3)', (tester) async {
    // 画面全体を wrap すると下半分のログ / 作戦パネルまで拡大されて崩れる。
    final h = await _pump(tester);
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();

    expect(find.byType(KoEffectOverlay), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(KoEffectOverlay),
        matching: find.byType(CombatantSprite),
      ),
      findsWidgets,
      reason: '対峙している 2 体は overlay の内側 = ズームの対象',
    );
    await _drainBackHintTimer(tester);
  });

  testWidgets('🔴 演出完了前は敵が fadeOut に入らない (§4.4)', (tester) async {
    final h = await _pump(tester);
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();

    // とどめが入る
    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();

    expect(_enemySpriteAction(tester), isNot(SpriteAction.fadeOut),
        reason: '演出中に消え始めるとズームする対象が残らない');
    expect(find.byType(KoLabel), findsNothing, reason: 'まだヒットストップ中');

    // 演出の途中 (ラベルが出ている頃)
    await _pumpToKoLabel(tester);
    expect(find.byType(KoLabel), findsOneWidget);
    expect(_enemySpriteAction(tester), isNot(SpriteAction.fadeOut),
        reason: '「K.O.」が出ている最中も敵は残っている');

    // 演出が終わる → ここで初めて消え始める
    await _finishKoEffect(tester);
    expect(_enemySpriteAction(tester), SpriteAction.fadeOut);
    await _drainBackHintTimer(tester);
  });

  testWidgets('🔴 演出完了前は報酬モーダルが出ない (Pre-mortem #1)',
      (tester) async {
    final h = await _pump(tester);
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();

    // とどめ → **ほぼ同時に** finish API が返ってきた最悪ケース。
    // API が速いほど壊れるので、テストでは「即完了」で再現する。
    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();
    h.notifier.push(BattleSession(
      state: _wonWithKo(),
      finishCompleted: true,
      rewardCoinsGained: 12,
      rewardExpGained: 34,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing,
        reason: '演出の途中でモーダルが乗ってはいけない');

    // 演出完了 → ゲートが開いてモーダルが出る。
    // 🔴 `ref.listen` は session が動いたときにしか走らないので、
    // **ゲートが開いた側からの再評価**が無いとここで永久に出ない。
    await _finishKoEffect(tester);
    await _settleDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '演出が終わったらモーダルが出る (出ないと画面が固まる)');
    await _drainBackHintTimer(tester);
  });

  testWidgets('敗北時は KO 演出を挟まず、従来どおり即モーダル', (tester) async {
    // 「決めた」と「やられた」は演出の意味が逆 (決定事項 3)。
    // `koEvent` が null なのでゲートは常に開いている。
    final h = await _pump(tester);
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();

    final lost = BattleState(
      player: _player()..currentHp = 0,
      enemy: _enemy(hp: 30),
      tactic: Tactic.offense,
      status: BattleStatus.lost,
      logLines: const ['やられてしまった'],
      startedAt: DateTime(2026, 8, 21),
    );
    h.notifier.push(BattleSession(state: lost, finishCompleted: true));
    await tester.pump();

    expect(find.byType(KoLabel), findsNothing, reason: '敗北で「K.O.」は出さない');
    await _settleDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '敗北モーダルは待たされない');
    await _drainBackHintTimer(tester);
  });

  testWidgets('🔴 連戦: 2 戦目もゲートが閉じ直される (Pre-mortem #6)',
      (tester) async {
    final h = await _pump(tester);

    // 1 戦目
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();
    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();
    await _finishKoEffect(tester);
    expect(_enemySpriteAction(tester), SpriteAction.fadeOut);

    // 2 戦目開始 (新しい orchestrator = 新しい BattleState)
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();
    expect(_enemySpriteAction(tester), isNot(SpriteAction.fadeOut));

    // 2 戦目のとどめ
    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();
    expect(_enemySpriteAction(tester), isNot(SpriteAction.fadeOut),
        reason: '前バトルのフラグが残っていると演出を待たずに消える');

    await _pumpToKoLabel(tester);
    expect(find.byType(KoLabel), findsOneWidget, reason: '2 戦目も演出が出る');

    await _finishKoEffect(tester);
    expect(_enemySpriteAction(tester), SpriteAction.fadeOut);
    await _drainBackHintTimer(tester);
  });

  testWidgets('koEvent の無い勝利では待たない (ゲートが開いたまま)',
      (tester) async {
    // アンビエント側で決着した state を後から見に来たケース。
    // ここで待つと **敵が永久に消えず、報酬モーダルも出ない**。
    final h = await _pump(tester);
    final wonWithoutKo = BattleState(
      player: _player(),
      enemy: _enemy(hp: 0),
      tactic: Tactic.offense,
      status: BattleStatus.won,
      logLines: const ['倒した'],
      startedAt: DateTime(2026, 8, 21),
    );
    h.notifier.push(BattleSession(state: wonWithoutKo, finishCompleted: true));
    await tester.pump();

    expect(_enemySpriteAction(tester), SpriteAction.fadeOut);
    await _settleDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await _drainBackHintTimer(tester);
  });

  testWidgets('演出中に離脱しても例外にならない (Pre-mortem #4)', (tester) async {
    final h = await _pump(tester);
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();
    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 戻るジェスチャ相当 = BattlePage ごと差し替える
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });


// ─────────────────────────────────────────────────────────────────────────────
// 【2026-08-22 実機報告】前のバトルの KO が次のバトルの頭で再生される
// ─────────────────────────────────────────────────────────────────────────────
//
// 症状: アンビエントモード (ホーム額縁) で勝利したあと、ギルドから手動で
// バトルを始めると、**アンビエント側の KO 演出が最初に流れてからバトルが始まる**。
//
// 原因: `battleSessionProvider` は autoDispose ではないので、**前のバトルの
// 決着済み state (`status = won` + `koEvent`) が残ったまま** BattlePage が
// mount される。そこへ initState の「mount 時点で既に決着していた state を
// 拾う経路」が働き、**前のバトルの KoEvent で演出を発火していた**。
//
// `startBattle()` は await されていないうえ、session state のリセットは
// API 往復の **後** なので、直後に読むと確実に古い state が返る。
//
// アンビエント固有ではない。通常のバトル → ギルド → 次のバトルでも同じ。

  testWidgets('🔴 前のバトルの KO は次のバトルの頭で再生されない', (tester) async {
    // アンビエントで勝ち終わった直後の session をそのまま持ってページに入る
    final h = await _pump(
      tester,
      initialSession: BattleSession(
        state: _wonWithKo(),
        finishCompleted: true,
        modalShown: true, // 額縁側でモーダルは出し終わっている
      ),
    );

    // initState の postFrameCallback が走るところまで進める
    await tester.pump();
    await _pumpToKoLabel(tester);

    expect(find.byType(KoLabel), findsNothing,
        reason: '前のバトルの KO をここで流してはいけない');

    // 新しいバトルが始まっても出ない
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();
    await _pumpToKoLabel(tester);
    expect(find.byType(KoLabel), findsNothing);

    // 新しいバトルのとどめでは、ちゃんと出る
    h.notifier.push(BattleSession(state: _wonWithKo()));
    await tester.pump();
    await _pumpToKoLabel(tester);
    expect(find.byType(KoLabel), findsOneWidget,
        reason: '今回のバトルの KO は出る');

    await _finishKoEffect(tester);
    await _drainBackHintTimer(tester);
  });

  testWidgets('🔴 前のバトルの koEvent でゲートが閉じたままにならない',
      (tester) async {
    // 発火しないことだけを直すと、今度は「koEvent があるのに演出が始まらない」
    // 状態になり、**ゲートが永久に閉じたまま**になる。そちらも同時に縛る。
    //
    // 🔵 mount 時点の古い session についてはモーダルを期待しない。
    //    決着済みバトルのモーダルは額縁側が `markModalShown()` で出す担当で、
    //    BattlePage が後から出す仕様は FEAT-526 以前から存在しない。
    final h = await _pump(
      tester,
      initialSession: BattleSession(
        state: _wonWithKo(),
        finishCompleted: true,
      ),
    );
    await tester.pump();

    expect(_enemySpriteAction(tester), SpriteAction.fadeOut,
        reason: '前のバトルの敵は待たされずに消えてよい (ゲートは開いている)');

    // 古い state を引きずったページでも、**今回のバトル**は最後まで通ること。
    h.notifier.push(BattleSession(state: _running()));
    await tester.pump();
    h.notifier.push(BattleSession(state: _wonWithKo(), finishCompleted: true));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing, reason: '演出中は出さない');

    await _finishKoEffect(tester);
    await _settleDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '演出後にちゃんと出る (前の state に汚染されていない)');
    await _drainBackHintTimer(tester);
  });

  // ── 【2026-08-22 実機報告】全画面だけ KO 演出が見えなかった ──────────────
  //
  // 🔴 とどめが必殺技だと、撃墜エフェクトの **白フラッシュ (alpha 0.6 / 350ms)**
  // が全画面に掛かる。KO 演出はその裏で ヒットストップ → ズーム → 「K.O.」と
  // 進むので **前半がまるごと白飛びする**。3 倍速では KO 演出 (約 230ms) が
  // フラッシュ (350ms、倍速に追従しない) に**完全に飲み込まれる**。
  //
  // 額縁に撃墜エフェクトが無いのが「額縁では見えるのに全画面では見えない」の
  // 正体だった。ハプティクス側は FEAT-526 で既に同じ判断 (とどめでは打たない)
  // をしており、**視覚に同じガードを掛け忘れていた**。
  group('🔴 とどめが必殺技のとき、撃墜エフェクトを重ねない', () {
    testWidgets('必殺がとどめ → 白フラッシュは出ない', (tester) async {
      final h = await _pump(tester);
      h.notifier.push(BattleSession(state: _running()));
      await tester.pump();

      h.notifier.push(BattleSession(state: _wonWithKoByUltimate()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(_ultimateFlashVisible(tester), isFalse,
          reason: '白フラッシュが KO 演出の前半を覆い隠す');

      await _finishKoEffect(tester);
      await _drainBackHintTimer(tester);
    });

    testWidgets('必殺がとどめでも「K.O.」はちゃんと出る', (tester) async {
      final h = await _pump(tester);
      h.notifier.push(BattleSession(state: _running()));
      await tester.pump();

      h.notifier.push(BattleSession(state: _wonWithKoByUltimate()));
      await tester.pump();
      await _pumpToKoLabel(tester);

      expect(find.byType(KoLabel), findsOneWidget);

      await _finishKoEffect(tester);
      await _drainBackHintTimer(tester);
    });

    testWidgets('必殺がとどめでなければ、従来どおり白フラッシュが出る',
        (tester) async {
      final h = await _pump(tester);
      h.notifier.push(BattleSession(state: _running()));
      await tester.pump();

      h.notifier.push(BattleSession(state: _runningWithUltimate()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(_ultimateFlashVisible(tester), isTrue,
          reason: 'とどめでない必殺の演出まで消してはいけない');

      await tester.pump(const Duration(milliseconds: 400));
      await _drainBackHintTimer(tester);
    });
  });

}
