// 【FEAT-527 (2026-08-22)】攻撃フレーム再生の契約テスト。
//
// ## 何を守っているか
//
// 素材は 1 体ずつ増える。**全キャラが揃うまで必ず混在する**ので、
// 「フレームを持たないキャラが 1 行も変わらない」ことが本機能の前提条件になる。
// 壊れると、素材が無いキャラだけ画像が消える / 例外が出る、という形で表面化する。
//
// もう 1 つは **命中フレームの位置**。`BattleOrchestrator` は t=200ms で
// `slash` (斬撃線) を出すので、3 枚目がそこに重ならないと
// 「斬撃線が出たのに手はまだ振りかぶっている」というズレた絵になる。
// これは実機を見ても「なんとなく変」としか分からず、原因を追いにくい。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/constants/battle_sprite_motion.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/widgets/combatant_sprite.dart';
import 'package:sabiowl/features/battle/widgets/mini_battle_arena.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// widget tree から `Image.asset` のパスを全部拾う。
List<String> _assetPaths(WidgetTester tester) {
  return tester
      .widgetList<Image>(find.byType(Image))
      .map((w) => w.image)
      .whereType<AssetImage>()
      .map((a) => a.assetName)
      .toList();
}

Future<void> _pumpSprite(
  WidgetTester tester, {
  required String spriteKey,
  required SpriteAction action,
  required bool enableMotion,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CombatantSprite(
        spriteKey: spriteKey,
        action: action,
        enableMotion: enableMotion,
      ),
    ),
  ));
}

void main() {
  group('FEAT-527 BattleSpriteMotion — 定義', () {
    test('命中フレームは 3 枚目 (index 2) で、t=200ms の slash と重なる', () {
      // BattleOrchestrator._triggerAttackEffect のフェーズ 2 が 200ms。
      final impactAt = BattleSpriteMotion.frameStep *
          BattleSpriteMotion.impactFrameIndex;
      expect(impactAt, const Duration(milliseconds: 200),
          reason: '命中フレームが斬撃線とズレると、振りかぶったまま斬撃線だけ出る');
    });

    test('総再生時間は idle 復帰 (500ms) より短い', () {
      // 500ms で BattleOrchestrator が idle に戻すので、それを超えると
      // 立ち絵に戻った後もフレームが動き続ける。
      expect(BattleSpriteMotion.totalDuration.inMilliseconds, lessThan(500));
    });

    test('進捗 1.0 は最終フレームに丸まる (範囲外にしない)', () {
      expect(BattleSpriteMotion.frameIndexFor(0.0), 0);
      expect(BattleSpriteMotion.frameIndexFor(0.49), 1);
      expect(BattleSpriteMotion.frameIndexFor(0.51), 2);
      expect(BattleSpriteMotion.frameIndexFor(1.0),
          BattleSpriteMotion.frameCount - 1,
          reason: '終端で index が frameCount になると存在しないファイルを引く');
    });

    test('登録済みキャラは攻撃フレームを持ち、未対応キャラは持たない', () {
      expect(BattleSpriteMotion.has('aria'), isTrue);
      expect(BattleSpriteMotion.has('sol'), isTrue);
      expect(BattleSpriteMotion.has('lucia'), isTrue);
      expect(BattleSpriteMotion.has('faye'), isTrue);
      expect(BattleSpriteMotion.has('rune'), isTrue);
      expect(BattleSpriteMotion.has('beatrix'), isTrue);
      expect(BattleSpriteMotion.has('zenon'), isFalse);
      expect(BattleSpriteMotion.has('enemy_goblin'), isFalse);
    });
  });

  group('FEAT-527 フォールバック — 素材が無いキャラは 1 行も変わらない', () {
    testWidgets('enableMotion: true でも未対応キャラは従来の <key>.webp を描く',
        (tester) async {
      await _pumpSprite(tester,
          spriteKey: 'zenon', action: SpriteAction.idle, enableMotion: true);
      expect(_assetPaths(tester), contains('assets/images/battle/zenon.webp'));
    });

    testWidgets('未対応キャラは攻撃中も <key>.webp のまま', (tester) async {
      await _pumpSprite(tester,
          spriteKey: 'zenon', action: SpriteAction.charge, enableMotion: true);
      await tester.pump(const Duration(milliseconds: 250));
      expect(_assetPaths(tester), contains('assets/images/battle/zenon.webp'));
    });

    testWidgets('enableMotion: false なら対応キャラでも従来の絵のまま',
        (tester) async {
      await _pumpSprite(tester,
          spriteKey: 'aria', action: SpriteAction.charge, enableMotion: false);
      await tester.pump(const Duration(milliseconds: 250));
      expect(_assetPaths(tester), contains('assets/images/battle/aria.webp'),
          reason: '既定 false のまま挙動が変わると、有効化していない画面に波及する');
    });
  });

  group('FEAT-527 再生 — 対応キャラ', () {
    testWidgets('待機は専用の立ち絵を使う (既存 <key>.webp ではない)',
        (tester) async {
      await _pumpSprite(tester,
          spriteKey: 'aria', action: SpriteAction.idle, enableMotion: true);
      final paths = _assetPaths(tester);
      expect(paths, contains(BattleSpriteMotion.idlePath('aria')));
      expect(paths, isNot(contains('assets/images/battle/aria.webp')),
          reason: '攻撃フレームと絵柄が違う立ち絵を混ぜると、攻撃のたびに別人になる');
    });

    testWidgets('攻撃するとフレームが 1→4 へ進む', (tester) async {
      await _pumpSprite(tester,
          spriteKey: 'aria', action: SpriteAction.charge, enableMotion: true);

      // 細かく刻んでサンプリングし、連続する重複を畳んでから順序を見る。
      // `pump(frameStep)` でちょうど 4 回サンプルすると、AnimationController の
      // 開始 tick が 1 フレーム遅れる分だけ位相がずれて最終フレームに届かない。
      // **確認したいのは「1→4 の順に、抜けなく進むこと」**なので、
      // 位相に依存しない形で測る。
      final seen = <String>[];
      for (var t = 0; t <= 460; t += 20) {
        final path = _assetPaths(tester)
            .firstWhere((p) => p.contains('aria_attack_'));
        if (seen.isEmpty || seen.last != path) seen.add(path);
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(seen, [
        for (var i = 0; i < BattleSpriteMotion.frameCount; i++)
          BattleSpriteMotion.framePath('aria', i),
      ], reason: 'フレームが飛ぶ / 戻る / 最終フレームに届かないと動きが破綻する');
    });

    testWidgets('被弾 (recoil) では攻撃フレームを出さない', (tester) async {
      await _pumpSprite(tester,
          spriteKey: 'aria', action: SpriteAction.recoil, enableMotion: true);
      await tester.pump(const Duration(milliseconds: 150));
      expect(_assetPaths(tester).where((p) => p.contains('aria_attack_')),
          isEmpty,
          reason: '攻撃フレームは自分が斬るときだけ。被弾で出ると意味が反転する');
    });

    testWidgets('KO 相当 (slash のまま止まる) では最終フレームで静止する',
        (tester) async {
      // FEAT-526 §4.5: KO のとき BattleOrchestrator は idle 復帰 Timer を畳むので
      // action は slash のまま残る。そこで最終フレームが出続けるのが正しい。
      await _pumpSprite(tester,
          spriteKey: 'aria', action: SpriteAction.charge, enableMotion: true);
      await tester.pump(BattleSpriteMotion.totalDuration);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CombatantSprite(
            spriteKey: 'aria',
            action: SpriteAction.slash,
            enableMotion: true,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _assetPaths(tester),
        contains(BattleSpriteMotion.framePath(
            'aria', BattleSpriteMotion.frameCount - 1)),
        reason: '止まった瞬間に立ち絵へ戻ると「斬った姿勢のまま静止」が崩れる',
      );
    });

    testWidgets('攻撃が終わって idle に戻ると立ち絵へ復帰する', (tester) async {
      await _pumpSprite(tester,
          spriteKey: 'aria', action: SpriteAction.charge, enableMotion: true);
      await tester.pump(BattleSpriteMotion.totalDuration);
      await _pumpSprite(tester,
          spriteKey: 'aria', action: SpriteAction.idle, enableMotion: true);
      await tester.pump();
      expect(_assetPaths(tester), contains(BattleSpriteMotion.idlePath('aria')));
    });
  });

  group('FEAT-527 アセットの実在', () {
    test('宣言したキャラのファイルがすべて存在する', () async {
      // pubspec は assets/images/battle/ をディレクトリ登録しているので
      // ファイルを置けば bundle される。**置き忘れると errorBuilder の
      // 灰色プレースホルダが黙って出る** (FEAT-428 と同じ壊れ方)。
      for (final key in ['aria', 'sol', 'lucia', 'faye', 'rune', 'beatrix']) {
        final paths = <String>[
          BattleSpriteMotion.idlePath(key),
          for (var i = 0; i < BattleSpriteMotion.frameCount; i++)
            BattleSpriteMotion.framePath(key, i),
        ];
        for (final path in paths) {
          expect(await _exists(path), isTrue, reason: '$path が見つからない');
        }
      }
    });
  });
  // ── 【FEAT-527 (2026-08-22 訂正)】額縁 (アンビエント) でもフレームが出る ──
  //
  // 当初は Pre-mortem #4 (バッテリー) を理由に額縁を `enableMotion: false` の
  // ままにしていたが、**前提が誤っていた**。`CombatantSprite` は
  // `_idleCtrl.repeat()` で常時ティックしており、「額縁は再描画が増えない」
  // という理屈が成立しない。ユーザーが実機で「額縁だけ動かない」と検出した。
  //
  // 全画面と額縁は**別ファイル**なので、片方だけ直しても気付けない。ここで縛る。
  group('FEAT-527 額縁 (MiniBattleArena) でも攻撃フレームが出る', () {
    testWidgets('額縁で味方が攻撃するとフレームが差し替わる', (tester) async {
      await _pumpArena(tester, spriteKey: 'lucia', action: SpriteAction.charge);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        _assetPaths(tester).where((p) => p.contains('lucia_attack_')),
        isNotEmpty,
        reason: '全画面だけ直して額縁を忘れると、ホームでは静止画のままになる',
      );
    });

    testWidgets('額縁の待機も専用の立ち絵を使う', (tester) async {
      await _pumpArena(tester, spriteKey: 'lucia', action: SpriteAction.idle);
      final paths = _assetPaths(tester);
      expect(paths, contains(BattleSpriteMotion.idlePath('lucia')));
      expect(paths, isNot(contains('assets/images/battle/lucia.webp')));
    });

    testWidgets('額縁でも未対応キャラは従来どおり', (tester) async {
      await _pumpArena(tester, spriteKey: 'zenon', action: SpriteAction.charge);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_assetPaths(tester),
          contains('assets/images/battle/zenon.webp'));
    });
  });
}

class _FakeSessionNotifier extends BattleSessionNotifier {
  _FakeSessionNotifier(super.ref);
  void push(BattleSession session) => state = session;
}

/// 額縁 (`MiniBattleArena`) を実寸に近い箱で立ち上げる。
///
/// ⚠️ `pumpAndSettle` は使えない (`CombatantSprite` の待機ユラユラが永久ループ)。
Future<void> _pumpArena(
  WidgetTester tester, {
  required String spriteKey,
  required SpriteAction action,
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
  notifier.push(BattleSession(
    state: BattleState(
      player: Combatant(
        id: 'player', name: '勇者', spriteKey: spriteKey,
        maxHp: 100, currentHp: 100, atk: 10, spd: 10,
      ),
      enemy: Combatant(
        id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
        maxHp: 60, currentHp: 60, atk: 5, spd: 10,
      ),
      tactic: Tactic.offense,
      status: BattleStatus.running,
      logLines: const ['戦闘開始'],
      startedAt: DateTime(2026, 8, 22),
      playerAction: action,
    ),
  ));

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('ja'),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 344, height: 240, child: MiniBattleArena()),
        ),
      ),
    ),
  ));
  await tester.pump();
}


Future<bool> _exists(String assetPath) async {
  // test の cwd は mobile/ なので assets/... がそのまま実ファイルパスになる。
  return await File(assetPath).exists();
}
