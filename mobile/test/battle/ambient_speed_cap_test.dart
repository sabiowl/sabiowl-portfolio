// 【FEAT-529 (2026-08-22)】アンビエント（ホーム額縁）バトルの速度上限テスト。
//
// ## 何を守るテストか
//
// バトル速度 `battle_speed_multiplier` は 1 本の設定で、アンビエントバトルも
// 通常バトルと同じ `startBattle` を通る（FEAT-513 v1.1 hotfix 2 follow-up で
// headless 経路を撤去して visible battle 経路へ統合したため）。
// その結果 **Skip (50x) のままホームに戻ると額縁のバトルも 50 倍速で走り**、
// FEAT-527 で 6 キャラ分描いた攻撃モーション（400ms 固定 = 倍速に追従しない）が
// 一度も見えないまま決着する。
//
// FEAT-529 は「額縁だけ 3x で頭打ち」という最小の変更でこれを塞いだ。
// 本ファイルはその契約を 2 方向から縛る:
//
//   A-1: ambient は 50x → 3x に落ちる（上限が効いている）
//   A-2: 🔴 通常バトルは 50x のまま（上限が Skip 機能に漏れていない）
//   A-3: 上限未満（2x）は素通り（1.5x/2x/3x のユーザーに影響がない）
//   A-4: 🔴 ambient バトル後も pref は 50.0 のまま（設定を書き換えていない）
//   B-1: `ambient: true` を渡すのは orchestrator の 1 箇所だけ
//
// A-2 と A-4 が本体。**上限そのものより「上限が漏れないこと」のほうが壊れると痛い**
// （FEAT-529 Pre-mortem #1 / #2）。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/ambient_speed_cap_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/features/battle/constants/battle_constants.dart';
import 'package:sabiowl/features/battle/models/job.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/battle_service.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';

const _prefsKey = 'battle_speed_multiplier';

/// HTTP を張らずに戦闘開始レスポンスだけ返す [BattleService]。
///
/// 非対象メソッドは `noSuchMethod` で throw させ、誤って触ったら
/// テストが失敗して気づけるようにしておく（既存 battle テストと同じ流儀）。
class _StubBattleService implements BattleService {
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
      // HP を厚くして、speedMultiplier を読む前に決着しないようにする。
      enemyHp: 100000,
      enemyAtk: 1,
      enemySpd: 1,
      playerJob: Job.fallback,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'test unexpectedly touched: ${invocation.memberName}',
    );
  }
}

/// `startBattle` は `_buildPlayerCombatant` で Player / Stat provider を read する。
/// override しないと本物が apiClient chain を起動し、非同期エラーでテストが落ちる。
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

class _StubStatsNotifier extends StatsNotifier {
  @override
  Future<List<CharacterStat>> build() async => const [];
}

List<Override> _overrides() => [
      battleServiceProvider.overrideWithValue(_StubBattleService()),
      playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
      statsNotifierProvider.overrideWith(_StubStatsNotifier.new),
    ];

/// pref に [savedSpeed] を仕込んで 1 戦開始し、実効 `speedMultiplier` を返す。
Future<double> _effectiveSpeed({
  required double savedSpeed,
  required bool ambient,
}) async {
  SharedPreferences.setMockInitialValues({_prefsKey: savedSpeed});
  final container = ProviderContainer(overrides: _overrides());
  addTearDown(container.dispose);

  final notifier = container.read(battleSessionProvider.notifier);
  await notifier.startBattle(enemyKey: 'goblin', ambient: ambient);

  final state = container.read(battleSessionProvider).state;
  expect(state, isNotNull, reason: '戦闘が開始できていない（テスト設定の問題）');
  return state!.speedMultiplier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('【FEAT-529】A: アンビエントバトルの速度上限', () {
    test(
      'A-1: pref が 50.0 (Skip) のとき、ambient の実効速度は 3.0 に落ちる',
      () async {
        final speed = await _effectiveSpeed(savedSpeed: 50.0, ambient: true);

        expect(
          speed,
          BattleConstants.ambientMaxSpeedMultiplier,
          reason: '額縁に Skip を持ち込むと FEAT-527 の攻撃モーション (400ms 固定) が '
              '一度も見えないまま決着する',
        );
        expect(speed, 3.0, reason: '上限値そのものが変わったら気づけるようにする');
      },
    );

    test(
      '🔴 A-2: 同じ pref でも通常バトルは 50.0 のまま (上限が Skip 機能に漏れていない)',
      () async {
        final speed = await _effectiveSpeed(savedSpeed: 50.0, ambient: false);

        expect(
          speed,
          50.0,
          reason: 'Skip は「1-2 秒で終わる」ことが価値。3x (30-45 秒) に落ちた時点で '
              '機能そのものが壊れている (Pre-mortem #2)',
        );
      },
    );

    test(
      'A-2b: ambient の既定値は false (呼び出し側が明示しない限り上限はかからない)',
      () async {
        SharedPreferences.setMockInitialValues({_prefsKey: 50.0});
        final container = ProviderContainer(overrides: _overrides());
        addTearDown(container.dispose);

        // ambient を渡さない = BattlePage / ギルドと同じ呼び方。
        await container
            .read(battleSessionProvider.notifier)
            .startBattle(enemyKey: 'goblin');

        expect(
          container.read(battleSessionProvider).state!.speedMultiplier,
          50.0,
          reason: '既定値が true に倒れると Skip が全経路で壊れる',
        );
      },
    );

    test('A-3: pref が 2.0 (上限未満) なら ambient も 2.0 で素通り', () async {
      final speed = await _effectiveSpeed(savedSpeed: 2.0, ambient: true);

      expect(
        speed,
        2.0,
        reason: '上限を 1x ではなく 3x にしたのは、1.5x/2x/3x のユーザーの挙動を '
            '変えないため',
      );
    });

    test('A-3b: pref が 3.0 (上限ちょうど) でも切り下げない', () async {
      final speed = await _effectiveSpeed(savedSpeed: 3.0, ambient: true);

      expect(speed, 3.0, reason: '比較は > であって >= ではない');
    });

    test(
      '🔴 A-4: ambient バトル後も pref は 50.0 のまま (ユーザーの設定を書き換えない)',
      () async {
        SharedPreferences.setMockInitialValues({_prefsKey: 50.0});
        final container = ProviderContainer(overrides: _overrides());
        addTearDown(container.dispose);

        await container
            .read(battleSessionProvider.notifier)
            .startBattle(enemyKey: 'goblin', ambient: true);

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getDouble(_prefsKey),
          50.0,
          reason: 'clamp 結果を書き戻すと、額縁バトルが 1 回走っただけで '
              'バトル画面の Skip 設定が消える。しかもホームに戻っただけなので '
              'ユーザーは「いつ消えたか」を特定できない (Pre-mortem #1)',
        );
      },
    );
  });

  group('【FEAT-529】B: 呼び出し側のソース走査', () {
    test('B-1: ambient: true を渡すのは ambient orchestrator の 1 箇所だけ', () {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue,
          reason: 'mobile/ を作業ディレクトリとして flutter test を実行すること');

      final hits = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final src = entity.readAsStringSync();
        if (!src.contains('ambient: true')) continue;
        final rel = entity.path.split(Platform.pathSeparator).join('/');
        hits.add(rel);
      }

      expect(
        hits,
        ['lib/features/battle/services/ambient_auto_battle_orchestrator.dart'],
        reason: '額縁以外から ambient: true が渡ると、その経路の Skip が黙って '
            '効かなくなる',
      );
    });

    test('B-2: startBattle の宣言は ambient の既定値 false を持つ', () {
      final src =
          File('lib/features/battle/providers/battle_provider.dart')
              .readAsStringSync();

      expect(
        src,
        contains('startBattle({String? enemyKey, bool ambient = false})'),
        reason: '既定値を true にすると Skip が全経路で壊れる (Pre-mortem #2)',
      );
    });

    test('B-3: clamp は savedSpeed だけで、prefs へ書き戻していない', () {
      // 【FEAT-528 (2026-08-22)】素朴な「ファイル全体に setDouble が無いこと」から
      // 書き換えた。FEAT-528 が同ファイルに `BattleSpeedPreferenceNotifier`
      // (速度 pref の唯一の書き手) を置いたので、その条件はもう成立しない。
      //
      // 🔴 **守りたいものは変わっていない**: clamp は「このバトルの実効値」だけを
      // 変えるのであって、**ユーザーの設定を書き換えてはいけない**。
      // なので「startBattle の中に書き込みが無いこと」を直接見る。
      final raw = File('lib/features/battle/providers/battle_provider.dart')
          .readAsStringSync();
      // doc コメントには「こう書いてはいけない」の例として同じ文字列が載っている。
      // 素直に走査すると**説明文が違反として検出される**ので落としてから見る。
      final src = const LineSplitter()
          .convert(raw)
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('|');

      expect(
        src,
        contains(
          'if (ambient && savedSpeed > BattleConstants.ambientMaxSpeedMultiplier)',
        ),
      );

      final writes = 'setDouble'.allMatches(src).toList();
      expect(writes.length, 1,
          reason: '速度 pref の書き手は BattleSpeedPreferenceNotifier だけ '
              '(FEAT-528 D-1 と同じ不変条件)');
      expect(
        writes.single.start,
        lessThan(src.indexOf('Future<void> startBattle(')),
        reason: '🔴 唯一の書き込みは notifier 側にあり、startBattle の中には無いこと。'
            'clamp 結果を書き戻すと、額縁バトルが 1 回走っただけで'
            'バトル画面の Skip 設定が消える (Pre-mortem #1)',
      );
    });
  });
}
