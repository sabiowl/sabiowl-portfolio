import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/posthog_service.dart';
import '../../habits/providers/habits_provider.dart' show playerNotifierProvider;
import '../models/battle_state.dart' show BattleStatus;
import '../models/enemy.dart' show EnemyMaster;
import '../providers/battle_provider.dart';
import '../services/battle_service.dart' show DailyBattleLimitReachedException;
import 'ambient_auto_battle_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AmbientBattleState — UI 通知用の状態
// ─────────────────────────────────────────────────────────────────────────────

class AmbientBattleState {
  const AmbientBattleState({
    this.isRunning = false,
    this.countdownSecondsLeft,
    this.defeatEnemyName,
    this.showEmptyPresetSnackBar = false,
    this.remainingBattles = 0,
    this.summary,
  });

  final bool isRunning;

  /// 【FEAT-513 v1.1 hotfix 2026-07-31】非 null = countdown 進行中 (10→1 の秒数)。
  /// WorldFrame 内で「N 秒後に自動出陣します」+ Skip button を表示する。
  final int? countdownSecondsLeft;

  /// 非 null = ホーム画面に敗北 dialog を表示させるシグナル。
  final String? defeatEnemyName;

  /// true = ホーム画面に「敵を選んでください」SnackBar を表示させるシグナル。
  final bool showEmptyPresetSnackBar;

  /// 【gameplay_review 20260803 §2-2 d】queue の残り戦闘数 (実行中の 1 戦を含む)。
  /// `isRunning == true` の間だけ意味を持つ。WorldFrame 下部の subtle 表示に使う。
  final int remainingBattles;

  /// 【gameplay_review 20260803 §2-2 d】非 null = queue が終了したシグナル。
  ///
  /// FEAT-513 Pre-mortem S7 は「連続勝利中は SnackBar を表示しない」と決めていたが、
  /// 実装は 1 戦ごとに `barrierDismissible: false` のモーダルを出しており、
  /// 2 秒後には次戦が始まるため **user が閉じる前に次の戦闘が動き出す**状態だった。
  /// 対策として per-battle モーダルは queue 実行中は抑止し、代わりに run 全体の
  /// 集計をここで 1 回だけ通知する。
  final AmbientBattleSummary? summary;
}

/// 【gameplay_review 20260803 §2-2 d】ambient queue 1 run 分の戦果。
///
/// 【FEAT-523 Phase 1 (2026-08-07)】特別報酬 3 種を運ぶ field を追加した。
///
/// `c585e012` が per-battle モーダルを `isRunning` guard で抑止した判断は正しい
/// (連戦中に `barrierDismissible: false` のモーダルが 1 戦ごとに出て、閉じる前に
/// 次戦が始まっていた = FEAT-513 S7 が自ら禁じた形)。**足りなかったのは run 終了後に
/// 消化する経路**で、本 class に運搬手段が無かったため以下が無音になっていた:
///
///   - その日初勝利 +5 💎 (FEAT-314) … **8/03 以前は出ていた退行**
///   - 木製武器ドロップ (FEAT-443)   … 10%/戦
///   - 熟練度 Max dialog (FEAT-511)  … ジョブごとに 1 回
///
/// per-battle では出せないが **run 単位でなら出せる**、というのが本件の構造。
/// guard は条件付きにもしない (それをすると c585e012 が直した問題に戻る)。
class AmbientBattleSummary {
  const AmbientBattleSummary({
    required this.wins,
    required this.coins,
    required this.exp,
    required this.queueExhausted,
    this.weaponNames = const [],
    this.firstDiamond = false,
    this.maxedJobs = const [],
  });

  /// この run での勝利数 (1 以上のときだけ通知される)。
  final int wins;
  final int coins;
  final int exp;

  /// true = preset を撃ち切って自然終了した (要素 C-4 の案内を添える)。
  /// false = charges 切れ / 日次上限 / 敗北 など途中終了。
  ///
  /// 【FEAT-523 Pre-mortem #1】**下の 3 field は本値に関わらず消化する。**
  /// 中断 run でも武器やダイヤは「その run で確かに獲得済み」で、
  /// 獲得しているのに演出だけ消えるのは元の症状の再発になる。
  final bool queueExhausted;

  /// 【FEAT-523】この run で拾った木製武器の名前 (FEAT-443、10%/戦)。
  final List<String> weaponNames;

  /// 【FEAT-523】この run でその日初勝利ダイヤ (+5💎、FEAT-314) が出たか。
  final bool firstDiamond;

  /// 【FEAT-523】この run で熟練度 Max に到達したジョブ名 (FEAT-511)。
  final List<String> maxedJobs;

  /// 特別報酬が 1 つでもあるか (通常の戦果トーストに追記するかの判定)。
  bool get hasSpecialRewards =>
      weaponNames.isNotEmpty || firstDiamond || maxedJobs.isNotEmpty;
}

// tier 降順ソート用: hidden_boss > boss > mid_boss > zako
const _kTierOrder = {
  'hidden_boss': 4,
  'boss': 3,
  'mid_boss': 2,
  'zako': 1,
};

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

/// 【FEAT-513 v1.1 hotfix 2026-07-31】countdown 秒数の inject provider。
/// production = 10 秒、tests は overrideWithValue(0) で即座に battle 開始可能。
final ambientAutoBattleCountdownSecondsProvider =
    Provider<int>((ref) => 10);

final ambientAutoBattleProvider =
    StateNotifierProvider<AmbientAutoBattleNotifier, AmbientBattleState>(
  (ref) => AmbientAutoBattleNotifier(ref),
);

// ─────────────────────────────────────────────────────────────────────────────
// AmbientAutoBattleNotifier
// ─────────────────────────────────────────────────────────────────────────────

/// 【FEAT-513】Ambient Auto Battle の実行制御 StateNotifier。
///
/// 設計ポイント:
///   - `_isRunning` フラグで二重発火を防止 (S10)
///   - 呼出元は `maybeStartAutoBattle()` を fire-and-forget で呼ぶだけでよい
///   - 敗北 / SnackBar は `state` の変化として通知し、HomePage が ref.listen で受ける
///   - UI シグナル消費後は `clearUiSignals()` を呼んで state をリセットする
class AmbientAutoBattleNotifier extends StateNotifier<AmbientBattleState> {
  AmbientAutoBattleNotifier(this._ref) : super(const AmbientBattleState());

  final Ref _ref;

  // S10: 二重発火防止フラグ (provider 再生成がなければ有効)
  bool _isRunning = false;

  /// 【FEAT-513 v1.1 hotfix 2026-07-31】countdown 進行中 flag。
  bool _countdownActive = false;

  /// 【FEAT-513 v1.1 hotfix 2026-07-31】countdown 中に user が Skip 押下 = 即開始。
  bool _skipRequested = false;

  /// 【FEAT-513 v1.1 hotfix 2026-07-31】countdown 中に user が Cancel = auto battle 中止。
  bool _cancelRequested = false;

  /// 【gameplay_review 20260803 要素 A-4】次回 1 回だけ countdown を省略する。
  ///
  /// 敗北 dialog の「続ける」は user の明示的な再開意思なので、countdown の目的
  /// (= 意図しない発火を止める猶予) は既に満たされている。そこで再度 10 秒待たせるのは
  /// 「今まさに続けると言ったのに待たされる」という一番いらない待ちになる。
  bool _skipNextCountdown = false;

  /// ホーム到着時 or task 達成で charges 到達時に呼ぶ。前提条件確認 → 10 秒
  /// countdown → バトルループ実行の 3 段階。
  /// fire-and-forget: エラーを外部に投げず、全例外を内部で吸収する。
  Future<void> maybeStartAutoBattle() async {
    if (_isRunning || _countdownActive) return; // S10: 二重発火防止

    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. 機能 ON/OFF チェック
      if (!AmbientAutoBattlePreferences.isEnabled(prefs)) return;

      // 2. チャージ (charges >= 3) チェック
      final avail = _ref.read(battleAvailabilityProvider);
      if (!avail.canBattle) return;

      // 3. 解放済み敵の取得
      // 【FEAT-513 v1.1 hotfix 2026-07-31】旧: `.valueOrNull` は enemyListProvider
      // (autoDispose.family) が home 画面で watch されていない場合に null → silent
      // return する構造的 bug (user 報告: ホームで task 3 回達成しても countdown が
      // 出ず、Guild 画面等を経由して再 home した時のみ発火)。
      // 新: `.future` を await して orchestrator 側で fetch を強制、home からの
      // 発火経路を保証する。fetch 失敗時のみ silent return。
      final List<EnemyMaster> enemies;
      try {
        enemies = await _ref.read(enemyListProvider(null).future);
      } catch (_) {
        return;
      }
      if (enemies.isEmpty) return;

      final playerLevel =
          _ref.read(playerNotifierProvider).valueOrNull?.level ?? 0;
      final unlocked = enemies
          .where((e) => e.unlockLevel <= 0 || playerLevel >= e.unlockLevel)
          .toList();
      if (unlocked.isEmpty) return;

      // 4. preset 一覧取得
      final presets = AmbientAutoBattlePreferences.getAllPresets(
        prefs,
        unlocked.map((e) => e.key).toList(),
      );

      // 5. すべての preset が 0 → 1 日 1 回 SnackBar シグナル
      if (presets.values.every((v) => v == 0)) {
        if (AmbientAutoBattlePreferences.shouldShowEmptySnackBar(prefs)) {
          await AmbientAutoBattlePreferences.markEmptySnackBarShown(prefs);
          state = const AmbientBattleState(showEmptyPresetSnackBar: true);
        }
        return;
      }

      // ─── 6. 10 秒 countdown (FEAT-513 v1.1 hotfix 2026-07-31) ─────────────
      // 【要素 A-4】「続ける」直後は 0 秒 = countdown を挟まず即開始する。
      final countdownSeconds = _skipNextCountdown
          ? 0
          : _ref.read(ambientAutoBattleCountdownSecondsProvider);
      _skipNextCountdown = false;
      _countdownActive = true;
      _skipRequested = false;
      _cancelRequested = false;
      try {
        for (int i = countdownSeconds; i > 0; i--) {
          state = AmbientBattleState(countdownSecondsLeft: i);
          if (countdownSeconds > 0) {
            await Future.delayed(const Duration(seconds: 1));
          }
          if (_cancelRequested) {
            // Cancel = auto battle 中止、idle 状態に戻す
            state = const AmbientBattleState();
            return;
          }
          if (_skipRequested) break; // Skip = 即バトル開始
        }
      } finally {
        _countdownActive = false;
      }

      // ─── 7. バトルループ開始 ────────────────────────────────────────────
      _isRunning = true;

      // 【gameplay_review 20260803 §2-2 d】run 全体の戦果を集計する。
      // per-battle モーダル (1 戦ごとに次戦へ覆いかぶさる) を抑止する代償として、
      // 終了時に 1 回だけまとめて通知するための材料。
      var wins = 0;
      var coins = 0;
      var exp = 0;
      // 【FEAT-523 Phase 1】特別報酬は per-battle では出せない (guard で抑止済) ので、
      // run 単位で積んで終了時に 1 度だけ消化する。
      final weaponNames = <String>[];
      final maxedJobs = <String>[];
      var firstDiamond = false;
      var remainingTotal = presets.values.fold<int>(0, (sum, v) => sum + v);
      state = AmbientBattleState(
        isRunning: true,
        remainingBattles: remainingTotal,
      );

      /// 途中終了 (charges 切れ / 日次上限 / timeout) でも戦果を握り潰さない共通 exit。
      void stopWithSummary({required bool exhausted}) {
        state = wins > 0
            ? AmbientBattleState(
                summary: AmbientBattleSummary(
                  wins: wins,
                  coins: coins,
                  exp: exp,
                  queueExhausted: exhausted,
                  // 【FEAT-523 Pre-mortem #1】exhausted の値に関わらず必ず載せる。
                  // 中断 run でも獲得済みなので、ここで落とすと元の症状に戻る。
                  weaponNames: List.unmodifiable(weaponNames),
                  firstDiamond: firstDiamond,
                  maxedJobs: List.unmodifiable(maxedJobs),
                ),
              )
            : const AmbientBattleState();
      }

      // Q2: tier 降順ソート (hidden_boss > boss > mid_boss > zako)
      final sorted = [...unlocked]
        ..sort((a, b) {
          final ta = _kTierOrder[a.tier] ?? 0;
          final tb = _kTierOrder[b.tier] ?? 0;
          return tb.compareTo(ta);
        });

      for (final enemy in sorted) {
        var remaining = presets[enemy.key] ?? 0;

        while (remaining > 0) {
          // charges を再チェック (バトルごとに消費されるため)
          final currentAvail = _ref.read(battleAvailabilityProvider);
          if (!currentAvail.canBattle) {
            stopWithSummary(exhausted: false);
            return;
          }

          PosthogService.instance.capture(
            'ambient_battle_started',
            properties: {'enemy_key': enemy.key},
          );

          // 【FEAT-513 v1.1 hotfix 2 (2026-07-31)】visible battle 経路 (startBattle
          // → BattleSessionNotifier 経由で MiniBattleArena が WorldFrame に render)。
          // 旧 headless 経路 (runSkipBattle、hotfix 2 follow-up で完全撤去) では
          // WorldFrame 演出なしで user 目に見えない bug があった。完了検知は
          // _onOrchestratorUpdate の auto-finish を wait する。
          BattleSession? session;
          try {
            await _ref
                .read(battleSessionProvider.notifier)
                .startBattle(enemyKey: enemy.key);
            session = await _awaitBattleCompletion();
          } on DailyBattleLimitReachedException {
            // T7: 日次上限 → ループ終了
            stopWithSummary(exhausted: false);
            return;
          }

          if (session == null) {
            // startBattle がエラーを吸収して null を返した / timeout
            stopWithSummary(exhausted: false);
            return;
          }

          // 【FEAT-513 v1.1 hotfix 2026-07-31】visible battle 経路では
          // session.state?.status で直接判定 (敗北時 reward=0 で判定不能を回避)。
          final won = session.state?.status == BattleStatus.won;
          PosthogService.instance.capture(
            'ambient_battle_completed',
            properties: {'enemy_key': enemy.key, 'won': won},
          );

          if (!won) {
            // Q7: 敗北 → ループ停止 + 敗北 dialog シグナル
            // 【gameplay_review 20260803 §2-2 d】敗北までに積んだ戦果も同時に渡す
            // (ホーム側でトースト → 敗北 dialog の順に消化される)。
            state = AmbientBattleState(
              defeatEnemyName: enemy.name,
              summary: wins > 0
                  ? AmbientBattleSummary(
                      wins: wins,
                      coins: coins,
                      exp: exp,
                      queueExhausted: false,
                      // 【FEAT-523 Pre-mortem #1】敗北で終わった run でも、
                      // そこまでに拾った武器 / ダイヤ / Max は確かに獲得済み。
                      weaponNames: List.unmodifiable(weaponNames),
                      firstDiamond: firstDiamond,
                      maxedJobs: List.unmodifiable(maxedJobs),
                    )
                  : null,
            );
            return;
          }

          // 勝利: 戦果を加算し、preset を 1 減らして永続化
          wins++;
          coins += session.rewardCoinsGained;
          exp += session.rewardExpGained;
          // 【FEAT-523 Phase 1】特別報酬を run に積む。
          // BattlePage / ホーム単発経路では showPostBattleRewards が消化するが、
          // ambient では guard でモーダルごと抑止されるため、ここで拾わないと
          // どこにも届かない。
          final drop = session.weaponDropped;
          if (drop != null) weaponNames.add(drop.weaponName);
          if (session.battleFirstDiamond) firstDiamond = true;
          final maxedJob = session.jobMasteryMaxedJobName;
          if (maxedJob != null) maxedJobs.add(maxedJob);
          remaining--;
          if (remainingTotal > 0) remainingTotal--;
          await AmbientAutoBattlePreferences.setPreset(
            prefs,
            enemy.key,
            remaining,
          );
          if (remainingTotal > 0) {
            state = AmbientBattleState(
              isRunning: true,
              remainingBattles: remainingTotal,
            );
          }
        }
      }

      // 全バトル完了
      stopWithSummary(exhausted: true);
    } catch (_) {
      // 予期しない例外はサイレント吸収。ホーム画面を壊さない。
      state = const AmbientBattleState();
    } finally {
      _isRunning = false;
      _countdownActive = false;
    }
  }

  /// 【FEAT-513 v1.1 hotfix 2026-07-31】visible battle 完了を wait する helper。
  ///
  /// _onOrchestratorUpdate (battle_provider.dart:730) が won/lost 検知時に
  /// _sendFinish を呼び、Backend への finish 送信 + reward 反映を実行する。
  /// 本 method は battle status が won/lost に達したことを検知し、finish 送信
  /// 完了を待つため extra 2 秒 delay してから state を返す。
  ///
  /// 敗北時 rewardExpGained=0 のケースを考慮し、reward の値では判定せず
  /// **status 変化のみ** をトリガーとする。
  ///
  /// Timeout: 3 分 (1x で 100-140 秒 + 余裕、tap 待ちで hang しないよう cap)。
  Future<BattleSession?> _awaitBattleCompletion() async {
    final completer = Completer<BattleSession?>();
    late final ProviderSubscription<BattleSession> sub;
    sub = _ref.listen<BattleSession>(
      battleSessionProvider,
      (prev, next) {
        final status = next.state?.status;
        if (status == BattleStatus.won || status == BattleStatus.lost) {
          if (!completer.isCompleted) {
            // _sendFinish の Backend round-trip を待つため 2 秒余裕を持たせる。
            Future.delayed(const Duration(seconds: 2), () {
              if (!completer.isCompleted) {
                completer.complete(_ref.read(battleSessionProvider));
              }
            });
          }
        }
      },
      fireImmediately: false,
    );
    try {
      return await completer.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => null,
      );
    } finally {
      sub.close();
    }
  }

  /// 【FEAT-513 v1.1 hotfix】countdown 中に「今すぐ開始」button 押下時に呼ぶ。
  void skipCountdown() {
    if (_countdownActive) _skipRequested = true;
  }

  /// 【FEAT-513 v1.1 hotfix】countdown 中に「キャンセル」button 押下時に呼ぶ。
  void cancelCountdown() {
    if (_countdownActive) _cancelRequested = true;
  }

  /// 【gameplay_review 20260803 要素 A-4】次回 1 回だけ countdown を省略させる。
  /// 敗北 dialog の「続ける」から `maybeStartAutoBattle()` を呼ぶ直前に使う。
  void requestSkipNextCountdown() {
    _skipNextCountdown = true;
  }

  /// ホーム画面が dialog / SnackBar を表示した後に呼ぶ。UI シグナルをリセットする。
  void clearUiSignals() {
    state = const AmbientBattleState();
  }
}
