// 【FEAT-530 (2026-08-29)】バトル終了後の再取得を「ホームが生きているか」で分岐する契約。
//
// ## 何を守るテストか
//
// `_sendFinish` の末尾は、長いあいだ **同じ内容を 2 回取りに行っていた**:
//
//   await playerNotifierProvider.notifier.refresh();   // ① GET /api/player/  (15 クエリ)
//   invalidate(homeBootstrapRawProvider);              // ② GET /api/home/    (30 クエリ)
//
// ② は `PlayerProfileSerializer` を丸ごと含んでいて、`setFromBootstrap` で
// `playerNotifierProvider` に流し込まれる。つまり **② が返った時点で ① の結果は
// 上書きされる**。
//
// 🔵 **ただし「① は常に無駄」ではない。** ここを取り違えると壊れる。
// ホームが watch していないとき ② は「再取得は走るが player には伝わらない」
// —— `homeBootstrapControllerProvider` が誰にも listen されておらず再評価されない
// ためで、この文脈では ① が仕事をしている。バグではなく、**2 つの文脈に対する
// 2 つの正解を、分岐させずに和集合で足した**形だった。
//
// ## 🔴 このテストの主目的は、クエリ削減ではなく「3 度目を止めること」
//
// この経路には `refresh()` が **すでに 2 回足されている**:
//
//   - FEAT-295 hotfix (2026-05-25) … 成功パス
//   - 2026-07-05 追記             … catch 側 (ギルド「本日のクエスト」の陳腐化)
//
// どちらも「反映されない」という症状を見て**足す**方向で解決された。
// A-1 が無いと、次に同じ症状を見た人がまた足して元に戻る。だから
// **「余分な取得をしていないこと」と「値が新しいこと」を同時に縛る**。
// 片方 (クエリ数) だけを見るテストは、反映漏れをそのまま通す。
//
// | # | 内容 |
// |---|---|
// | A-1 | 🔴 ホーム滞在中にバトルが終わっても `GET /api/player/` が発行されない |
// | A-2 | 🔴 ホームが居ないとき (全画面バトル) は `refresh()` が走る |
// | A-3 | **どちらの経路でも** player の値が新しくなる (節約が反映漏れになっていない) |
// | A-4 | 失敗パス (finish が throw) でも同じ分岐 —— 2 箇所の直し忘れが無い |
// | B-1 | `refresh()` の呼び出しはファイル内で 1 箇所だけ (構造的に 3 度目を止める) |
// | B-2 | 判定に使う provider の `exists` がホーム離脱に追従する |
// | B-3 | 🔴 `homeBootstrapRawProvider` の `exists` は追従しない (不採用の記録) |
// | C-1 | 連戦の途中でホームを離れたら、次の 1 戦から `refresh()` が復活する |
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/battle_finish_refresh_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/cache/cache_service.dart';
import 'package:sabiowl/features/battle/models/job.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/battle_service.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/features/habits/providers/home_bootstrap_provider.dart';
import 'package:sabiowl/features/habits/services/habits_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// fakes
// ─────────────────────────────────────────────────────────────────────────────

/// `GET /api/player/` と `GET /api/home/` の**発行回数**を数える [HabitsService]。
///
/// 本 FEAT が見たいのは「どちらの往復が走ったか」なので、Dio ではなく
/// service 境界で数える。`serverExp` を書き換えれば「サーバー側の値が新しく
/// なった」状況を作れる (A-3 用)。
class _CountingHabitsService implements HabitsService {
  int playerFetches = 0;
  int bootstrapFetches = 0;

  /// サーバーが返す最新の EXP。バトル報酬が入った状態を作るために書き換える。
  int serverExp = 100;

  Map<String, dynamic> _playerJson() => {
        'id': 1,
        'name': 'テストプレイヤー',
        'gender': 'f',
        'level': 3,
        'current_exp': serverExp,
        'max_exp': 240,
        'allocatable_points': 0,
        'diamonds': 0,
        'diamonds_total': 0,
        'friend_id': '12345678',
        'daily_tickets': 0,
        'weekly_tickets': 0,
        'monthly_tickets': 0,
        'reminder_enabled': false,
        'mode': 'training',
      };

  @override
  Future<Player> fetchPlayer() async {
    playerFetches++;
    return Player.fromJson(_playerJson());
  }

  @override
  Future<Map<String, dynamic>> fetchHomeBootstrap({String? timeSegment}) async {
    bootstrapFetches++;
    return {
      'player': _playerJson(),
      'habits': <dynamic>[],
      'has_more_habits': false,
      'unread_notif_count': 0,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'test unexpectedly touched: ${invocation.memberName}',
      );
}

/// 1 撃で決着する戦闘を返す [BattleService]。
///
/// `finishFails` を立てると `finishBattle` が throw し、`_sendFinish` の
/// **catch 経路**を通せる (A-4)。
class _StubBattleService implements BattleService {
  _StubBattleService({this.finishFails = false});

  final bool finishFails;
  int finishCalls = 0;

  @override
  Future<BattleStartResponse> startBattle({
    String? enemyKey,
    int potionsToUse = 0,
    int potionsPlusToUse = 0,
    int attackPotionsToUse = 0,
    int defensePotionsToUse = 0,
  }) async {
    return BattleStartResponse(
      token: 'test-token',
      enemyKey: enemyKey ?? 'goblin',
      enemyName: 'ゴブリン',
      enemySpriteKey: 'goblin',
      // HP 1 / SPD 1 = プレイヤーの初撃で必ず決着する (テストを短く保つ)。
      enemyHp: 1,
      enemyAtk: 1,
      enemySpd: 1,
      playerJob: Job.fallback,
    );
  }

  @override
  Future<BattleFinishResponse> finishBattle({
    required String token,
    required String result,
    required int durationSec,
    required int damageDealt,
    required int damageTaken,
    required int rounds,
    required String summaryText,
    int potionsUsed = 0,
    int potionsPlusUsed = 0,
    int attackPotionsUsed = 0,
    int defensePotionsUsed = 0,
  }) async {
    finishCalls++;
    if (finishFails) {
      throw Exception('simulated damage_unreasonable reject');
    }
    return const BattleFinishResponse(
      coinsGained: 15,
      expGained: 400,
      leveledUp: false,
      newCoins: 115,
      newExp: 500,
      battleCharges: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'test unexpectedly touched: ${invocation.memberName}',
      );
}

class _StubStatsNotifier extends StatsNotifier {
  @override
  Future<List<CharacterStat>> build() async => const [];
}

// ─────────────────────────────────────────────────────────────────────────────
// harness
// ─────────────────────────────────────────────────────────────────────────────

/// 1 戦分の観測結果。
class _Observed {
  const _Observed({
    required this.playerFetches,
    required this.bootstrapFetches,
    required this.exp,
  });

  /// 戦闘終了後に増えた `GET /api/player/` の本数 (= ①)。
  final int playerFetches;

  /// 戦闘終了後に増えた `GET /api/home/` の本数 (= ②)。
  final int bootstrapFetches;

  /// 戦闘終了後に `playerNotifierProvider` が保持している EXP。
  final int? exp;
}

/// ホーム / 全画面いずれかの文脈を組み立てて 1 戦走らせるテストハーネス。
class _Harness {
  _Harness._(this.container, this.habits, this.battle);

  final ProviderContainer container;
  final _CountingHabitsService habits;
  final _StubBattleService battle;

  ProviderSubscription<void>? _homeLive;
  ProviderSubscription<void>? _homeController;

  static Future<_Harness> create({bool finishFails = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final habits = _CountingHabitsService();
    final battle = _StubBattleService(finishFails: finishFails);
    final container = ProviderContainer(overrides: [
      habitsServiceProvider.overrideWithValue(habits),
      battleServiceProvider.overrideWithValue(battle),
      cacheServiceProvider.overrideWithValue(CacheService(prefs)),
      statsNotifierProvider.overrideWith(_StubStatsNotifier.new),
    ]);
    addTearDown(container.dispose);
    final h = _Harness._(container, habits, battle);

    // player は全画面バトル中もギルド / バトル画面が watch している。
    // ここで listen しないと autoDispose で毎 read 再生成され、回数が測れない。
    container.listen(playerNotifierProvider, (_, __) {});
    await h._settle();
    return h;
  }

  /// HomePage が mount した状態にする (額縁バトルの文脈)。
  Future<void> enterHome() async {
    _homeLive = container.listen(homeIsLiveProvider, (_, __) {});
    _homeController =
        container.listen(homeBootstrapControllerProvider, (_, __) {});
    await _settle();
  }

  /// HomePage が unmount した状態にする (タブ移動 / 全画面バトルの文脈)。
  Future<void> leaveHome() async {
    _homeLive?.close();
    _homeController?.close();
    _homeLive = null;
    _homeController = null;
    await _settle();
  }

  Future<void> _settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  /// 1 戦走らせ、**戦闘終了時に増えた**往復数と、終了後の player 値を返す。
  Future<_Observed> runOneBattle() async {
    final playersBefore = habits.playerFetches;
    final bootstrapsBefore = habits.bootstrapFetches;
    final finishesBefore = battle.finishCalls;

    final notifier = container.read(battleSessionProvider.notifier);
    await notifier.startBattle(enemyKey: 'goblin');

    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (container.read(battleSessionProvider).finishCompleted != true) {
      if (DateTime.now().isAfter(deadline)) {
        fail('戦闘が終わらない (テスト設定の問題): '
            'status=${container.read(battleSessionProvider).state?.status}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(battle.finishCalls, finishesBefore + 1,
        reason: 'finishBattle が 1 回だけ呼ばれている');

    // `_sendFinish` は fire-and-forget で呼ばれるので、再取得が落ち着くまで待つ。
    await _settle();
    await _settle();

    return _Observed(
      playerFetches: habits.playerFetches - playersBefore,
      bootstrapFetches: habits.bootstrapFetches - bootstrapsBefore,
      exp: container.read(playerNotifierProvider).valueOrNull?.currentExp,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FEAT-530 A: バトル終了後の再取得は文脈で分岐する', () {
    test(
      'A-1 🔴 ホーム滞在中にバトルが終わっても GET /api/player/ は発行されない '
      '(A-3: それでも player の値は新しくなる)',
      () async {
        final h = await _Harness.create();
        await h.enterHome();
        // サーバー側にバトル報酬が入った状態にする。
        h.habits.serverExp = 500;

        final observed = await h.runOneBattle();

        expect(observed.playerFetches, 0,
            reason: '🔴 ホームが生きているなら ① は丸ごと余る '
                '(② の PlayerProfileSerializer が同じものを返すため)');
        expect(observed.bootstrapFetches, 1, reason: '② は 1 本だけ走る');
        // A-3: 節約が反映漏れになっていないこと。**ここが無いテストは何も守れない。**
        expect(observed.exp, 500,
            reason: '🔴 ① を止めても player の値は新しくなる '
                '(bootstrap の player が setFromBootstrap で入る)');
      },
    );

    test(
      'A-2 🔴 ホームが居ないとき (全画面バトル) は refresh() が走る (A-3: 値も新しくなる)',
      () async {
        final h = await _Harness.create();
        // enterHome しない = HomePage が mount していない文脈。
        h.habits.serverExp = 500;

        final observed = await h.runOneBattle();

        expect(observed.playerFetches, 1,
            reason: '🔴 ホームが居なければ ② は player に伝わらない。'
                'ここで ① を止めると FEAT-295 が塞いだ「盾バッジが古いまま」が再発する');
        expect(observed.exp, 500, reason: 'refresh() 経由で新しい値になっている');
      },
    );

    test(
      'A-4 失敗パス (finishBattle が throw) でも同じ分岐 —— 2 箇所の直し忘れが無い',
      () async {
        // 成功パスだけ直して catch 側を取りこぼす、が起きていないことを
        // **両方の文脈で**確かめる (FEAT-530 §2.1 / Pre-mortem #2)。
        final live = await _Harness.create(finishFails: true);
        await live.enterHome();
        live.habits.serverExp = 500;
        final onHome = await live.runOneBattle();

        expect(onHome.playerFetches, 0,
            reason: '🔴 catch 経路もホーム滞在中は ① を出さない '
                '(直し忘れていたらここが 1 になる)');
        expect(onHome.bootstrapFetches, 1);
        expect(onHome.exp, 500,
            reason: 'finish が失敗しても、ギルドが見る player は新しくなる '
                '(2026-07-05 追記が守りたかったもの)');

        final away = await _Harness.create(finishFails: true);
        away.habits.serverExp = 500;
        final offHome = await away.runOneBattle();

        expect(offHome.playerFetches, 1,
            reason: 'catch 経路もホーム不在なら ① が仕事をする');
        expect(offHome.exp, 500);
      },
    );
  });

  group('FEAT-530 B: 3 度目の refresh() を構造的に止める', () {
    test(
      'B-1 🔴 playerNotifierProvider.refresh() の呼び出しは _refreshAfterFinish 1 箇所だけ',
      () {
        // 行番号は**元ファイルのもの**を保つ (報告先が実際に開ける番号であること)。
        // コメント行は除外する —— このメソッドの doc コメントが自分自身に
        // ヒットして緑/赤が反転するのを防ぐため (FEAT-528 E-3 の轍)。
        final all = const LineSplitter().convert(
            File('lib/features/battle/providers/battle_provider.dart')
                .readAsStringSync());
        final src = <int, String>{
          for (var i = 0; i < all.length; i++)
            if (!all[i].trimLeft().startsWith('//')) i + 1: all[i],
        };

        final refreshLines = src.entries
            .where((e) =>
                e.value.contains('playerNotifierProvider.notifier).refresh()'))
            .map((e) => e.key)
            .toList();
        expect(
          refreshLines.length,
          1,
          reason: '🔴 refresh() が 2 箇所以上ある = 成功パスと catch に同じものが '
              '再び生えている。この経路は FEAT-295 hotfix → 2026-07-05 追記と '
              'すでに 2 回足されている。足したいときは _refreshAfterFinish の '
              '中を直すこと。見つかった行: $refreshLines',
        );

        // 呼び出し側が 2 箇所とも共通メソッドを経由していること。
        final callSites = src.values
            .where((l) => l.contains('_refreshAfterFinish()'))
            .where((l) => !l.contains('Future<void> _refreshAfterFinish'))
            .length;
        expect(callSites, 2, reason: '成功パスと catch の 2 箇所から呼ばれている');
      },
    );

    test('B-2 判定に使う homeIsLiveProvider の exists は、ホーム離脱に追従する',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.exists(homeIsLiveProvider), isFalse, reason: 'ホーム未訪問');
      final sub = c.listen(homeIsLiveProvider, (_, __) {});
      expect(c.exists(homeIsLiveProvider), isTrue, reason: 'HomePage が watch 中');
      sub.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.exists(homeIsLiveProvider), isFalse,
          reason: '🔴 autoDispose なので離脱に追従する。'
              'ここが true に張り付くと A-2 が壊れる');
    });

    test(
      'B-3 🔴 homeBootstrapRawProvider の exists は離脱後も true のまま '
      '—— これを判定に使ってはいけない (不採用の記録)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final c = ProviderContainer(overrides: [
          habitsServiceProvider.overrideWithValue(_CountingHabitsService()),
          cacheServiceProvider.overrideWithValue(CacheService(prefs)),
        ]);
        addTearDown(c.dispose);

        final sub = c.listen(homeBootstrapControllerProvider, (_, __) {});
        await Future<void>.delayed(const Duration(milliseconds: 30));
        sub.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // 非 autoDispose + keepAlive() なので、一度ホームを開いたら永久に true。
        expect(c.exists(homeBootstrapRawProvider), isTrue,
            reason: '🔴 FEAT-530 §2.2 の素案 `_ref.exists(homeBootstrapRawProvider)` は '
                'ここで永久 true になる。Pre-mortem #3 がそのまま現実になる形なので '
                '採用していない');
        expect(c.read(homeBootstrapRawProvider).hasValue, isTrue,
            reason: 'hasValue も張り付く (値は保持されたまま)');
      },
    );
  });

  group('FEAT-530 C: エッジケース', () {
    test(
      'C-1 連戦の途中でホームを離れたら、次の 1 戦から refresh() が復活する (Pre-mortem #4)',
      () async {
        final h = await _Harness.create();
        await h.enterHome();
        h.habits.serverExp = 500;

        final first = await h.runOneBattle();
        expect(first.playerFetches, 0, reason: 'ホーム滞在中の 1 戦目');

        // 連戦の途中でギルドへ移動 (ShellRoute のタブ切替で HomePage は unmount)。
        await h.leaveHome();
        h.habits.serverExp = 900;

        final second = await h.runOneBattle();
        expect(second.playerFetches, 1,
            reason: '🔴 ホームを離れた瞬間から ① が復活する。'
                'ここが 0 のままだと「切り替わった 1 戦だけ古い値」が残る');
        expect(second.exp, 900, reason: '離脱後の 1 戦も値が新しくなる');
      },
    );
  });
}
