// 【BUG-148 (2026-08-24)】敗北したオートバトルの回数消費テスト。
//
// ## 何を守るテストか
//
// 旧実装は **回数を減らすのが勝利したときだけ**だった。敗北すると
// `ambient_auto_battle_preset_{key}` が元の値のまま残るので、
// **負け続けるかぎり同じ敵がキューの先頭に残り続ける**。
//
// キューは tier 降順ソート (`_kTierOrder` の `hidden_boss: 4`) なので、
// 一度でも hidden_boss に回数を入れて負けると:
//
//   回数を設定 → 負ける → 回数そのまま
//     → 次にホームへ来る → その敵が先頭 → また戦う → また負ける → …
//
// ホームに来るたびに **一番強い相手にチャージを払って報酬ゼロで負ける**。
// ユーザーからは「設定していないのに勝手に始まった」としか見えない
// (2026-08-24 実機報告、相手は虚空の竜 = `void_dragon` / hidden_boss / Lv35)。
//
// 🔵 これは実装の逸脱ではなく **仕様の穴**だった。
// `FEAT-513_develop_handoff.md` の擬似コードも「敗北 → return、勝利 → 減らす」
// になっている。
//
// ## 縛る対象
//
//   A-1: 🔴 敗北でも preset が 1 減って永続化される（本体）
//   A-2: 🔴 敗北でもループは止まる（Q7 連敗防止を壊していない）
//   A-3: 🔴 回数 1 で敗北 → 0 になり、次回は走らない（報告の解消そのもの）
//   A-4: 勝利側の消費が二重になっていない（5 回設定 → 5 戦）
//   A-5: `defeatRemainingBattles` が state に載る
//   B-1: `requestSkipNextCountdown` が repo に残っていない
//
// **A-2 と A-4 が本体。** 「回数を消費する」を「ループを続けてよい」と読み違えると
// 負け続けてチャージを全部溶かすし、勝利側と共通化しすぎると
// 「5 回設定したのに 3 回で終わる」という静かな目減りになる。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/ambient_defeat_preset_test.dart
// ```

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/features/battle/dialogs/ambient_battle_defeat_dialog.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/enemy.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/ambient_auto_battle_orchestrator.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

const _presetKey = 'ambient_auto_battle_preset_goblin';

// ─────────────────────────────────────────────────────────────────────────────
// fixtures （`ambient_auto_battle_rewards_test.dart` と同じ流儀）
// ─────────────────────────────────────────────────────────────────────────────

EnemyMaster _enemy(String key) => EnemyMaster(
      key: key,
      name: key,
      spriteKey: key,
      baseHp: 100,
      baseAtk: 10,
      baseSpd: 5,
      levelScaling: 0.0,
      rewardCoins: 10,
      rewardExp: 20,
      tier: 'zako',
      unlockLevel: 0,
    );

BattleAvailability _avail({bool canBattle = true}) => BattleAvailability(
      charges: canBattle ? 3 : 0,
      canBattle: canBattle,
      label: '',
      description: '',
    );

Combatant _combatant(String name) => Combatant(
      id: name,
      name: name,
      spriteKey: name,
      maxHp: 100,
      currentHp: 100,
      atk: 10,
      spd: 10,
    );

BattleSession _session(BattleStatus status) => BattleSession(
      state: BattleState(
        player: _combatant('player'),
        enemy: _combatant('goblin'),
        tactic: Tactic.offense,
        status: status,
        logLines: const [],
      ),
      token: 'tok',
      finishCompleted: true,
      rewardCoinsGained: status == BattleStatus.won ? 10 : 0,
      rewardExpGained: status == BattleStatus.won ? 20 : 0,
    );

BattleSession _win() => _session(BattleStatus.won);
BattleSession _lose() => _session(BattleStatus.lost);

/// 実物の [BattleSessionNotifier] を継承し、HTTP を張らずに結果を返す。
///
/// **state 変更は非同期に流す。** orchestrator は `await startBattle()` の **後**に
/// `_awaitBattleCompletion()` で listener を張るので、同期的に state を変えると
/// 変化を取りこぼして 3 分 timeout に落ちる。
class _FakeBattleSession extends BattleSessionNotifier {
  _FakeBattleSession(super.ref, {required this.results});

  final List<BattleSession> results;
  int startCount = 0;

  @override
  Future<void> startBattle({String? enemyKey, bool ambient = false}) async {
    final result = results[startCount.clamp(0, results.length - 1)];
    startCount++;
    state = const BattleSession();
    Future.delayed(const Duration(milliseconds: 10), () {
      state = result;
    });
  }
}

void _setPrefs({required int presetCount}) {
  SharedPreferences.setMockInitialValues({
    'ambient_auto_battle_enabled': true,
    _presetKey: presetCount,
  });
}

ProviderContainer _container(_FakeBattleSession Function(Ref) fake) {
  return ProviderContainer(overrides: [
    battleAvailabilityProvider.overrideWithValue(_avail()),
    enemyListProvider(null).overrideWith((_) async => [_enemy('goblin')]),
    ambientAutoBattleCountdownSecondsProvider.overrideWithValue(0),
    battleSessionProvider.overrideWith(fake),
  ]);
}

Future<void> _run(ProviderContainer container) async {
  final sub = container.listen(enemyListProvider(null), (_, __) {});
  addTearDown(sub.close);
  await container.read(enemyListProvider(null).future);
  await container
      .read(ambientAutoBattleProvider.notifier)
      .maybeStartAutoBattle();
}

Future<int?> _savedPreset() async =>
    (await SharedPreferences.getInstance()).getInt(_presetKey);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  group('【BUG-148】A: 敗北でも回数を消費する', () {
    test('🔴 A-1: 敗北すると preset が 1 減って永続化される', () async {
      _setPrefs(presetCount: 3);
      final container = _container((ref) => _FakeBattleSession(ref, results: [
            _lose(),
          ]));
      addTearDown(container.dispose);

      await _run(container);

      expect(
        await _savedPreset(),
        2,
        reason: '🔴 減らさないと、負け続けるかぎり同じ敵が永久にキューの先頭に残り、'
            'ホームに来るたびに報酬ゼロで負ける (2026-08-24 実機報告)。'
            'ギルド画面のラベルは「残り回数」なので、戦った以上 1 消費するのが正しい',
      );
    });

    test('🔴 A-2: 敗北でもループは止まる (Q7 連敗防止)', () async {
      _setPrefs(presetCount: 3);
      final container = _container((ref) => _FakeBattleSession(ref, results: [
            _lose(),
          ]));
      addTearDown(container.dispose);

      await _run(container);

      final notifier =
          container.read(battleSessionProvider.notifier) as _FakeBattleSession;
      expect(
        notifier.startCount,
        1,
        reason: '🔴 「回数を消費する」を「ループを続けてよい」と読み違えると、'
            '負け続けてチャージを全部溶かす。FEAT-513 S2 が構造的に防いだものを'
            'こちらから壊すことになる。preset 3 でも敗北で 1 戦だけ',
      );
      expect(container.read(ambientAutoBattleProvider).defeatEnemyName,
          isNotNull,
          reason: '敗北 dialog のシグナルは立つ');
    });

    test('🔴 A-3: 回数 1 で敗北 → 0 になり、次回は走らない', () async {
      // ユーザー報告の解消そのもの。0 になれば空 preset 経路に入って
      // バトルは始まらない。
      _setPrefs(presetCount: 1);
      final container = _container((ref) => _FakeBattleSession(ref, results: [
            _lose(),
          ]));
      addTearDown(container.dispose);

      await _run(container);
      expect(await _savedPreset(), 0);

      // 2 回目の呼び出し（= 次にホームへ来た）でバトルが増えないこと。
      final notifier =
          container.read(battleSessionProvider.notifier) as _FakeBattleSession;
      final before = notifier.startCount;
      await container
          .read(ambientAutoBattleProvider.notifier)
          .maybeStartAutoBattle();

      expect(
        notifier.startCount,
        before,
        reason: '🔴 これが「設定していないのに勝手に始まった」の解消。'
            '0 になったら二度と走らない',
      );
    });

    test('A-4: 勝利側の消費が二重になっていない (5 回設定 → 5 戦)', () async {
      // 敗北側に消費を足すとき勝利側と共通化しすぎると、両方で減って
      // 「5 回設定したのに 3 回で終わる」になる。静かな目減りなので、
      // ユーザーは設定した記憶のほうを疑う。
      _setPrefs(presetCount: 5);
      final container = _container((ref) => _FakeBattleSession(ref, results: [
            _win(),
          ]));
      addTearDown(container.dispose);

      await _run(container);

      final notifier =
          container.read(battleSessionProvider.notifier) as _FakeBattleSession;
      expect(notifier.startCount, 5, reason: '5 回設定なら 5 戦');
      expect(await _savedPreset(), 0, reason: '撃ち切って 0');
    });

    test('A-5: defeatRemainingBattles が state に載る', () async {
      _setPrefs(presetCount: 3);
      final container = _container((ref) => _FakeBattleSession(ref, results: [
            _lose(),
          ]));
      addTearDown(container.dispose);

      await _run(container);

      final state = container.read(ambientAutoBattleProvider);
      expect(
        state.defeatRemainingBattles,
        2,
        reason: '🔴 queue 全体の `remainingBattles` ではなく **この敵の** 残数。'
            '名前が似ているので取り違えやすい',
      );
    });

    test('A-5b: 撃ち切ったら defeatRemainingBattles は 0', () async {
      _setPrefs(presetCount: 1);
      final container = _container((ref) => _FakeBattleSession(ref, results: [
            _lose(),
          ]));
      addTearDown(container.dispose);

      await _run(container);

      expect(container.read(ambientAutoBattleProvider).defeatRemainingBattles, 0,
          reason: 'dialog が「予定していた出陣は終わりです」に切り替わる条件');
    });
  });

  group('【BUG-148】C: ダイアログはボタン 1 つ', () {
    Future<void> pumpDialog(WidgetTester tester, int remaining) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
        home: Scaffold(
          body: AmbientBattleDefeatDialog(
            enemyName: '虚空の竜',
            remainingBattles: remaining,
            onClose: () {},
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('🔴 C-1: ボタンは「閉じる」1 つだけ', (tester) async {
      await pumpDialog(tester, 2);

      final l10n = await AppLocalizations.delegate.load(const Locale('ja'));
      expect(find.text(l10n.battleAmbientDefeatCloseButton), findsOneWidget);
      expect(
        find.byType(ElevatedButton),
        findsOneWidget,
        reason: '🔴 「休む」は押しても休めない (回数が残っていれば次にホームへ来た'
            '時点で再開する)。「続ける」は同じ敵に戻ってまた負けるだけだった。'
            'どちらもユーザーには区別が付かない',
      );
      expect(find.byType(TextButton), findsNothing,
          reason: '旧「休む」(TextButton) が残っていない');
    });

    testWidgets('🔴 C-2: 残り回数で本文の行が変わる', (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ja'));

      await pumpDialog(tester, 2);
      expect(
        find.text(l10n.battleAmbientDefeatEnemyLabel('虚空の竜', 2)),
        findsOneWidget,
        reason: 'ボタンが 1 つになったぶん、閉じた後どうなるかを本文で示す',
      );
      expect(find.text(l10n.battleAmbientDefeatQueueDoneLabel('虚空の竜')),
          findsNothing);

      await pumpDialog(tester, 0);
      expect(find.text(l10n.battleAmbientDefeatQueueDoneLabel('虚空の竜')),
          findsOneWidget,
          reason: '0 なら「予定していた出陣は終わりです」に切り替わる');
    });

    testWidgets('C-3: 「閉じる」を押すと onClose が呼ばれる', (tester) async {
      var closed = 0;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
        home: Scaffold(
          body: AmbientBattleDefeatDialog(
            enemyName: '虚空の竜',
            remainingBattles: 0,
            onClose: () => closed++,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(closed, 1);
    });
  });

  group('【BUG-148】B: 撤去したものが残っていない', () {
    test('B-1: requestSkipNextCountdown が repo に残っていない', () {
      // 「続ける」ボタンからしか呼ばれていなかったので dead code になる。
      // 残すと次に読む人が「どこから呼ばれるのか」を探して時間を溶かす。
      // 🔵 走査対象は `lib/` だけにする。本ファイル自身が判定用の文字列を
      // 持っているので `test/` を含めると **自分にヒットする**（実際に一度
      // 落とした）。テスト側から参照が残っていればコンパイルが通らないので、
      // lib だけ見れば目的は果たせる。
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final rel = e.path.split(Platform.pathSeparator).join('/');
        if (rel.startsWith('lib/l10n/app_localizations')) continue;
        // 撤去の経緯を説明するコメント（``付き）は許し、**実コード**だけ見る。
        final src = e
            .readAsStringSync()
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        if (src.contains('requestSkipNextCountdown')) offenders.add(rel);
      }
      expect(offenders, isEmpty,
          reason: '呼ばれない分岐が残っている: ${offenders.join(', ')}');
    });
  });
}

