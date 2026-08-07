// 【2026-07-09 hotfix】BattleSession の startBattle catch 経路 state リセット契約テスト。
//
// 【症状 (user 報告)】ボス連戦で「9 回目 coins/exp=0」→「10 回目タップしても
//   前回討伐後の状態が表示され、変化しない」→ 翌朝復旧。
//
// 【原因】startBattle の catch 経路は `state = state.copyWith(errorMessage: ...)`
//   だけを行い、前 battle の finish state (finishCompleted / rewardCoinsGained 等)
//   をそのまま保持していた。svc.startBattle が失敗すると line 491 の
//   `state = const BattleSession().copyWith(...)` に到達しない = 前 state 持ち越し。
//
// 【本テスト】catch 2 経路 (DailyBattleLimitReachedException + 一般 catch) で
//   state が「新規セッション baseline」= const BattleSession() 相当にリセットされる
//   ことを assert。将来 catch で `state.copyWith` に戻すリファクタが発生した場合の
//   regression 防止。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/battle_service.dart';

/// startBattle を必ず throw させる mock service。
///
/// 非対象メソッド (fetchEnemyList / finishBattle 等) は本テストで呼ばれない前提で
/// UnimplementedError を投げる (=誤って触ったら test 失敗で気づく)。
class _ThrowingBattleService implements BattleService {
  _ThrowingBattleService(this.exceptionToThrow);
  final Object exceptionToThrow;

  @override
  Future<BattleStartResponse> startBattle({
    String? enemyKey,
    int potionsToUse = 0,
    int potionsPlusToUse = 0,
    int attackPotionsToUse = 0,
    int defensePotionsToUse = 0,
  }) async {
    throw exceptionToThrow;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError('test unexpectedly touched: ${invocation.memberName}');
  }
}

void main() {
  group('【2026-07-09 hotfix】BattleSession startBattle catch 経路 state リセット', () {
    test(
      '一般 catch (generic Exception) 経路: state は const BattleSession() に完全リセット '
      '+ errorMessage set',
      () async {
        final container = ProviderContainer(
          overrides: [
            battleServiceProvider.overrideWithValue(
              _ThrowingBattleService(Exception('simulated network failure')),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(battleSessionProvider.notifier);

        await notifier.startBattle();

        final session = container.read(battleSessionProvider);
        // errorMessage は set されている
        expect(session.errorMessage, isNotNull);
        expect(session.errorMessage!, contains('戦闘開始がうまくいきませんでした'));

        // 【核心】前 battle の finish state (以下 4 field) が持ち越されていないこと。
        // 旧実装ではこれらが持ち越されて「10 回目タップしても 9 回目の modal が復活」
        // 現象を生んでいた。
        expect(session.finishCompleted, isFalse,
            reason: 'finishCompleted は初期値 false (前 battle 状態を持ち越さない)');
        expect(session.rewardCoinsGained, 0,
            reason: 'rewardCoinsGained は初期値 0');
        expect(session.rewardExpGained, 0,
            reason: 'rewardExpGained は初期値 0');
        expect(session.leveledUp, isFalse,
            reason: 'leveledUp は初期値 false');
        expect(session.state, isNull,
            reason: 'BattleState は初期値 null (前 orchestrator の finalState を保持しない)');
        expect(session.token, isNull,
            reason: 'token も初期値 null');
      },
    );

    test(
      'DailyBattleLimitReachedException catch 経路: state は completely リセット '
      '+ errorMessage に daily_battle_limit_reached prefix + limit 情報',
      () async {
        final container = ProviderContainer(
          overrides: [
            battleServiceProvider.overrideWithValue(
              _ThrowingBattleService(
                DailyBattleLimitReachedException(
                  message: 'daily limit',
                  currentCount: 10,
                  limit: 10,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(battleSessionProvider.notifier);

        await notifier.startBattle();

        final session = container.read(battleSessionProvider);
        expect(session.errorMessage, isNotNull);
        expect(session.errorMessage!,
            contains('daily_battle_limit_reached:'),
            reason: 'Mobile 側 dialog trigger prefix');
        expect(session.errorMessage!, contains('10/10'));

        // 【核心】DailyBattleLimit 経路でも finish state 持ち越しゼロ
        expect(session.finishCompleted, isFalse);
        expect(session.rewardCoinsGained, 0);
        expect(session.rewardExpGained, 0);
        expect(session.state, isNull);
        expect(session.token, isNull);
      },
    );
  });
}
