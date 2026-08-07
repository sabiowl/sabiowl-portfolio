import 'package:flutter/foundation.dart';                    // debugPrint
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 【FEAT-398】EXP throttle SnackBar 1日1回制御
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/analytics/posthog_service.dart';  // FEAT-200
import '../../../core/api/api_client.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/toast_center.dart';            // FEAT-314
import '../../battle/models/weapon_info.dart';  // 【FEAT-326】WeaponInfo (装備変更 Optimistic UI)
import '../../calendar/providers/calendar_provider.dart';  // FEAT-280: invalidateCalendarBootstrapCache
import '../../social/models/social_models.dart';  // 【FEAT-452】FriendGiftCandidate
import '../../puzzle_world/models/puzzle_world.dart';  // 【FEAT-479】PuzzlePieceAwarded
import '../../puzzle_world/providers/puzzle_world_provider.dart';  // 【FEAT-479】puzzlePieceAwardedProvider
import '../../social/providers/social_provider.dart';  // 【FEAT-452】friendGiftCandidateProvider
import '../models/habit.dart' show Habit, HabitReward, HabitsSummary, PendingPlayerReward;
import '../models/player.dart';
import '../providers/home_bootstrap_provider.dart';  // FEAT-280: invalidateHomeBootstrapCache
import '../services/habits_service.dart';

part 'habits_provider.g.dart';

// 【FEAT-264】FEAT-213 のリファクタ取りこぼし解消（2026-05-21、機能レビュー指摘）。
//
// 旧実装は FEAT-201 時代の 4 値（'運動' / '学習' / '健康' / 'メンタル'）を
// `_kCategoriesWithStatBonus` Set で持ち、それ以外を「stat bonus 0」として
// 楽観 EXP を過少評価していた。しかし真実値は backend/api/constants.py の
// FEAT-213 で **11 カテゴリすべてが必ず 6 stat のいずれかにマップ** される
// 設計に進化済（migration 0066）。
//
// さらに 'メンタル' は migration 0066 で '精神' にリネーム済 = dead string。
// 結果として 7 カテゴリ（体力/美容/仕事/創造/休息/精神/社交/その他）で
// 「楽観反映 → 確定で +5〜10 EXP 増加」の二段カウント UX バグが発生していた。
//
// → 本 FEAT で `_kCategoriesWithStatBonus` Set 自体を撤去し、`_estimateExpGain`
//   は全カテゴリで stat bonus 期待値（base × 0.25 = 中央値）を加算する。
//   FEAT-213 の真実値「全カテゴリが必ず stat にマップされる」前提と整合。

@riverpod
HabitsService habitsService(Ref ref) {
  return HabitsService(ref.watch(apiClientProvider));
}

// ── レベルアップ通知（null = 通知なし）─────────────────────
// UI 側で ref.listen して表示後に null に戻す
final levelUpNotifierProvider = StateProvider<int?>((ref) => null);

// ── レベルアップ時の自動配分結果（{ stat名: pt数 } / 空 = 配分なし）────
// ダイアログ表示後に空マップにリセットする
final levelUpAutoAllocationsProvider = StateProvider<Map<String, int>>(
  (ref) => const {},
);

// ── レベルアップ時の結晶付与サマリー（{ crystal_key: count } / 空 = 結晶なし）─────
// 【FEAT-379 (2026-05-29)】ダイアログ表示後に空マップにリセットする
final levelUpCrystalsProvider = StateProvider<Map<String, int>>(
  (ref) => const {},
);

// ── コンバック通知（休息日明けの復帰）─────────────────────
// UI 側で ref.listen して表示後に false に戻す
final comebackNotifierProvider = StateProvider<bool>((ref) => false);

// ── FEAT-131: 自動シールド通知（'rest_day' | 'fruit' | null）──
// UI 側で ref.listen して SnackBar 表示後に null に戻す
final autoShieldNotifierProvider = StateProvider<String?>((ref) => null);

// ── リワードトースト（習慣達成時の EXP / ダイヤ表示）──────
// UI 側で ref.listen してトースト表示後に null に戻す
final rewardToastProvider = StateProvider<HabitReward?>((ref) => null);

// ── 楽観的プレイヤー差分（EXP/ダイヤの暫定加算値）───────────────────────
// null = 通常状態。_buildPlayerHeader がこれを加算して表示する。
final pendingPlayerRewardProvider =
    StateProvider<PendingPlayerReward?>((ref) => null);

/// 【BUG-122 (2026-06-14)】「その日初回タスク達成」ボーナス保留 provider。
/// `_apply_plus` 経路 (habit count / checklist / timeline complete) で API が
/// `today_login_bonus` を返したとき、本 provider に値を入れる。Home / Habits 系
/// の Consumer がこれを監視して `LoginBonusCalendarDialog` を表示後 null クリア。
/// 値の構造: {amount, days_count, granted_daily_tickets, granted_weekly_tickets}
final pendingLoginBonusProvider =
    StateProvider<Map<String, dynamic>?>((ref) => null);

// ── 習慣リストのフィルター ──────────────────────────────────
// null    = すべて（フィルターなし）
// 'daily' = 今日の習慣 / 'weekly' = 今週 / 'monthly' = 今月
final habitFilterProvider = StateProvider<String?>((ref) => null);

// ── カテゴリフィルター ─────────────────────────────────────
// null = すべてのカテゴリ / '運動' / '学習' / '健康' / 'メンタル' 等
final habitCategoryFilterProvider = StateProvider<String?>((ref) => null);

// ── タイプフィルター (BUG-134、2026-06-17) ────────────────
// null = すべて / 'count' = カウント型 / 'checklist' = チェックリスト型
// ToDo (habitType='todo') は home_page 側で別軸 (isTodo) で除外しているため、
// 本フィルタの選択肢には含めない (Habit リスト = 非 ToDo の count/checklist のみ)。
final habitTypeFilterProvider = StateProvider<String?>((ref) => null);

// ── 月間 21 日達成 SSR 確定チケット獲得シグナル (FEAT-438、2026-06-17) ──────
// FEAT-433 で Backend 実装済の SSR 確定チケット配布通知を、SnackBar から
// ポップアップ (MonthlyTicketAwardedDialog) に昇格させるための one-shot 通知。
// true 設定後、RestackApp の global listener が showDialog → 表示完了後に
// false に戻すフロー。複数画面で listen が同時 mount される ShellRoute 構造
// でも、edge trigger + 即時 reset で多重発火を構造的に防ぐ。
final monthlyTicketAwardedNotifierProvider = StateProvider<bool>((ref) => false);

// ── Player ────────────────────────────────────────────────────
@riverpod
class PlayerNotifier extends _$PlayerNotifier {
  @override
  Future<Player> build() async {
    // FEAT-188: ゲスト時もサーバー側に PlayerProfile が存在するため、
    // 通常ユーザー時と同じく `/player/` を叩く（ゲストトークンが自動付与される）。
    final player = await ref.watch(habitsServiceProvider).fetchPlayer();
    // FCMトークンをバックグラウンドで登録（失敗しても無視）
    _tryRegisterFcmToken();
    // FEAT-200: PlayerProfile.id 確定タイミングで PostHog の distinct_id を同期する。
    // ゲスト/認証済みの判定は ApiClient のトークン保有状況から推定（ユーザートークンがあれば認証済み）。
    // 認証完了直後は startAsGuest 経由の identify から更新され、user_properties.is_guest が
    // false に切り替わる。失敗しても player 取得自体は止めない。
    _tryIdentifyPosthog(player.id);
    return player;
  }

  Future<void> _tryIdentifyPosthog(int playerId) async {
    if (playerId <= 0) return;
    try {
      final apiClient = ref.read(apiClientProvider);
      final hasUserToken = (await apiClient.getToken())?.isNotEmpty ?? false;
      await PosthogService.instance.identify(playerId, isGuest: !hasUserToken);
    } catch (_) {
      // silent: PostHog 識別失敗はアプリ機能に影響させない
    }
  }

  Future<void> _tryRegisterFcmToken() async {
    final token = NotificationService.fcmToken;
    if (token == null || token.isEmpty) return;
    try {
      await ref.read(habitsServiceProvider).patchPlayer({'fcm_token': token});
    } catch (_) {
      // silent: FCMトークン登録失敗はアプリを止めない
    }
  }

  Future<void> refresh() async => ref.invalidateSelf();

  /// ホームブートストラップから Player を直接注入（API 呼び出し不要）
  void setFromBootstrap(Player p) {
    state = AsyncData(p);
  }

  /// プレイモードを切り替える
  Future<void> switchMode(String mode) async {
    await ref.read(habitsServiceProvider).patchPlayer({'mode': mode});
    ref.invalidateSelf();
  }

  /// リマインダー設定を保存して Player キャッシュを更新する
  Future<void> updateReminderSettings({
    required bool enabled,
    String? reminderTime, // 'HH:MM' or null
  }) async {
    await ref.read(habitsServiceProvider).patchPlayer({
      'reminder_enabled': enabled,
      'reminder_time': reminderTime,
    });
    ref.invalidateSelf();
  }

  /// 【FEAT-257】Google カレンダー push トグルを更新する。
  /// Optimistic UI（PATCH 完了前にローカル state を即更新）+ invalidate で再同期。
  Future<void> setGcalPushEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current != null) {
      // 【2026-08-02 hotfix】旧実装は Player を全フィールド手書きで詰め替えており、
      // 新フィールド追加時に落ちたものが既定値へ silent に戻る構造だった。
      // copyWith に統一 (詳細は player.dart の copyWith docstring)。
      state = AsyncData(current.copyWith(
        gcalPushEnabled: enabled,
      ));
    }
    await ref.read(habitsServiceProvider).patchPlayer({
      'gcal_push_enabled': enabled,
    });
    ref.invalidateSelf();
  }

  /// 【FEAT-273】タイムライン予定の +15 分未完了リマインダー有効フラグを更新する。
  /// setGcalPushEnabled と同じ Optimistic UI パターン。
  Future<void> setTimelineUncompletedReminderEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current != null) {
      // 【2026-08-02 hotfix】旧実装は Player を全フィールド手書きで詰め替えており、
      // 新フィールド追加時に落ちたものが既定値へ silent に戻る構造だった。
      // copyWith に統一 (詳細は player.dart の copyWith docstring)。
      state = AsyncData(current.copyWith(
        timelineUncompletedReminderEnabled: enabled,
      ));
    }
    await ref.read(habitsServiceProvider).patchPlayer({
      'timeline_uncompleted_reminder_enabled': enabled,
    });
    ref.invalidateSelf();
  }

  /// 【FEAT-377 (2026-05-29)】ストリーク自動保護 ON/OFF を更新する。
  /// setTimelineUncompletedReminderEnabled と同じ Optimistic UI パターン。
  Future<void> setStreakProtectionAutoEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current != null) {
      // 【2026-08-02 hotfix】旧実装は Player を全フィールド手書きで詰め替えており、
      // freeMemoEnabled 等 9 フィールドを落としていた (トグルすると仮メモ機能が
      // 一瞬 OFF に見える不具合)。copyWith に統一して構造的に再発を防ぐ。
      state = AsyncData(current.copyWith(
        streakProtectionAutoEnabled: enabled,
        // 【FEAT-420 Pre-mortem S2】自動保護を ON にしたら pending 予約は強制クリア
        streakProtectionPending: enabled ? false : current.streakProtectionPending,
      ));
    }
    await ref.read(habitsServiceProvider).patchPlayer({
      'streak_protection_auto_enabled': enabled,
    });
    ref.invalidateSelf();
  }

  /// 【FEAT-493 (2026-07-25)】フリーメモ機能 opt-in/out を切り替える。
  /// setStreakProtectionAutoEnabled と同じ Optimistic UI パターン。
  Future<void> setFreeMemoEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current != null) {
      // 【2026-08-02 hotfix】旧実装は Player を全フィールド手書きで詰め替えており、
      // 新フィールド追加時に落ちたものが既定値へ silent に戻る構造だった。
      // copyWith に統一 (詳細は player.dart の copyWith docstring)。
      state = AsyncData(current.copyWith(
        freeMemoEnabled: enabled,
      ));
    }
    await ref.read(habitsServiceProvider).patchPlayer({'free_memo_enabled': enabled});
    ref.invalidateSelf();
  }

  /// 【FEAT-420 (2026-06-10)】ストリーク保護の予約 ON/OFF を切り替える。
  /// value=true → /streak-protection/use/ (予約設定)
  /// value=false → /streak-protection/cancel/ (予約取消)
  /// 失敗時は DioException を rethrow (呼び出し側で catch + SnackBar 表示)。
  Future<void> setStreakProtectionPending(bool value) async {
    if (value) {
      await ref.read(habitsServiceProvider).useStreakProtection();
    } else {
      await ref.read(habitsServiceProvider).cancelStreakProtection();
    }
    ref.invalidateSelf();
  }

  /// 【FEAT-326】装備中の武器を切り替える (PartyEditDialog の WeaponSelectSheet から呼出)。
  ///
  /// Optimistic UI: 即座に `equippedWeapon` を `localWeapon` で上書き → API 呼出
  /// 成功時は invalidateSelf で確定。失敗時は state をロールバック + bool 返却。
  ///
  /// `weaponId` は WeaponMaster.id (PlayerWeapon.weapon_id ではない)。
  /// `localWeapon` は Optimistic 反映用 (Backend 応答前の即時 UI 更新)。
  Future<bool> setEquippedWeapon(int weaponId, {required WeaponInfo localWeapon}) async {
    final current = state.valueOrNull;
    if (current == null) return false;

    final original = current.equippedWeapon;

    // Optimistic 反映 (localWeapon を equippedWeapon に上書き)
    state = AsyncData(_clonePlayerWithWeapon(current, localWeapon));

    try {
      final equipped = await ref.read(habitsServiceProvider).patchEquippedWeapon(weaponId);
      // 成功 → Backend 応答で再構築 (id/key/name/atk_bonus が確定)
      final confirmed = WeaponInfo.fromJson(equipped);
      state = AsyncData(_clonePlayerWithWeapon(current, confirmed));
      // 装備変更後は他経路 (バトル damage / SWR) でも最新値を反映させるため invalidate
      ref.invalidateSelf();
      // 【FEAT-327】playerWeaponsProvider の is_equipped flag を最新化
      // (EquipmentSelectionOverlay が次回開いた時に新装備が「装備中」表示される)
      ref.invalidate(playerWeaponsProvider);
      return true;
    } catch (e, st) {
      debugPrint('[PlayerNotifier.setEquippedWeapon] failed: $e\n$st');
      // 失敗 → ロールバック
      state = AsyncData(_clonePlayerWithWeapon(current, original));
      return false;
    }
  }

  /// `Player` インスタンスを equippedWeapon だけ差し替えて clone するヘルパー
  /// (Optimistic UI と rollback で同じパターンを再利用するため抽出)。
  static Player _clonePlayerWithWeapon(Player p, WeaponInfo? weapon) {
    return Player(
      id:                p.id,
      name:              p.name,
      gender:            p.gender,
      level:             p.level,
      currentExp:        p.currentExp,
      maxExp:            p.maxExp,
      allocatablePoints: p.allocatablePoints,
      diamonds:          p.diamonds,
      diamondsTotal:     p.diamondsTotal,
      friendId:          p.friendId,
      dailyTickets:      p.dailyTickets,
      weeklyTickets:     p.weeklyTickets,
      monthlyTickets:    p.monthlyTickets,
      reminderEnabled:   p.reminderEnabled,
      reminderTime:      p.reminderTime,
      activeCharacter:   p.activeCharacter,
      activeJob:         p.activeJob,
      mode:              p.mode,
      createdAt:         p.createdAt,
      gcalPushEnabled:   p.gcalPushEnabled,
      timelineUncompletedReminderEnabled:
          p.timelineUncompletedReminderEnabled,
      battleCharges:     p.battleCharges,
      equippedWeapon:    weapon,
    );
  }
}

// ── サマリー ──────────────────────────────────────────────────
@riverpod
Future<HabitsSummary> habitsSummary(Ref ref) async {
  // FEAT-188: ゲスト時もサーバー集計を叩く（GuestTokenAuthentication 対応済）。
  return ref.watch(habitsServiceProvider).fetchSummary();
}

// ── 【FEAT-474】pagination side state ─────────────────────────
/// 次ページの cursor 文字列。空文字 = 次ページなし。
final habitsNextCursorProvider = StateProvider<String>((ref) => '');

/// まだ続きがあるか。
final habitsHasMoreProvider = StateProvider<bool>((ref) => false);

/// loadMore() 実行中フラグ。
final habitsIsLoadingMoreProvider = StateProvider<bool>((ref) => false);

// ── アクティブ習慣一覧 ─────────────────────────────────────────
@riverpod
class HabitsNotifier extends _$HabitsNotifier {
  /// 処理中の habitId セット（連打による二重送信を防止）
  final _inFlight = <int>{};

  @override
  Future<List<Habit>> build() async {
    // FEAT-188: ゲスト分岐削除。ゲストトークンも認証ヘッダーに自動付与される。
    try {
      final page = await ref.watch(habitsServiceProvider).fetchHabits();
      ref.read(habitsNextCursorProvider.notifier).state = page.nextCursor;
      ref.read(habitsHasMoreProvider.notifier).state    = page.hasMore;
      return page.results;
    } catch (e, st) {
      debugPrint('habitsNotifierProvider.build() failed: $e\n$st');
      rethrow;
    }
  }

  /// 【FEAT-474】続きを追加取得してリストに append する。
  Future<void> loadMore() async {
    if (ref.read(habitsIsLoadingMoreProvider)) return;
    if (!ref.read(habitsHasMoreProvider)) return;
    final cursor = ref.read(habitsNextCursorProvider);
    ref.read(habitsIsLoadingMoreProvider.notifier).state = true;
    try {
      final page = await ref.read(habitsServiceProvider).fetchHabits(cursor: cursor);
      state = state.whenData((current) => [...current, ...page.results]);
      ref.read(habitsNextCursorProvider.notifier).state = page.nextCursor;
      ref.read(habitsHasMoreProvider.notifier).state    = page.hasMore;
    } catch (e, st) {
      debugPrint('[HabitsNotifier.loadMore] failed: $e\n$st');
    } finally {
      ref.read(habitsIsLoadingMoreProvider.notifier).state = false;
    }
  }

  void _refreshRelated() {
    ref.invalidate(habitsSummaryProvider);
    ref.invalidate(playerNotifierProvider);
    _invalidateSwrCaches();
  }

  /// 【FEAT-280 Pre-mortem #4】習慣リスト or プレイヤー状態を変更する write 操作後に呼ぶ。
  /// ホーム / カレンダーキャッシュを invalidate して、次回 watch で fresh 取得を強制する
  /// （stale データが画面に残らない）。fire-and-forget で進行する（write を遅らせない）。
  void _invalidateSwrCaches() {
    // ignore: discarded_futures
    invalidateHomeBootstrapCache(ref);
    // ignore: discarded_futures
    invalidateCalendarBootstrapCache(ref);
  }

  /// ホームブートストラップから習慣リストを直接注入（API 呼び出し不要）
  /// 【FEAT-474】hasMore フラグも同時に設定する。
  void setFromBootstrap(List<Habit> habits, {bool hasMore = false}) {
    state = AsyncData(habits);
    ref.read(habitsHasMoreProvider.notifier).state    = hasMore;
    ref.read(habitsNextCursorProvider.notifier).state = '';
  }

  // 習慣を一覧から更新
  void _updateInList(Habit updated) {
    state = state.whenData(
      (habits) => habits.map((h) => h.id == updated.id ? updated : h).toList(),
    );
  }

  // カウント +1
  Future<void> incrementCount(int habitId, {AppLocalizations? l10n}) async {
    if (_inFlight.contains(habitId)) return; // 二重送信ガード
    _inFlight.add(habitId);

    // 【BUG-71 fix 2026-05-27】try-finally の **外側** にあった `firstWhere` の
    // `StateError` (habit not found in state) で `_inFlight.remove(habitId)` が
    // 実行されず、以降のタップが永久に line 内 contains() 早期 return される
    // 構造的バグを構造解消。`_inFlight.add` 直後にすべてのロジックを try で包み、
    // どこで throw されても finally で必ず `_inFlight.remove` が走るようにする。
    // 再発防止契約テスト: `mobile/test/habits/habit_increment_inflight_test.dart`
    final Habit habit;
    final int estimated;
    try {
      // ① 楽観的更新: 難易度から EXP を推定してローカル即反映
      final habits = state.valueOrNull ?? [];
      habit = habits.firstWhere(
        (h) => h.id == habitId,
        orElse: () => throw StateError('habit not found'),
      );
      estimated = _estimateExpGain(habit.difficulty, habit.category);
      ref.read(pendingPlayerRewardProvider.notifier).state =
          PendingPlayerReward(expDelta: estimated, diamondDelta: 0);

      // ② 習慣カード楽観的更新: API 完了前にカード表示を即座に更新
      final optimistic = habit.optimisticIncrement();
      _updateInList(optimistic);
    } catch (_) {
      // 【BUG-71 fix】firstWhere の StateError 等を catch、_inFlight を即時解放してから rethrow
      _inFlight.remove(habitId);
      rethrow;
    }

    try {
      // 【BUG-137 (2026-06-17)】race ガード: player 再フェッチ中 (valueOrNull=null)
      // の場合、`?? 0` で 0 にフォールバックする。Lv.1 から始まるプレイヤーにとって
      // 0 は実質的に「未知」sentinel。HabitLogResult.leveledUp ゲッターで
      // `prevLevel > 0` チェックにより Lv.UP 誤発火を構造的に遮断 (habit.dart:379)。
      final prevLevel = ref.read(playerNotifierProvider).valueOrNull?.level ?? 0;
      final result = await ref
          .read(habitsServiceProvider)
          .incrementCount(habitId, prevLevel: prevLevel);

      _updateInList(result.habit); // サーバー確定値で上書き
      _refreshRelated();

      // ③ 確定値に切り替え（差分プロバイダーをクリア）
      ref.read(pendingPlayerRewardProvider.notifier).state = null;

      // FEAT-200: count 型習慣の完了 / ToDo の完了をトラッキング。
      // habit_type=todo の場合は todo_completed、それ以外は habit_completed。
      await PosthogService.instance.capture(
        habit.habitType == 'todo' ? 'todo_completed' : 'habit_completed',
        properties: {
          'category':   habit.category,
          'difficulty': habit.difficulty,
        },
      );

      // ④ RewardToast 表示
      if (result.expGain > 0) {
        ref.read(rewardToastProvider.notifier).state = HabitReward(
          expGain:       result.expGain,
          bonusExp:      result.bonusExp,
          diamondEarned: result.diamondEarned,
        );
      }

      if (result.leveledUp) {
        ref.read(levelUpNotifierProvider.notifier).state = result.newLevel;
        ref.read(levelUpAutoAllocationsProvider.notifier).state = result.autoAllocations;
        // 【FEAT-379】結晶付与サマリーを同時セット (ダイアログ表示に使う)
        if (result.crystalsAwarded.isNotEmpty) {
          ref.read(levelUpCrystalsProvider.notifier).state = result.crystalsAwarded;
        }
      }
      if (result.isComeback) {
        ref.read(comebackNotifierProvider.notifier).state = true;
      }
      // FEAT-131: 自動シールド通知
      if (result.autoShieldType != null) {
        ref.read(autoShieldNotifierProvider.notifier).state = result.autoShieldType;
      }
      // 【FEAT-314】 7 / 14 / 21 / ... 日達成節目のサビ口調トースト + +5💎 誘導
      // streakDiamondDays が non-null = Backend 側で実付与済（冪等チェック通過）。
      final streakDays = result.streakDiamondDays;
      if (streakDays != null) {
        ToastCenter.showSuccess(
          l10n?.habitProviderStreakMilestoneSabi_message(streakDays) ??
              '$streakDays days in a row — splendid. Here are +5 Diamonds for you. 🪶',
        );
      }
      // 【FEAT-398】日次 EXP 閾値到達直後 → サビ口調 SnackBar (1 日 1 回限定)
      if (result.dailyThrottleTriggered) {
        await _maybeShowExpThrottleSabiSnackBar(l10n);
      }
      // 【FEAT-420 (2026-06-10)】予約していたストリーク保護が今回の達成で消費された場合のみ表示
      if (result.streakProtectionPendingConsumed) {
        ToastCenter.showSuccess(
          result.streakProtectionMessage ??
              (l10n?.habitProviderStreakProtectionSabi_message ??
                  'One streak shield has been used. 🪶'),
        );
      }
      // 【FEAT-433 (2026-06-13) → FEAT-438 (2026-06-17) ポップアップ昇格】
      // 当月 21 日達成で SSR 確定チケットを配布した場合、provider state を true に。
      // RestackApp の global listener が showDialog で MonthlyTicketAwardedDialog
      // を表示する (旧 SnackBar は廃止)。
      if (result.monthlyTicketAwarded) {
        ref.read(monthlyTicketAwardedNotifierProvider.notifier).state = true;
      }
      // 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナスを保留 provider に注入。
      // Home / Habits 系の Consumer がこれを watch して LoginBonusCalendarDialog を表示。
      if (result.todayLoginBonus != null) {
        ref.read(pendingLoginBonusProvider.notifier).state =
            result.todayLoginBonus;
      }
      // 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント popup
      // 候補を friendGiftCandidateProvider に set。FriendGiftPopupListener が watch
      // して non-null 時に確認ダイアログを表示する。
      if (result.friendGiftCandidate != null) {
        ref.read(friendGiftCandidateProvider.notifier).state =
            FriendGiftCandidate.fromJson(result.friendGiftCandidate!);
      }
      // 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
      // puzzlePieceAwardedProvider に set → PuzzlePieceListener が watch して
      // PuzzlePieceOverlayModal を発火する。
      if (result.puzzlePieceAwarded != null) {
        ref.read(puzzlePieceAwardedProvider.notifier).state =
            PuzzlePieceAwarded.fromJson(result.puzzlePieceAwarded!);
      }
    } catch (_) {
      // ⑤ ロールバック: 楽観的更新前の状態に戻す
      _updateInList(habit);
      ref.read(pendingPlayerRewardProvider.notifier).state = null;
      ref.read(playerNotifierProvider.notifier).refresh();
      rethrow;
    } finally {
      _inFlight.remove(habitId);
    }
  }

  /// 【FEAT-398】日次 EXP 閾値到達時のサビ口調 SnackBar (1 日 1 回限定)。
  ///
  /// SharedPreferences に「最終表示日」を保存し、同日に 2 回以上表示されないよう抑制する。
  /// 習慣 / タイムライン 両経路が呼び出すため、共通 utility として定義。
  Future<void> _maybeShowExpThrottleSabiSnackBar(AppLocalizations? l10n) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const key = 'last_exp_throttle_snackbar_shown_date';
      final today = DateTime.now();
      final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final lastShown = prefs.getString(key);
      if (lastShown == todayStr) return;  // 同日 2 回目以降はスキップ
      await prefs.setString(key, todayStr);
      // 【FEAT-408 (2026-06-01)】"上限→打ち止め" フレームから "上澄み → 余録" フレームに変更。
      // 旧: 「十分に積み上がりましたね」= 達成の打ち止めを示唆、パワーユーザーへの
      //     "もう十分" メッセージとして誤読される可能性あり。
      // 新: 「ここから先はおまけのご褒美」= 達成欲を否定せず余録フレームで伝える。
      // サビ口調規則 (〜ですよ / 〜ましたね / 🪶 / 感嘆符なし) 準拠。
      ToastCenter.showSuccess(
        l10n?.habitProviderExpThrottleSabi_message ??
            "You've done well today. From here on, think of it as bonus rewards. 🪶",
      );
    } catch (e, st) {
      debugPrint('[HabitsNotifier._maybeShowExpThrottleSabiSnackBar] failed: $e\n$st');
    }
  }

  // ── EXP 推定（楽観的更新用・正確な値は API レスポンス後に確定）───────────
  // サーバの実加算式（backend/api/views/habits.py の HabitCountView 参照）:
  //   total = base(difficulty別) + bonus_exp
  //     bonus_exp = round(base × min(stat.level × 0.05, 0.50))  ← Stat ボーナス 0〜50%
  //              + round(base × 0.20)                           ← 冒険モード時のみ
  //
  // P1-2 (functional review): 楽観値が base + 冒険のみだと「楽観反映 → 確定で増加」の
  // 二段カウントが発生する。Stat ボーナスの**期待値（中央値 25%）**を係数で混ぜ、
  // 誤差を中レベルプレイヤーで ±5% 以内に収める。
  //
  // 【FEAT-264】FEAT-213 真実値準拠: 全 11 カテゴリ（運動/学習/仕事/体力/美容/健康/
  // 精神/創造/社交/休息/その他）は必ず 6 stat のいずれかにマップされるため、
  // `hasStat` 分岐は撤去し、全カテゴリで stat bonus 期待値を加算する。
  // category 引数は将来 CATEGORY_STAT_MAP 経由で個別に補正する余地を残すため保持。
  int _estimateExpGain(String difficulty, String category) {
    final base = switch (difficulty) {
      'easy'      => 20,
      'normal'    => 30,
      'hard'      => 40,
      'legendary' => 60,
      _           => 20,
    };
    final player = ref.read(playerNotifierProvider).valueOrNull;
    final isAdventure = player?.mode == 'adventure';

    // 【FEAT-264】Stat ボーナス期待値（中央値 25%）— 全カテゴリ共通
    // FEAT-213 で全 11 カテゴリが必ず stat にマップされる前提（migration 0066）
    final statBonus = (base * 0.25).round();

    // 冒険モードボーナス
    final adventureBonus = isAdventure ? (base * 0.20).round() : 0;

    return base + statBonus + adventureBonus;
  }

  // カウント -1（取り消し）
  Future<void> decrementCount(int habitId) async {
    if (_inFlight.contains(habitId)) return; // 二重送信ガード
    _inFlight.add(habitId);

    // 【BUG-71 fix 2026-05-27】incrementCount と同じ構造的修正 (firstWhere StateError
    // で _inFlight 永久残置バグの再発防止)。
    final Habit habit;
    try {
      final habits = state.valueOrNull ?? [];
      habit = habits.firstWhere(
        (h) => h.id == habitId,
        orElse: () => throw StateError('habit not found'),
      );

      // ① 楽観的反映（マイナス方向）
      final estimated = _estimateExpGain(habit.difficulty, habit.category);
      ref.read(pendingPlayerRewardProvider.notifier).state =
          PendingPlayerReward(expDelta: -estimated, diamondDelta: 0);
      _updateInList(habit.optimisticDecrement());
    } catch (_) {
      _inFlight.remove(habitId);
      rethrow;
    }

    try {
      final updated =
          await ref.read(habitsServiceProvider).decrementCount(habitId);
      _updateInList(updated);
      ref.read(pendingPlayerRewardProvider.notifier).state = null;
      _refreshRelated();
    } catch (_) {
      // ロールバック: 楽観的更新前の状態に戻す
      _updateInList(habit);
      ref.read(pendingPlayerRewardProvider.notifier).state = null;
      ref.read(playerNotifierProvider.notifier).refresh();
      rethrow;
    } finally {
      _inFlight.remove(habitId);
    }
  }

  // チェックリストトグル
  Future<void> toggleChecklistItem(int habitId, int itemId) async {
    if (_inFlight.contains(habitId)) return; // 二重送信ガード
    _inFlight.add(habitId);

    // 【BUG-71 fix 2026-05-27】incrementCount と同じ構造的修正。
    final Habit habit;
    try {
      final habits = state.valueOrNull ?? [];
      habit = habits.firstWhere(
        (h) => h.id == habitId,
        orElse: () => throw StateError('habit not found'),
      );

      // ① 楽観的反映: チェックボックスを即座に反転
      _updateInList(habit.optimisticToggleChecklistItem(itemId));
    } catch (_) {
      _inFlight.remove(habitId);
      rethrow;
    }

    try {
      final prevLevel =
          ref.read(playerNotifierProvider).valueOrNull?.level ?? 0;
      final result = await ref
          .read(habitsServiceProvider)
          .toggleChecklistItem(habitId, itemId, prevLevel: prevLevel);
      _updateInList(result.habit);
      _refreshRelated();
      // FEAT-200: チェックリスト型習慣の完了をトラッキング（個別アイテムのトグルではなく、
      // EXP が加算された = 「達成」と判定できるタイミングで送る）。
      if (result.expGain > 0) {
        await PosthogService.instance.capture('habit_completed', properties: {
          'category':   habit.category,
          'difficulty': habit.difficulty,
        });
        ref.read(rewardToastProvider.notifier).state = HabitReward(
          expGain:       result.expGain,
          bonusExp:      result.bonusExp,
          diamondEarned: result.diamondEarned,
        );
      }
      if (result.leveledUp) {
        ref.read(levelUpNotifierProvider.notifier).state = result.newLevel;
        ref.read(levelUpAutoAllocationsProvider.notifier).state = result.autoAllocations;
        // 【FEAT-379】結晶付与サマリー (checklist 経路)
        if (result.crystalsAwarded.isNotEmpty) {
          ref.read(levelUpCrystalsProvider.notifier).state = result.crystalsAwarded;
        }
      }
      // 【FEAT-433 (2026-06-13) → FEAT-438 (2026-06-17) ポップアップ昇格】(checklist 経路)
      // 上記 _incrementCount と同パターン、provider state を true → RestackApp が表示
      if (result.monthlyTicketAwarded) {
        ref.read(monthlyTicketAwardedNotifierProvider.notifier).state = true;
      }
      // 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス (checklist 経路)
      if (result.todayLoginBonus != null) {
        ref.read(pendingLoginBonusProvider.notifier).state =
            result.todayLoginBonus;
      }
    } catch (_) {
      // ロールバック: 楽観的更新前の状態に戻す
      _updateInList(habit);
      ref.read(playerNotifierProvider.notifier).refresh();
      rethrow;
    } finally {
      _inFlight.remove(habitId);
    }
  }

  // シールド発動
  Future<void> activateShield(int habitId) async {
    final updated =
        await ref.read(habitsServiceProvider).activateShield(habitId);
    _updateInList(updated);
  }

  // ToDo クイック追加
  Future<void> createTodo(
    String name, {
    String priority   = 'medium',
    String difficulty = 'normal',
    String category   = '学習',   // 【FEAT-201】「その他」廃止、デフォルトを 4 値内の「学習」に
    String memo       = '',        // 【FEAT-198】ToDo 追加時にメモを渡せるようにする
  }) async {
    await ref.read(habitsServiceProvider).createHabit(
          name:       name,
          category:   category,      // FEAT-147: 仮値から実際の選択値に変更
          frequency:  'daily',
          resetCycle: 'daily',
          habitType:  'todo',
          difficulty: difficulty,
          priority:   priority,
          memo:       memo,
        );
    // FEAT-200: ToDo 作成イベント。失敗してもアプリ機能を止めない（best-effort）。
    await PosthogService.instance.capture('todo_created', properties: {
      'category':   category,
      'difficulty': difficulty,
      'priority':   priority,
      'source':     'direct',  // 【FEAT-493】フリーメモ変換経由は 'free_memo_convert'
    });
    ref.invalidateSelf();
  }

  // 習慣追加
  Future<void> createHabit({
    required String name,
    required String category,
    required String frequency,
    required String resetCycle,
    required String habitType,
    required String difficulty,
    String memo = '',
    bool isPublic = true,
    List<String> checklistItems = const [],
  }) async {
    await ref.read(habitsServiceProvider).createHabit(
          name: name,
          category: category,
          frequency: frequency,
          resetCycle: resetCycle,
          habitType: habitType,
          difficulty: difficulty,
          memo: memo,
          isPublic: isPublic,
          checklistItems: checklistItems,
        );
    // FEAT-200: 習慣作成イベント。habit_type で count/checklist を識別。
    await PosthogService.instance.capture('habit_created', properties: {
      'category':   category,
      'difficulty': difficulty,
      'habit_type': habitType,
      'source':     'direct',  // 【FEAT-493】フリーメモ変換経由は 'free_memo_convert'
    });
    ref.invalidateSelf(); // 一覧を再取得
    ref.invalidate(categoriesProvider); // 新カテゴリを即反映
    _invalidateSwrCaches(); // 【FEAT-280】キャッシュ無効化
  }

  // 習慣編集
  Future<void> updateHabit(int habitId, Map<String, dynamic> data) async {
    final updated =
        await ref.read(habitsServiceProvider).updateHabit(habitId, data);
    _updateInList(updated);
    ref.invalidate(categoriesProvider); // カテゴリ変更を即反映
    _invalidateSwrCaches(); // 【FEAT-280】キャッシュ無効化
  }

  // 習慣削除
  Future<void> deleteHabit(int habitId) async {
    await ref.read(habitsServiceProvider).deleteHabit(habitId);
    state = state.whenData(
      (habits) => habits.where((h) => h.id != habitId).toList(),
    );
    _invalidateSwrCaches(); // 【FEAT-280】キャッシュ無効化
  }

  // アーカイブ
  Future<void> archiveHabit(int habitId) async {
    await ref.read(habitsServiceProvider).archiveHabit(habitId);
    state = state.whenData(
      (habits) => habits.where((h) => h.id != habitId).toList(),
    );
    ref.invalidate(categoriesProvider); // 最後の習慣アーカイブ時にカテゴリを更新
    _invalidateSwrCaches(); // 【FEAT-280】キャッシュ無効化
  }

  // 並び替え
  Future<void> reorderHabits(List<Habit> reordered) async {
    // UI を先に更新（楽観的更新）
    state = AsyncData(reordered);
    await ref
        .read(habitsServiceProvider)
        .reorderHabits(reordered.map((h) => h.id).toList());
  }

  Future<void> refresh() async => ref.invalidateSelf();
}

// ── アーカイブ済み習慣 ─────────────────────────────────────────
@riverpod
class ArchivedHabitsNotifier extends _$ArchivedHabitsNotifier {
  @override
  Future<List<Habit>> build() async {
    // FEAT-188: ゲスト時もサーバー側にアーカイブ機能あり。
    return ref.watch(habitsServiceProvider).fetchArchivedHabits();
  }

  Future<void> restoreHabit(int habitId) async {
    await ref.read(habitsServiceProvider).restoreHabit(habitId);
    state = state.whenData(
      (habits) => habits.where((h) => h.id != habitId).toList(),
    );
    // アクティブ一覧も更新
    ref.invalidate(habitsNotifierProvider);
  }

  Future<void> refresh() async => ref.invalidateSelf();
}

// ── カテゴリ一覧（デフォルト4種 + カスタム）──────────────────
final categoriesProvider = FutureProvider<List<String>>((ref) async {
  // FEAT-188: ゲスト時もサーバー側で取得（GuestToken 認証対応済）。
  return ref.watch(habitsServiceProvider).fetchCategories();
});

// ── 【FEAT-327】所持武器全件 (EquipmentSelectionOverlay 用) ──────
/// `GET /api/player/weapons/` のラッパー。EquipmentSelectionOverlay が
/// 「現在装備中 + 所持武器一覧」を表示する際にスクロール領域に流す。
/// autoDispose で Overlay を閉じたら次回起動時に fresh fetch される。
///
/// 装備変更後 (PlayerNotifier.setEquippedWeapon 成功時) は同 Notifier 内で
/// `ref.invalidate(playerWeaponsProvider)` で再フェッチをトリガーする想定
/// (本 FEAT 内で setEquippedWeapon 経路に追加実装する)。
final playerWeaponsProvider =
    FutureProvider.autoDispose<List<WeaponInfo>>((ref) async {
  final raw = await ref.watch(habitsServiceProvider).fetchPlayerWeapons();
  return raw.map(WeaponInfo.fromJson).toList();
});

// ── ゴミ箱（論理削除後30日以内） ──────────────────────────────
class TrashHabitsNotifier extends StateNotifier<AsyncValue<List<Habit>>> {
  TrashHabitsNotifier(this._service, this._ref)
      : super(const AsyncValue.loading()) {
    _load();
  }

  final HabitsService _service;
  final Ref _ref;

  Future<void> _load() async {
    state = await AsyncValue.guard(() => _service.fetchTrashHabits());
  }

  Future<void> restoreHabit(int habitId) async {
    await _service.restoreHabit(habitId);
    state = state.whenData(
      (habits) => habits.where((h) => h.id != habitId).toList(),
    );
    _ref.invalidate(habitsNotifierProvider);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    await _load();
  }
}

final trashHabitsNotifierProvider = StateNotifierProvider.autoDispose<
    TrashHabitsNotifier, AsyncValue<List<Habit>>>(
  (ref) => TrashHabitsNotifier(ref.watch(habitsServiceProvider), ref),
);
