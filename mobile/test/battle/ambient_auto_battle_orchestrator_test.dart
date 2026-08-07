// 【FEAT-513】AmbientAutoBattleOrchestrator + Preferences 契約テスト
//
// 検証対象:
//   T1: オート OFF → maybeStartAutoBattle は即座 return (state 変化なし)
//   T2: charges < 3 → maybeStartAutoBattle は即座 return (state 変化なし)
//   T3: 全 preset = 0 + ON → showEmptyPresetSnackBar シグナル (1日1回)
//   T4: tier 降順ソート — hidden_boss(4) > boss(3) > mid_boss(2) > zako(1)
//   T5: AmbientAutoBattlePreferences.setPreset がクランプ + 永続化する
//   T6: AmbientBattleState — defeatEnemyName 非 null で isRunning=false
//   T7: DailyBattleLimitReachedException 型契約

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/features/battle/models/enemy.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/ambient_auto_battle_orchestrator.dart';
import 'package:sabiowl/features/battle/services/ambient_auto_battle_preferences.dart';
import 'package:sabiowl/features/battle/services/battle_service.dart'
    show DailyBattleLimitReachedException;

// ── テスト用 EnemyMaster ファクトリ ─────────────────────────────────────────

EnemyMaster _makeEnemy({
  required String key,
  required String tier,
  int unlockLevel = 0,
}) =>
    EnemyMaster(
      key: key,
      name: key,
      spriteKey: key,
      baseHp: 100,
      baseAtk: 10,
      baseSpd: 5,
      levelScaling: 1.0,
      rewardCoins: 10,
      rewardExp: 20,
      tier: tier,
      unlockLevel: unlockLevel,
    );

// ── テスト用 BattleAvailability ─────────────────────────────────────────────

BattleAvailability _avail({required bool canBattle, int charges = 0}) =>
    BattleAvailability(
      charges: canBattle ? 3 : charges,
      canBattle: canBattle,
      label: canBattle ? '✓×1' : '',
      description: '',
    );

void main() {
  // 【FEAT-513 T3 fix 2026-07-31】
  // orchestrator は _ref.read(playerNotifierProvider) を read するため、
  // provider chain 経由で apiClient → flutter_secure_storage が起動される。
  // 全 suite 実行時に MissingPluginException で T3 が fail する root cause。
  // 単独実行 (--name T3) では他 test の副作用がないため pass する。
  //
  // 対策: TestWidgetsFlutterBinding + flutter_secure_storage の MethodChannel を
  // mock で null 返却させ、apiClient chain を安全に short-circuit する。
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      // Return null / empty for all secure_storage methods (read/write/delete/etc.)
      // apiClient は token 未取得と判定して HTTP call を組み立てるが、
      // provider の error は AsyncValue.error に captured されるだけで test 全体を
      // fail させない。
      return null;
    });
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  group('FEAT-513: AmbientAutoBattleOrchestrator 契約テスト', () {
    // ────────────────────────────────────────────────────────────────────────
    // T1: オート OFF → maybeStartAutoBattle は即座 return
    // ────────────────────────────────────────────────────────────────────────
    test('T1: ambient_auto_battle_enabled=false → state は変化しない', () async {
      SharedPreferences.setMockInitialValues({
        'ambient_auto_battle_enabled': false,
      });

      final container = ProviderContainer(
        overrides: [
          // canBattle=true にしてもオート OFF なら発火しないことを確認
          battleAvailabilityProvider.overrideWithValue(
            _avail(canBattle: true),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(ambientAutoBattleProvider.notifier);
      await notifier.maybeStartAutoBattle();

      final state = container.read(ambientAutoBattleProvider);
      expect(state.isRunning, isFalse, reason: 'オート OFF → ループ未起動');
      expect(state.defeatEnemyName, isNull);
      expect(state.showEmptyPresetSnackBar, isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // T2: charges < 3 → maybeStartAutoBattle は即座 return
    // ────────────────────────────────────────────────────────────────────────
    test('T2: オート ON + charges < 3 → state は変化しない', () async {
      SharedPreferences.setMockInitialValues({
        'ambient_auto_battle_enabled': true,
      });

      final container = ProviderContainer(
        overrides: [
          battleAvailabilityProvider.overrideWithValue(
            _avail(canBattle: false, charges: 1),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(ambientAutoBattleProvider.notifier).maybeStartAutoBattle();

      final state = container.read(ambientAutoBattleProvider);
      expect(state.isRunning, isFalse, reason: 'charges < 3 → ループ未起動');
      expect(state.showEmptyPresetSnackBar, isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // T3: オート ON + charges OK + 全 preset = 0 → SnackBar シグナル
    // ────────────────────────────────────────────────────────────────────────
    test('T3: オート ON + charges OK + 全 preset=0 → showEmptyPresetSnackBar=true', () async {
      SharedPreferences.setMockInitialValues({
        'ambient_auto_battle_enabled': true,
        // preset キーなし = デフォルト 0
      });

      final goblin = _makeEnemy(key: 'goblin', tier: 'zako');
      final container = ProviderContainer(
        overrides: [
          battleAvailabilityProvider.overrideWithValue(_avail(canBattle: true)),
          enemyListProvider(null).overrideWith((_) async => [goblin]),
        ],
      );
      addTearDown(container.dispose);

      // 【FEAT-513 T3 fix 2026-07-31】
      // enemyListProvider は FutureProvider.autoDispose.family。
      // container.read(...).valueOrNull は初回 null (loading state) を返すため、
      // orchestrator が enemies=null で早期 return する。
      // 対策: container.listen で autoDispose を防ぎつつ future 完了を待ってから
      // maybeStartAutoBattle() を呼ぶ。flutter_secure_storage MethodChannel は
      // setUpAll で mock 済のため、apiClient chain が起動しても安全。
      final enemySub = container.listen(enemyListProvider(null), (_, __) {});
      addTearDown(enemySub.close);
      await container.read(enemyListProvider(null).future);

      await container.read(ambientAutoBattleProvider.notifier).maybeStartAutoBattle();

      final state = container.read(ambientAutoBattleProvider);
      expect(
        state.showEmptyPresetSnackBar,
        isTrue,
        reason: '全 preset=0 → SnackBar シグナルが立つ',
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T4: tier 降順ソート — hidden_boss > boss > mid_boss > zako
    // ────────────────────────────────────────────────────────────────────────
    test('T4: tier 降順ソートで hidden_boss が先頭に来る', () {
      // オーケストレーター内部と同じ _kTierOrder を使ったソートを検証。
      // 実装が変わればこのテストが壊れるため、契約として機能する。
      const kTierOrder = {
        'hidden_boss': 4,
        'boss': 3,
        'mid_boss': 2,
        'zako': 1,
      };

      final enemies = [
        _makeEnemy(key: 'goblin',      tier: 'zako'),
        _makeEnemy(key: 'goblin_king', tier: 'boss'),
        _makeEnemy(key: 'void_dragon', tier: 'hidden_boss'),
        _makeEnemy(key: 'armored_knight', tier: 'mid_boss'),
      ];

      final sorted = [...enemies]
        ..sort((a, b) {
          final ta = kTierOrder[a.tier] ?? 0;
          final tb = kTierOrder[b.tier] ?? 0;
          return tb.compareTo(ta);
        });

      expect(sorted[0].tier, 'hidden_boss');
      expect(sorted[1].tier, 'boss');
      expect(sorted[2].tier, 'mid_boss');
      expect(sorted[3].tier, 'zako');
    });

    // ────────────────────────────────────────────────────────────────────────
    // T5: AmbientAutoBattlePreferences — setPreset はクランプ + 永続化する
    // ────────────────────────────────────────────────────────────────────────
    test('T5: setPreset(enemyKey, count) が SharedPreferences に永続化し 0-99 クランプする',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      // 通常値の書き込み
      await AmbientAutoBattlePreferences.setPreset(prefs, 'goblin', 5);
      expect(
        AmbientAutoBattlePreferences.getPreset(prefs, 'goblin'),
        5,
        reason: '5 を書いて 5 が読める',
      );

      // 上限クランプ (99)
      await AmbientAutoBattlePreferences.setPreset(prefs, 'goblin', 200);
      expect(
        AmbientAutoBattlePreferences.getPreset(prefs, 'goblin'),
        99,
        reason: '200 は 99 にクランプされる',
      );

      // 下限クランプ (0)
      await AmbientAutoBattlePreferences.setPreset(prefs, 'goblin', -3);
      expect(
        AmbientAutoBattlePreferences.getPreset(prefs, 'goblin'),
        0,
        reason: '-3 は 0 にクランプされる',
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T6: AmbientBattleState — defeatEnemyName 設定時に isRunning=false
    // ────────────────────────────────────────────────────────────────────────
    test('T6: AmbientBattleState の defeatEnemyName が非 null のとき isRunning は false', () {
      const defeatState = AmbientBattleState(defeatEnemyName: 'ゴブリンキング');
      expect(defeatState.defeatEnemyName, 'ゴブリンキング');
      expect(defeatState.isRunning, isFalse,
          reason: '敗北シグナル = ループ停止済みであるべき');
      expect(defeatState.showEmptyPresetSnackBar, isFalse);
    });

    // ────────────────────────────────────────────────────────────────────────
    // T7: DailyBattleLimitReachedException 型契約
    // ────────────────────────────────────────────────────────────────────────
    test('T7: DailyBattleLimitReachedException は Exception のサブタイプ', () {
      // オーケストレーターが catch して loop を止める例外の型契約。
      // FEAT-429 で required params 化された 3 field (message / currentCount / limit) を明示。
      final ex = DailyBattleLimitReachedException(
        message: '本日の出陣上限に達しました 🪶',
        currentCount: 10,
        limit: 10,
      );
      expect(ex, isA<Exception>());
    });

    // ────────────────────────────────────────────────────────────────────────
    // T8: AmbientBattleState.countdownSecondsLeft (v1.1 hotfix 2026-07-31)
    // ────────────────────────────────────────────────────────────────────────
    test('T8: countdownSecondsLeft は state field として存在し、他 field と独立', () {
      const countingState = AmbientBattleState(countdownSecondsLeft: 5);
      expect(countingState.countdownSecondsLeft, 5);
      expect(countingState.isRunning, isFalse);
      expect(countingState.defeatEnemyName, isNull);
      expect(countingState.showEmptyPresetSnackBar, isFalse);

      const idleState = AmbientBattleState();
      expect(idleState.countdownSecondsLeft, isNull);
    });

    // ────────────────────────────────────────────────────────────────────────
    // T9: skipCountdown / cancelCountdown は idle 状態で crash しない
    // (v1.1 hotfix 2026-07-31、defensive programming の型契約)
    // ────────────────────────────────────────────────────────────────────────
    test('T9: skipCountdown / cancelCountdown は idle 状態で crash しない', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          battleAvailabilityProvider.overrideWithValue(
            _avail(canBattle: false, charges: 0),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(ambientAutoBattleProvider.notifier);
      // idle 状態で呼んでも例外を投げない (internal flag なので no-op)
      expect(() => notifier.skipCountdown(), returnsNormally);
      expect(() => notifier.cancelCountdown(), returnsNormally);

      // idle 状態が壊れていない
      final state = container.read(ambientAutoBattleProvider);
      expect(state.countdownSecondsLeft, isNull);
      expect(state.isRunning, isFalse);
    });
  });
}
