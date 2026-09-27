// 【FEAT-531 (2026-08-29)】手動バトルの開始 / 結果を計測する契約テスト。
//
// ## 何を守るテストか
//
// Flutter の PostHog イベント 33 本のうち、battle は 4 本しかなく、しかも
// `ambient_battle_*` 2 本 (自動戦闘のループ単位) と `job_mastery_*` 2 本
// (Lv1 → Max の道中に 9 回) だった。
//
// **ギルド → 敵を選ぶ → BattlePage で戦う → 勝つ / 負ける** という、
// このアプリが最も手をかけて設計した本流には **開始も結果も 1 本も無かった**。
// 結果として次のどれにも答えられない:
//
//   1. 手動でバトルを始める人は DAU の何 %
//   2. 始めた人のうち最後まで戦う人は何 % (途中離脱率)
//   3. 一度負けた人は翌日また戦うか
//
// 一方で「フリーメモの音声入力が失敗した回数」には答えられる状態だった。
//
// ## 🔴 ソース走査ではなく、実際に capture が走ることを見る
//
// 指示書 §3 は「PosthogService を差し替えられる形にする / 大掛かりならソース走査で
// 代替してよい」としていた。**差し替えを採った** —— `PosthogService.debugCaptureSink`
// を足すだけ (実質 5 行) で、走査より遥かに強い。
//
// 計測テストは **対象が呼ばれなくても緑になりやすい**。FEAT-524 Phase 1 で
// 「3 件が黙って緑」だった前例があるので、「その文字列がソースにある」ではなく
// **戦闘を実際に走らせて capture が飛ぶこと**を見る。
//
// | # | 内容 |
// |---|---|
// | A-1 | 手動開始で `battle_started` が `entry: 'manual'` で 1 回 |
// | A-2 | アンビエント開始で `entry: 'ambient'` |
// | A-3 | 勝利で `battle_finished` が `result: 'win'` |
// | A-4 | 🔴 敗北でも `result: 'lose'` が飛ぶ (0 報酬でも送る) |
// | A-5 | 🔴 既存の `ambient_battle_*` を消していない (粒度が違うので両立する) |
// | B-1 | 🔴 `entry` の判定が二重に実装されていない (`ambient` フラグをそのまま流す) |
// | B-2 | 表示名を送っていない (`enemy_key` だけ、FEAT-200 の方針) |
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/battle_analytics_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/analytics/posthog_service.dart';
import 'package:sabiowl/core/cache/cache_service.dart';
import 'package:sabiowl/features/battle/models/job.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/battle_service.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/features/habits/services/habits_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 計測の観測
// ─────────────────────────────────────────────────────────────────────────────

/// 送られた 1 件。
class _Captured {
  const _Captured(this.event, this.properties);
  final String event;
  final Map<String, Object>? properties;

  @override
  String toString() => '$event $properties';
}

/// `PosthogService.debugCaptureSink` を張って、送信を全部拾う。
class _CaptureRecorder {
  final List<_Captured> events = [];

  void install() {
    PosthogService.debugCaptureSink =
        (event, properties) => events.add(_Captured(event, properties));
    addTearDown(() => PosthogService.debugCaptureSink = null);
  }

  List<_Captured> named(String event) =>
      events.where((e) => e.event == event).toList();

  _Captured only(String event) {
    final hits = named(event);
    expect(hits, hasLength(1),
        reason: '$event がちょうど 1 回のはず。実際に飛んだもの: $events');
    return hits.single;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// fakes
// ─────────────────────────────────────────────────────────────────────────────

/// 1 撃で決着する戦闘を返す [BattleService]。
///
/// `playerWins=false` にすると敵が圧倒的に強くなり、敗北で決着する (A-4)。
class _StubBattleService implements BattleService {
  _StubBattleService({this.playerWins = true});

  final bool playerWins;
  int finishCalls = 0;
  String? lastResult;

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
      enemyHp:  playerWins ? 1 : 100000,
      enemyAtk: playerWins ? 1 : 100000,
      enemySpd: playerWins ? 1 : 100,
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
    lastResult = result;
    // 敗北は 0 報酬。**それでも battle_finished は飛ばなければならない** (A-4)。
    final win = result == 'win';
    return BattleFinishResponse(
      coinsGained: win ? 15 : 0,
      expGained:   win ? 20 : 0,
      leveledUp:   false,
      newCoins:    115,
      newExp:      120,
      battleCharges: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'test unexpectedly touched: ${invocation.memberName}',
      );
}

class _StubPlayerNotifier extends PlayerNotifier {
  @override
  Future<Player> build() async => const Player(
        id: 1,
        name: 'テストプレイヤー',
        gender: 'f',
        level: 5,
        currentExp: 0,
        maxExp: 500,
        allocatablePoints: 0,
        diamonds: 0,
        diamondsTotal: 0,
        friendId: '12345678',
        dailyTickets: 0,
        weeklyTickets: 0,
        monthlyTickets: 0,
        reminderEnabled: false,
        mode: 'training',
      );
}

/// `_refreshAfterFinish` (FEAT-530) が bootstrap を invalidate するので、
/// 本物の `HabitsService` が走ると secure_storage の plugin が無くて落ちる。
/// 計測とは無関係なノイズなので塞ぐ。
class _StubHabitsService implements HabitsService {
  @override
  Future<Map<String, dynamic>> fetchHomeBootstrap({String? timeSegment}) async =>
      {'habits': <dynamic>[], 'unread_notif_count': 0};

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'test unexpectedly touched: ${invocation.memberName}',
      );
}

class _StubStatsNotifier extends StatsNotifier {
  @override
  Future<List<CharacterStat>> build() async => const [];
}

/// 1 戦走らせて、その間に飛んだ計測を返す。
Future<_CaptureRecorder> _runOneBattle({
  required bool ambient,
  bool playerWins = true,
  double savedSpeed = 1.0,
  String enemyKey = 'goblin',
  bool waitForFinish = true,
}) async {
  SharedPreferences.setMockInitialValues(
      {'battle_speed_multiplier': savedSpeed});
  // `_refreshAfterFinish` (FEAT-530) が homeBootstrapRawProvider を invalidate
  // するので、cacheService を入れておかないと非同期エラーがログを汚す。
  final prefs = await SharedPreferences.getInstance();
  final rec = _CaptureRecorder()..install();
  final svc = _StubBattleService(playerWins: playerWins);
  final container = ProviderContainer(overrides: [
    battleServiceProvider.overrideWithValue(svc),
    cacheServiceProvider.overrideWithValue(CacheService(prefs)),
    habitsServiceProvider.overrideWithValue(_StubHabitsService()),
    playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
    statsNotifierProvider.overrideWith(_StubStatsNotifier.new),
  ]);
  addTearDown(container.dispose);

  final notifier = container.read(battleSessionProvider.notifier);
  await notifier.startBattle(enemyKey: enemyKey, ambient: ambient);

  if (waitForFinish) {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (container.read(battleSessionProvider).finishCompleted != true) {
      if (DateTime.now().isAfter(deadline)) {
        fail('戦闘が終わらない (テスト設定の問題): '
            'status=${container.read(battleSessionProvider).state?.status}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // `_sendFinish` は fire-and-forget なので、計測が飛ぶまで少し待つ。
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return rec;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FEAT-531 A: 本流のバトルが計測される', () {
    test('A-1 手動開始で battle_started が entry: manual で 1 回', () async {
      final rec = await _runOneBattle(ambient: false, enemyKey: 'slime');

      final started = rec.only('battle_started');
      expect(started.properties, isNotNull);
      expect(started.properties!['entry'], 'manual',
          reason: '🔴 手動経路が manual として記録されていない');
      expect(started.properties!['enemy_key'], 'slime');
      expect(started.properties!['speed_multiplier'], 1.0);
    });

    test('A-2 アンビエント開始だと entry: ambient になる', () async {
      final rec = await _runOneBattle(ambient: true);

      expect(rec.only('battle_started').properties!['entry'], 'ambient',
          reason: '🔴 FEAT-529 の ambient フラグが entry に流れていない');
    });

    test('A-3 勝利で battle_finished が result: win', () async {
      final rec = await _runOneBattle(ambient: false, playerWins: true);

      final finished = rec.only('battle_finished');
      expect(finished.properties!['result'], 'win');
      expect(finished.properties!['entry'], 'manual',
          reason: '開始時の entry が終了時にも引き継がれている');
      expect(finished.properties!['enemy_key'], 'goblin');
      expect(finished.properties!['duration_sec'], isA<int>());
      expect(finished.properties!['rounds'], isA<int>());
    });

    test('A-4 🔴 敗北でも result: lose が飛ぶ (0 報酬でも送る)', () async {
      // 報酬 0 のパスは処理が短いので isWin の分岐の中だけに書いてしまいやすい
      // (Pre-mortem #4)。敗北が測れないと「負けた翌日また戦うか」に永久に
      // 答えられない。
      final rec = await _runOneBattle(ambient: false, playerWins: false);

      final finished = rec.only('battle_finished');
      expect(finished.properties!['result'], 'lose',
          reason: '🔴 敗北が計測されていない。isWin の分岐の中に書いていないか');
    });

    test('A-5 🔴 ambient_battle_* を消していない (粒度が違うので両立する)', () {
      // 既存 2 本は AmbientAutoBattleOrchestrator の **ループ単位** (run の
      // 開始 / 完了) で、本 FEAT が足したのは **1 戦単位**。片方を「重複」と
      // 見て消すと、連戦がどこで止まったかが測れなくなる。
      final src = File(
        'lib/features/battle/services/ambient_auto_battle_orchestrator.dart',
      ).readAsStringSync();
      for (final e in ['ambient_battle_started', 'ambient_battle_completed']) {
        expect(src.contains("'$e'"), isTrue,
            reason: '🔴 $e が消えています。本 FEAT の battle_started /'
                ' battle_finished とは粒度が違うので両立させること (§2.3)');
      }
    });
  });

  group('FEAT-531 B: 壊れ方を防ぐ', () {
    test('B-1 🔴 entry の判定が二重に実装されていない', () {
      // `ambient` フラグ (FEAT-529) と別に判定を書くと、片方だけ直したときに
      // ダッシュボードの手動 / 自動の比率が **静かに狂う** (Pre-mortem #2)。
      // 数字がおかしいことに誰も気付けない種類の壊れ方なので、
      // 「'manual' / 'ambient' というリテラルが 1 箇所からしか出ない」ことを縛る。
      final all = const LineSplitter().convert(
        File('lib/features/battle/providers/battle_provider.dart')
            .readAsStringSync(),
      );
      final code = <int, String>{
        for (var i = 0; i < all.length; i++)
          if (!all[i].trimLeft().startsWith('//')) i + 1: all[i],
      };

      final decisions = code.entries
          .where((e) => e.value.contains("'ambient' : 'manual'") ||
              e.value.contains("'manual' : 'ambient'"))
          .map((e) => e.key)
          .toList();
      expect(decisions, hasLength(1),
          reason: '🔴 entry を決めている三項演算子が 1 箇所ではありません。'
              '判定を増やすと手動 / 自動の比率が静かに狂います。'
              '見つかった行: $decisions');

      // 三項演算子以外の場所で 'manual' を作っていないこと。
      final manualLiterals = code.entries
          .where((e) => e.value.contains("'manual'"))
          .map((e) => e.key)
          .toList();
      expect(manualLiterals, equals(decisions),
          reason: "🔴 'manual' が entry 判定以外の行にも現れています: $manualLiterals");
    });

    test('B-2 表示名を送っていない (FEAT-200: キーだけ)', () async {
      // enemy_name のような表示名を足すと **ロケール依存の文字列**が入り、
      // 集計が ja / en で割れる (Pre-mortem #5)。
      final rec = await _runOneBattle(ambient: false);

      for (final e in [...rec.named('battle_started'),
                       ...rec.named('battle_finished')]) {
        expect(e.properties!.containsKey('enemy_name'), isFalse,
            reason: '🔴 表示名を送っています: ${e.properties}');
        for (final v in e.properties!.values) {
          if (v is String) {
            expect(RegExp(r'[぀-ヿ一-鿿]').hasMatch(v), isFalse,
                reason: '🔴 日本語の表示名が properties に混ざっています: '
                    '${e.event} -> ${e.properties}');
          }
        }
      }
    });
  });
}
