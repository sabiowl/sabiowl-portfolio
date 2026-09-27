// 【FEAT-523 Phase 1 (2026-08-07)】ambient auto battle の特別報酬が run 終了後に
// 届くことの契約テスト。
//
// ## 既存 14 本では守れない
//
// `ambient_auto_battle_ui_test.dart` / `ambient_auto_battle_orchestrator_test.dart`
// は **「何を出さないか」しか縛っていない** (per-battle モーダルの抑止 / 発火条件)。
// 同じ書き方をすると、**報酬が届かなくなっても緑のまま**になる
// (FEAT-523 Pre-mortem #5)。本ファイルは「届くこと」と「届く順序」を縛る。
//
// ## 何が起きていたか
//
// `c585e012` (2026-08-03) が per-battle モーダルを `isRunning` guard で抑止した。
// **判断は正しい** — 連戦中に `barrierDismissible: false` のモーダルが 1 戦ごとに出て、
// 閉じる前に次戦が始まっていた (FEAT-513 S7 が自ら禁じた形)。
// 足りなかったのは **run 終了後に消化する経路**で、`AmbientBattleSummary` に
// 武器名 / 初勝利ダイヤ / Max ジョブを運ぶ field が無かった。結果:
//
//   - その日初勝利 +5💎 … **8/03 以前は出ていた退行**
//   - 木製武器ドロップ … 10%/戦 で無音
//   - 熟練度 Max      … ジョブごとに 1 回、無音
//
// ## テスト
//
//   A: `weaponDropped` があった run では summary に武器名が載る
//   B: `battleFirstDiamond` があった run では **`isRunning == false` になった後**に
//      ダイヤのシグナルが届く (Pre-mortem #2 — 順序を縛らないテストは何も守れない)
//   C: 中断 run (`queueExhausted == false`) でも報酬が消化される (Pre-mortem #1)
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/ambient_auto_battle_rewards_test.dart
// ```

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/enemy.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/ambient_auto_battle_orchestrator.dart';
import 'package:sabiowl/features/battle/services/battle_service.dart'
    show BattleWeaponDrop;

// ─────────────────────────────────────────────────────────────────────────────
// fixtures
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

BattleState _wonState() => BattleState(
      player: _combatant('player'),
      enemy: _combatant('goblin'),
      tactic: Tactic.offense,
      status: BattleStatus.won,
      logLines: const [],
    );

/// 実物の [BattleSessionNotifier] を継承し、HTTP を張らずに「勝った」state を返す。
///
/// **state 変更は非同期に流す。** orchestrator は `await startBattle()` の **後**に
/// `_awaitBattleCompletion()` で listener を張るので、同期的に state を変えると
/// 変化を取りこぼして 3 分 timeout に落ちる。
class _FakeBattleSession extends BattleSessionNotifier {
  _FakeBattleSession(
    super.ref, {
    required this.results,
  });

  /// 1 戦ごとに返す結果。使い切ったら最後の 1 つを繰り返す。
  final List<BattleSession> results;
  int startCount = 0;

  @override
  Future<void> startBattle({String? enemyKey, bool ambient = false}) async {
    final result = results[startCount.clamp(0, results.length - 1)];
    startCount++;
    // 一旦リセット (本物の startBattle も BattleSession を作り直す)
    state = const BattleSession();
    Future.delayed(const Duration(milliseconds: 10), () {
      state = result;
    });
  }
}

BattleSession _win({
  String? weaponName,
  bool firstDiamond = false,
  String? maxedJob,
  int coins = 15,
  int exp = 6,
}) =>
    BattleSession(
      state: _wonState(),
      token: 'tok',
      rewardCoinsGained: coins,
      rewardExpGained: exp,
      finishCompleted: true,
      battleFirstDiamond: firstDiamond,
      weaponDropped: weaponName == null
          ? null
          : BattleWeaponDrop(
              weaponKey: 'wood_bow', weaponName: weaponName, atkBonus: 3),
      jobMasteryMaxedJobName: maxedJob,
    );

/// preset 1 件だけを積んだ prefs を用意する。
void _setPrefs({required int presetCount}) {
  SharedPreferences.setMockInitialValues({
    'ambient_auto_battle_enabled': true,
    'ambient_auto_battle_preset_goblin': presetCount,
  });
}

Future<AmbientBattleSummary?> _runAndGetSummary(
  ProviderContainer container,
) async {
  final sub = container.listen(enemyListProvider(null), (_, __) {});
  addTearDown(sub.close);
  await container.read(enemyListProvider(null).future);
  await container.read(ambientAutoBattleProvider.notifier).maybeStartAutoBattle();
  return container.read(ambientAutoBattleProvider).summary;
}

ProviderContainer _container(_FakeBattleSession Function(Ref) fake,
    {bool canBattle = true}) {
  return ProviderContainer(overrides: [
    battleAvailabilityProvider.overrideWithValue(_avail(canBattle: canBattle)),
    enemyListProvider(null).overrideWith((_) async => [_enemy('goblin')]),
    ambientAutoBattleCountdownSecondsProvider.overrideWithValue(0),
    battleSessionProvider.overrideWith(fake),
  ]);
}

void main() {
  // orchestrator は playerNotifierProvider を read するので apiClient chain が
  // 起動する。既存の orchestrator テストと同じく secure_storage を mock する。
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

  // ───────────────────────────────────────────────────────────────────────────
  // A: 武器が summary に載る
  // ───────────────────────────────────────────────────────────────────────────
  test('A: weaponDropped があった run では summary に武器名が載る', () async {
    _setPrefs(presetCount: 2);
    final container = _container(
      (ref) => _FakeBattleSession(ref, results: [
        _win(weaponName: '木の弓'),
        _win(),  // 2 戦目はドロップなし
      ]),
    );
    addTearDown(container.dispose);

    final summary = await _runAndGetSummary(container);

    expect(summary, isNotNull, reason: '勝利があれば summary は通知される');
    expect(
      summary!.weaponNames, ['木の弓'],
      reason: 'ambient では per-battle モーダルが guard で抑止されるため、'
          'ここに載らないと武器ドロップはどこにも届かない (10%/戦 が常に無音)',
    );
    expect(summary.hasSpecialRewards, isTrue);
    expect(summary.wins, 2);
  });

  test('A2: 1 run で複数ドロップしたら全部載る', () async {
    _setPrefs(presetCount: 2);
    final container = _container(
      (ref) => _FakeBattleSession(ref, results: [
        _win(weaponName: '木の弓'),
        _win(weaponName: '木の斧'),
      ]),
    );
    addTearDown(container.dispose);

    final summary = await _runAndGetSummary(container);
    expect(summary!.weaponNames, ['木の弓', '木の斧']);
  });

  test('A3: ドロップが無ければ空のまま (空振りしていないことの裏取り)', () async {
    _setPrefs(presetCount: 1);
    final container = _container(
      (ref) => _FakeBattleSession(ref, results: [_win()]),
    );
    addTearDown(container.dispose);

    final summary = await _runAndGetSummary(container);
    expect(summary!.weaponNames, isEmpty);
    expect(summary.hasSpecialRewards, isFalse);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 順序 — isRunning == false になった後に届く
  // ───────────────────────────────────────────────────────────────────────────
  test('B: 初勝利ダイヤは isRunning == false になった後に届く', () async {
    _setPrefs(presetCount: 2);
    final container = _container(
      (ref) => _FakeBattleSession(ref, results: [
        _win(firstDiamond: true),
        _win(),
      ]),
    );
    addTearDown(container.dispose);

    // state 遷移を全部記録し、「summary が非 null になった瞬間の isRunning」を見る。
    final seen = <({bool isRunning, bool hasDiamond})>[];
    final sub = container.listen<AmbientBattleState>(
      ambientAutoBattleProvider,
      (_, next) => seen.add((
        isRunning: next.isRunning,
        hasDiamond: next.summary?.firstDiamond ?? false,
      )),
    );
    addTearDown(sub.close);

    final summary = await _runAndGetSummary(container);

    expect(summary!.firstDiamond, isTrue,
        reason: '8/03 以前は出ていた演出。ここが false だと退行が戻る');

    final diamondEmissions = seen.where((s) => s.hasDiamond).toList();
    expect(diamondEmissions, isNotEmpty,
        reason: 'ダイヤを載せた state が 1 度も publish されていない');
    expect(
      diamondEmissions.every((s) => !s.isRunning),
      isTrue,
      reason: '【Pre-mortem #2】ダイヤのシグナルが isRunning == true の間に出ている。'
          'run 中に演出を出すと、c585e012 が直した問題 '
          '(モーダルが次戦に覆いかぶさる) がそのまま戻る。'
          '\n観測した遷移: $seen',
    );

    // 「run 中に走った state が実在する」= 上の every が空振りでないことの裏取り。
    expect(
      seen.any((s) => s.isRunning),
      isTrue,
      reason: 'isRunning == true の state が 1 度も無い = テストが空振りしている',
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: 中断 run でも消化される
  // ───────────────────────────────────────────────────────────────────────────
  test('C: 敗北で中断した run でも、そこまでの報酬は summary に載る', () async {
    _setPrefs(presetCount: 3);
    final lost = BattleSession(
      state: BattleState(
        player: _combatant('player'),
        enemy: _combatant('goblin'),
        tactic: Tactic.offense,
        status: BattleStatus.lost,
        logLines: const [],
      ),
      token: 'tok',
      finishCompleted: true,
    );
    final container = _container(
      (ref) => _FakeBattleSession(ref, results: [
        _win(weaponName: '木の杖', firstDiamond: true, maxedJob: '魔法剣士'),
        lost,
      ]),
    );
    addTearDown(container.dispose);

    final summary = await _runAndGetSummary(container);

    expect(summary, isNotNull, reason: '敗北で終わっても勝ちが 1 つあれば通知される');
    expect(summary!.queueExhausted, isFalse, reason: '撃ち切っていない');
    expect(
      summary.weaponNames, ['木の杖'],
      reason: '【Pre-mortem #1】中断 run でも武器は「その run で確かに獲得済み」。'
          'queueExhausted を見て落とすと、獲得しているのに演出だけ消える = '
          '元の症状の再発になる',
    );
    expect(summary.firstDiamond, isTrue);
    expect(summary.maxedJobs, ['魔法剣士']);
  });

  test('C2: charges 切れで中断した run でも報酬は載る', () async {
    _setPrefs(presetCount: 5);
    // 【注意】`battleAvailabilityProvider` は Provider で 1 度しか評価されない。
    // 素の bool を閉じ込めても値が更新されないので、StateProvider を watch させて
    // 「1 戦目の開始で charges 切れに倒れる」を再現する。
    final container = ProviderContainer(overrides: [
      battleAvailabilityProvider.overrideWith(
        (ref) => _avail(canBattle: ref.watch(_canBattleFlag)),
      ),
      enemyListProvider(null).overrideWith((_) async => [_enemy('goblin')]),
      ambientAutoBattleCountdownSecondsProvider.overrideWithValue(0),
      battleSessionProvider.overrideWith(_CountingFakeSession.new),
    ]);
    addTearDown(container.dispose);

    final summary = await _runAndGetSummary(container);

    expect(summary, isNotNull);
    expect(
      summary!.queueExhausted, isFalse,
      reason: 'preset 5 のうち 1 戦で止まっているので撃ち切りではない。'
          'ここが true なら charges 切れの分岐を通っていない = テストが空振り',
    );
    expect(summary.weaponNames, ['木の盾'],
        reason: 'charges 切れの中断でも獲得済みの武器は届くこと');
  });
}

/// C2 用: charges 可用性のスイッチ。
final _canBattleFlag = StateProvider<bool>((ref) => true);

/// C2 用: 1 戦だけ武器付きで勝ち、開始と同時に charges を切らす。
class _CountingFakeSession extends BattleSessionNotifier {
  _CountingFakeSession(this._ref) : super(_ref);
  final Ref _ref;

  @override
  Future<void> startBattle({String? enemyKey, bool ambient = false}) async {
    _ref.read(_canBattleFlag.notifier).state = false;
    state = const BattleSession();
    Future.delayed(const Duration(milliseconds: 10), () {
      state = _win(weaponName: '木の盾');
    });
  }
}
