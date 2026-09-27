/// 【BUG-150 (2026-08-29)】**タスク達成レスポンス → provider** の単一真実値。
///
/// ## なぜこのファイルがあるか
///
/// 達成のレスポンスには popup を出すためのフィールドが 4 つ乗っている
/// (`todayLoginBonus` / `puzzlePieceAwarded` / `monthlyTicketAwarded` /
/// `friendGiftCandidate`)。ところが**それを provider に流す配線が 5 箇所に
/// 複製されており、どれも中身が違った**:
///
/// | 経路 | 落ちていたもの |
/// |---|---|
/// | `habits_provider._incrementCount` | （完全） |
/// | `habits_provider.toggleChecklistItem` | かけら / フレンドギフト / 復帰 / シールド / streak 系 |
/// | `daily_task_section`（カレンダーの ToDo） | **上記 + ログインボーナス + 月次チケット + 結晶** |
/// | `timeline_event_card`（ホームのタイムライン） | （完全） |
/// | `daily_task_section`（カレンダーのタイムライン） | **ログインボーナス + かけら** |
///
/// 🔴 **ログインボーナス / かけら / 月次チケットは Backend 側で配布済み**なので、
/// 落ちた経路で初回達成すると **その日（月）は二度と出ない**。
/// 報酬は入っているのに、もらったことに気づく手段が残らない。
///
/// ## なぜ複製されたか
///
/// `daily_task_section` が `habitsServiceProvider` を直呼びしているのは
/// **BUG-56 の回避策**（`habitsNotifierProvider` は autoDispose で、カレンダー
/// タブ滞在中に dispose されている）で、**判断としては正しい**。ただし結果として
/// 配線が複製され、**後から足された BUG-122 / FEAT-433 / FEAT-452 / FEAT-479 が
/// 片方にしか入らなかった**。
///
/// FEAT-534 の `popup_census_test.dart` が見つけた「**誰も間違っていない。
/// 合計を数える担当が誰にも割り当てられていない**」と同じ型の別インスタンスである。
///
/// ## 縛り
///
/// `test/habits/apply_completion_result_test.dart` が
/// **「popup 系 provider に値を書いてよいのはこのファイルだけ」**を走査で縛る。
/// 6 箇所目を足したら落ちる。
library;

import 'package:flutter/foundation.dart';                    // debugPrint
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';  // 【FEAT-398】1 日 1 回制御

import '../../../core/services/toast_center.dart';
import '../../../l10n/app_localizations.dart';
import '../../puzzle_world/models/puzzle_world.dart';
import '../../puzzle_world/providers/puzzle_world_provider.dart';
import '../../social/models/social_models.dart';
import '../../social/providers/social_provider.dart';
import '../../timeline/services/timeline_service.dart' show TimelineReward;
import '../models/habit.dart' show HabitLogResult, HabitReward;
import 'habits_provider.dart';

/// `Ref` と `WidgetRef` の両方を受けるための最小インターフェース。
///
/// Riverpod 2.x には両者の共通の親が無いので、`read` だけを関数として受け取る。
/// 呼び出し側は `applyHabitLogResult(ref.read, result)` と書く。
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// 習慣 / ToDo / チェックリストの達成レスポンスを provider に流す。
///
/// 🔴 **新しい popup を足すときはここに足す。** 呼び出し側に書くと 6 箇所目の
/// 複製になり、次の誰かが「片方にだけ足す」を繰り返す。
///
/// ⚠️ ここに入れないもの:
/// - 楽観的更新 / ロールバック（notifier の内部状態なので呼び出し側の責任）
/// - PostHog の `habit_completed` / `todo_completed`
///   （経路ごとにイベント名が違い、**カレンダー経路は元々送っていない**。
///   ここで一律に送ると FEAT-531 の計測 baseline が黙って変わる）
/// - `ScaffoldMessenger` を使う SnackBar（`context` が要るので呼び出し側）
Future<void> applyHabitLogResult(
  ProviderReader read,
  HabitLogResult result, {
  AppLocalizations? l10n,
}) async {
  // ── EXP トースト ────────────────────────────────────────────────────
  if (result.expGain > 0) {
    read(rewardToastProvider.notifier).state = HabitReward(
      expGain:       result.expGain,
      bonusExp:      result.bonusExp,
      diamondEarned: result.diamondEarned,
    );
  }

  // ── レベルアップ ────────────────────────────────────────────────────
  if (result.leveledUp) {
    read(levelUpNotifierProvider.notifier).state = result.newLevel;
    read(levelUpAutoAllocationsProvider.notifier).state = result.autoAllocations;
    // 【FEAT-379】結晶付与サマリー（ダイアログ表示に使う）
    if (result.crystalsAwarded.isNotEmpty) {
      read(levelUpCrystalsProvider.notifier).state = result.crystalsAwarded;
    }
  }

  // ── 復帰（休息日なのに達成した）────────────────────────────────────
  if (result.isComeback) {
    read(comebackNotifierProvider.notifier).state = true;
  }

  // 【FEAT-131】自動シールド通知
  if (result.autoShieldType != null) {
    read(autoShieldNotifierProvider.notifier).state = result.autoShieldType;
  }

  // 【FEAT-314】7 / 14 / 21 / ... 日達成節目のサビ口調トースト + 5💎 誘導。
  // streakDiamondDays が non-null = Backend 側で実付与済（冪等チェック通過）。
  final streakDays = result.streakDiamondDays;
  if (streakDays != null) {
    ToastCenter.showSuccess(
      l10n?.habitProviderStreakMilestoneSabi_message(streakDays) ??
          '$streakDays days in a row — splendid. Here are +5 Diamonds for you. 🪶',
    );
  }

  // 【FEAT-398】日次 EXP 閾値到達直後 → サビ口調トースト（1 日 1 回限定）
  if (result.dailyThrottleTriggered) {
    await maybeShowExpThrottleSabiToast(l10n);
  }

  // 【FEAT-420】予約していたストリーク保護が今回の達成で消費された場合のみ
  if (result.streakProtectionPendingConsumed) {
    ToastCenter.showSuccess(
      result.streakProtectionMessage ??
          (l10n?.habitProviderStreakProtectionSabi_message ??
              'One streak shield has been used. 🪶'),
    );
  }

  // ── 以下 4 つが「Backend で配布済み」= 落とすと二度と出ないもの ────────

  // 【FEAT-433 → FEAT-438 ポップアップ昇格】当月 21 日達成で SSR 確定チケット
  if (result.monthlyTicketAwarded) {
    read(monthlyTicketAwardedNotifierProvider.notifier).state = true;
  }
  // 【BUG-122】その日初回タスク達成ボーナス（7 日カレンダー + スタンプ演出）
  if (result.todayLoginBonus != null) {
    read(pendingLoginBonusProvider.notifier).state = result.todayLoginBonus;
  }
  // 【FEAT-452】当日 3 回目の達成でフレンドプレゼント popup 候補
  if (result.friendGiftCandidate != null) {
    read(friendGiftCandidateProvider.notifier).state =
        FriendGiftCandidate.fromJson(result.friendGiftCandidate!);
  }
  // 【FEAT-479】その日初回達成でパズルピース (grey) 付与
  if (result.puzzlePieceAwarded != null) {
    read(puzzlePieceAwardedProvider.notifier).state =
        PuzzlePieceAwarded.fromJson(result.puzzlePieceAwarded!);
  }
}

/// タイムライン予定の完了レスポンスを provider に流す。
///
/// `TimelineReward` は `HabitLogResult` とは**別のモデル**（レベルアップも
/// streak も持たない）なので関数を分けている。**落とすと二度と出ない 3 つ**
/// （ログインボーナス / フレンドギフト / かけら）は同じなので、
/// **同じファイルに置いて並べて見えるようにしてある**。
///
/// ⚠️ 予定時刻 ±15 分ボーナス（FEAT-419）の SnackBar は `context` が要るので
/// 呼び出し側に残す。
void applyTimelineReward(ProviderReader read, TimelineReward reward) {
  if (reward.expGain > 0) {
    read(rewardToastProvider.notifier).state = HabitReward(
      expGain:       reward.expGain,
      bonusExp:      0,
      diamondEarned: reward.diamondEarned,
    );
  }
  // 【BUG-122】
  if (reward.todayLoginBonus != null) {
    read(pendingLoginBonusProvider.notifier).state = reward.todayLoginBonus;
  }
  // 【FEAT-452】
  if (reward.friendGiftCandidate != null) {
    read(friendGiftCandidateProvider.notifier).state =
        FriendGiftCandidate.fromJson(reward.friendGiftCandidate!);
  }
  // 【FEAT-479】
  if (reward.puzzlePieceAwarded != null) {
    read(puzzlePieceAwardedProvider.notifier).state =
        PuzzlePieceAwarded.fromJson(reward.puzzlePieceAwarded!);
  }
}

/// 【FEAT-398】日次 EXP 閾値到達時のサビ口調トースト（1 日 1 回限定）。
///
/// SharedPreferences に「最終表示日」を保存し、同日 2 回目以降は出さない。
/// 習慣 / タイムライン 両経路が呼ぶため共通 utility。
@visibleForTesting
Future<void> maybeShowExpThrottleSabiToast(AppLocalizations? l10n) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    const key = 'last_exp_throttle_snackbar_shown_date';
    final today = DateTime.now();
    final todayStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final lastShown = prefs.getString(key);
    if (lastShown == todayStr) return;   // 同日 2 回目以降はスキップ
    await prefs.setString(key, todayStr);
    // 【FEAT-408】"上限 → 打ち止め" フレームから "上澄み → 余録" フレームに変更。
    // 旧:「十分に積み上がりましたね」= 達成の打ち止めを示唆し、パワーユーザーへの
    //     "もう十分" メッセージとして誤読される可能性があった。
    // 新:「ここから先はおまけのご褒美」= 達成欲を否定せず余録フレームで伝える。
    // サビ口調規則 (〜ですよ / 〜ましたね / 🪶 / 感嘆符なし) 準拠。
    ToastCenter.showSuccess(
      l10n?.habitProviderExpThrottleSabi_message ??
          "You've done well today. From here on, think of it as bonus rewards. 🪶",
    );
  } catch (e, st) {
    debugPrint('[apply_completion_result.maybeShowExpThrottleSabiToast] failed: $e\n$st');
  }
}
