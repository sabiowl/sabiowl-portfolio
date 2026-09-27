import '../../../core/api/api_client.dart';
import '../models/habit.dart';
import '../models/player.dart';

/// 【FEAT-474】cursor pagination レスポンスモデル。
class HabitsPage {
  final List<Habit> results;
  final String nextCursor;
  final bool hasMore;

  const HabitsPage({
    required this.results,
    required this.nextCursor,
    required this.hasMore,
  });
}

/// 【FEAT-524 Phase 2 (2026-08-08)】POST レスポンスの `player` を Player に起こす。
///
/// `Player.fromJson` は `id` 欠落時に `FormatException` を投げる (BUG-K の防御)。
/// player の取り込みは**最適化であって機能ではない**ため、ここで失敗しても
/// タップ自体を失敗させてはいけない。null を返すと呼び出し側が従来どおり
/// `invalidate(playerNotifierProvider)` にフォールバックする。
Player? _tryParsePlayer(Map<String, dynamic>? json) {
  if (json == null) return null;
  try {
    return Player.fromJson(json);
  } catch (_) {
    return null;
  }
}

class HabitsService {
  final ApiClient _apiClient;
  HabitsService(this._apiClient);

  // ── Player ──────────────────────────────────────────────────
  Future<Player> fetchPlayer() async {
    final res = await _apiClient.dio.get('/player/');
    return Player.fromJson(res.data as Map<String, dynamic>);
  }

  /// /api/player/ に任意のフィールドを PATCH する
  Future<void> patchPlayer(Map<String, dynamic> data) async {
    await _apiClient.dio.patch('/player/', data: data);
  }

  /// 【FEAT-326】PATCH /api/player/equip-weapon/
  /// 装備中の武器を切り替える (装備変更 BottomSheet からの呼出)。
  /// 失敗時は DioException を rethrow (呼び出し側で Optimistic UI ロールバック)。
  /// レスポンス: `{ "equipped_weapon": {id, key, name, atk_bonus} }`
  Future<Map<String, dynamic>> patchEquippedWeapon(int weaponId) async {
    final res = await _apiClient.dio.patch(
      '/player/equip-weapon/',
      data: {'weapon_id': weaponId},
    );
    return (res.data as Map<String, dynamic>)['equipped_weapon'] as Map<String, dynamic>;
  }

  /// 【FEAT-327】GET /api/player/weapons/
  /// 所持武器全件取得 (EquipmentSelectionOverlay の所持装備一覧用)。
  /// Shop 経由で買った武器とガチャ排出武器の両方を含めて、id/key/name/atk_bonus/
  /// is_equipped を返す。失敗時は DioException を rethrow。
  Future<List<Map<String, dynamic>>> fetchPlayerWeapons() async {
    final res = await _apiClient.dio.get('/player/weapons/');
    final list = (res.data as Map<String, dynamic>)['weapons'] as List<dynamic>;
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  /// 【FEAT-377 (2026-05-29) → FEAT-420 (2026-06-10) 予約モード化】
  /// ストリーク保護を予約する (在庫は消費せず streak_protection_pending=True を設定)。
  ///
  /// 翌日の習慣達成判定で「途切れていた」場合のみ在庫 1 個を消費して保護発動。
  /// 失敗時は DioException を rethrow (呼び出し側で catch + SnackBar 表示)。
  Future<Map<String, dynamic>> useStreakProtection({int? habitId}) async {
    final res = await _apiClient.dio.post(
      '/streak-protection/use/',
      data: habitId != null ? {'habit_id': habitId} : null,
    );
    return res.data as Map<String, dynamic>;
  }

  /// 【FEAT-420 (2026-06-10)】ストリーク保護の予約を取り消す (pending=False に戻すのみ、冪等)。
  /// 失敗時は DioException を rethrow (呼び出し側で catch + SnackBar 表示)。
  Future<Map<String, dynamic>> cancelStreakProtection() async {
    final res = await _apiClient.dio.post('/streak-protection/cancel/');
    return res.data as Map<String, dynamic>;
  }

  // ── Habits ──────────────────────────────────────────────────

  /// 【FEAT-474】cursor pagination 対応。
  /// 旧クライアントが返す flat List は後方互換で HabitsPage に wrap する。
  Future<HabitsPage> fetchHabits({String? cursor, int limit = 50}) async {
    final res = await _apiClient.dio.get(
      '/habits/',
      queryParameters: {
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        'limit': limit,
      },
    );
    final data = res.data;
    if (data is List) {
      return HabitsPage(
        results: data.map((e) => Habit.fromJson(e as Map<String, dynamic>)).toList(),
        nextCursor: '',
        hasMore: false,
      );
    }
    final map = data as Map<String, dynamic>;
    return HabitsPage(
      results: (map['results'] as List<dynamic>)
          .map((e) => Habit.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: map['next_cursor'] as String? ?? '',
      hasMore: map['has_more'] as bool? ?? false,
    );
  }

  Future<HabitsSummary> fetchSummary() async {
    final res = await _apiClient.dio.get('/habits/summary/');
    return HabitsSummary.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<Habit>> fetchArchivedHabits() async {
    final res = await _apiClient.dio.get('/habits/archived/');
    return (res.data as List<dynamic>)
        .map((e) => Habit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Habit> fetchHabit(int habitId) async {
    final res = await _apiClient.dio.get('/habits/$habitId/');
    return Habit.fromJson(res.data as Map<String, dynamic>);
  }

  // ── CRUD ────────────────────────────────────────────────────
  Future<Habit> createHabit({
    required String name,
    required String category,
    required String frequency,
    required String resetCycle,
    required String habitType,
    required String difficulty,
    String memo = '',
    bool isPublic = true,
    List<String> checklistItems = const [],
    String priority = 'medium',
    String? dueDate,
    // 【FEAT-205】dueTime 引数を削除（UI 未接続の死パイプライン、Backend モデルからも削除済み）
  }) async {
    final data = {
      'name': name,
      'category': category,
      'frequency': frequency,
      'reset_cycle': resetCycle,
      'habit_type': habitType,
      'difficulty': difficulty,
      'memo': memo,
      'is_public': isPublic,
      'priority': priority,
      if (checklistItems.isNotEmpty) 'checklist_items': checklistItems,
      if (dueDate != null) 'due_date': dueDate,
      // 【FEAT-205】due_time はモデル削除に伴い送信しない
    };
    final res = await _apiClient.dio.post('/habits/', data: data);
    return Habit.fromJson(res.data as Map<String, dynamic>);
  }

  Future<Habit> updateHabit(int habitId, Map<String, dynamic> data) async {
    final res = await _apiClient.dio.patch('/habits/$habitId/', data: data);
    return Habit.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteHabit(int habitId) async {
    await _apiClient.dio.delete('/habits/$habitId/');
  }

  // ── ログ記録 ─────────────────────────────────────────────────
  // API: POST /habits/<pk>/count/ body: { "action": "plus" }
  // Response: { "player": {...}, "habit": {...}, "diamond_earned": bool, "exp_gain": int,
  //   【FEAT-314】"streak_diamond_days": int? (7 の倍数達成時のみ、+5💎 トースト発火キー) }
  Future<HabitLogResult> incrementCount(int habitId, {int prevLevel = 0}) async {
    final res = await _apiClient.dio
        .post('/habits/$habitId/count/', data: {'action': 'plus'});
    final data = res.data as Map<String, dynamic>;
    final playerJson = data['player'] as Map<String, dynamic>?;
    final newLevel = playerJson?['level'] as int? ?? prevLevel;
    return HabitLogResult(
      habit: Habit.fromJson(data['habit'] as Map<String, dynamic>),
      // 【FEAT-524 Phase 2】level だけ抜いて捨てていた player を丸ごと持ち帰る。
      // 呼び出し側が setFromBootstrap で注入するので GET /player/ が不要になる。
      player: _tryParsePlayer(playerJson),
      diamondEarned: data['diamond_earned'] as bool? ?? false,
      expGain: data['exp_gain'] as int? ?? 0,
      bonusExp: data['bonus_exp'] as int? ?? 0,
      newLevel: newLevel,
      prevLevel: prevLevel,
      isComeback: data['is_comeback'] as bool? ?? false,
      autoAllocations: (data['auto_allocations'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as int? ?? 0)) ??
          const {},
      autoShieldType: data['auto_shield_type'] as String?,
      // 【FEAT-314】 7 の倍数達成時のみ Backend が int を返す（未達成は null）。
      streakDiamondDays: data['streak_diamond_days'] as int?,
      // 【FEAT-379】stat Lv UP 時に付与された結晶 { crystal_key: count }
      crystalsAwarded: (data['crystals_awarded'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as int? ?? 0)) ??
          const {},
      // 【FEAT-398】日次 EXP 閾値到達直後のみ True (サビ口調 SnackBar 発火シグナル)
      dailyThrottleTriggered: data['daily_throttle_triggered'] as bool? ?? false,
      // 【FEAT-420】予約していたストリーク保護が今回の達成で消費された場合のみ True
      streakProtectionPendingConsumed:
          data['streak_protection_pending_consumed'] as bool? ?? false,
      streakProtectionMessage: data['streak_protection_message'] as String?,
      // 【FEAT-433】当月 21 日達成で SSR 確定チケットを配布した場合のみ True
      monthlyTicketAwarded: data['monthly_ticket_awarded'] as bool? ?? false,
      // 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス (Day 1: 500+3+3、
      // Day 2-7: +100、Day 8+: +20)。non-null なら 7 日カレンダー演出を表示。
      todayLoginBonus: data['today_login_bonus'] as Map<String, dynamic>?,
      // 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント popup
      // 候補。non-null なら habits_provider が friendGiftCandidateProvider に set。
      friendGiftCandidate:
          data['friend_gift_candidate'] as Map<String, dynamic>?,
      // 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
      // non-null なら habits_provider が puzzlePieceAwardedProvider に set。
      puzzlePieceAwarded:
          data['puzzle_piece_awarded'] as Map<String, dynamic>?,
    );
  }

  // API: POST /habits/<pk>/count/ body: { "action": "minus" }
  Future<Habit> decrementCount(int habitId) async {
    final res = await _apiClient.dio
        .post('/habits/$habitId/count/', data: {'action': 'minus'});
    final data = res.data as Map<String, dynamic>;
    return Habit.fromJson(data['habit'] as Map<String, dynamic>);
  }

  // API: POST /habits/<pk>/checklist/<item_pk>/toggle/
  // Response: { "player": {...}, "habit": {...}, "diamond_earned": bool,
  //             "exp_gain": int, "bonus_exp": int, "is_comeback": bool,
  //             "auto_shield_type": str?, "auto_allocations": {...} }
  Future<HabitLogResult> toggleChecklistItem(int habitId, int itemId,
      {int prevLevel = 0}) async {
    final res = await _apiClient.dio
        .post('/habits/$habitId/checklist/$itemId/toggle/');
    final data = res.data as Map<String, dynamic>;
    final playerJson = data['player'] as Map<String, dynamic>?;
    final newLevel = playerJson?['level'] as int? ?? prevLevel;
    // BUG-B: チェックリスト経路の reward toast / Lv.UP 演出 / auto-shield 通知を
    // 動作させるため、サーバから返る各フィールドを忠実にマッピングする。
    return HabitLogResult(
      habit: Habit.fromJson(data['habit'] as Map<String, dynamic>),
      // 【FEAT-524 Phase 2】checklist toggle も `habits.py:852` で count 経路と
      // **同じ serializer / 同じ context** の player を返している。
      player: _tryParsePlayer(playerJson),
      diamondEarned: data['diamond_earned'] as bool? ?? false,
      expGain: data['exp_gain'] as int? ?? 0,
      bonusExp: data['bonus_exp'] as int? ?? 0,
      newLevel: newLevel,
      prevLevel: prevLevel,
      isComeback: data['is_comeback'] as bool? ?? false,
      autoAllocations: (data['auto_allocations'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as int? ?? 0)) ??
          const {},
      autoShieldType: data['auto_shield_type'] as String?,
      // 【FEAT-433】当月 21 日達成で SSR 確定チケットを配布した場合のみ True
      monthlyTicketAwarded: data['monthly_ticket_awarded'] as bool? ?? false,
      // 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス (Day 1 / Day 2-7 / Day 8+)
      todayLoginBonus: data['today_login_bonus'] as Map<String, dynamic>?,
      // 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント popup 候補
      friendGiftCandidate:
          data['friend_gift_candidate'] as Map<String, dynamic>?,
    );
  }

  // ── シールド・アーカイブ ──────────────────────────────────────
  Future<Habit> activateShield(int habitId) async {
    final res = await _apiClient.dio.post('/habits/$habitId/shield/');
    // バックエンドは {'player': {...}, 'habit': {...}} を返す
    final data = res.data as Map<String, dynamic>;
    return Habit.fromJson(data['habit'] as Map<String, dynamic>);
  }

  Future<void> archiveHabit(int habitId) async {
    await _apiClient.dio.post('/habits/$habitId/archive/');
  }

  Future<Habit> restoreHabit(int habitId) async {
    final res = await _apiClient.dio.post('/habits/$habitId/restore/');
    return Habit.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<String>> fetchCategories() async {
    final res = await _apiClient.dio.get('/habits/categories/');
    return (res.data as List<dynamic>).map((e) => e as String).toList();
  }

  Future<List<Habit>> fetchTrashHabits() async {
    final res = await _apiClient.dio.get('/habits/trash/');
    return (res.data as List<dynamic>)
        .map((e) => Habit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── 完了済み ToDo ────────────────────────────────────────────
  Future<List<TodoDoneGroup>> fetchTodoDone() async {
    final res = await _apiClient.dio.get('/habits/todos/done/');
    return (res.data as List<dynamic>)
        .map((e) => TodoDoneGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── 並び替え ─────────────────────────────────────────────────
  // API expects { "order": [...] } not { "ids": [...] }
  Future<void> reorderHabits(List<int> orderedIds) async {
    await _apiClient.dio.post('/habits/reorder/', data: {'order': orderedIds});
  }

  // ── ホーム集約 ───────────────────────────────────────────
  /// GET /api/home/ — ホーム画面の初回描画に必要なデータを 1 リクエストで取得する。
  ///
  /// レスポンスのキー:
  /// - `player`             : PlayerProfile オブジェクト
  /// - `habits`             : アクティブ習慣リスト
  /// - `summary`            : 今日の達成状況・週間達成率・ストリーク等
  /// - `unread_notif_count` : 未読通知数
  /// - `sabi_message`       : サビメッセージ (timeSegment 指定時のみ)
  ///
  /// 【FEAT-484】`timeSegment` を渡すと Backend が sabi_message を bootstrap に含む。
  /// nonce='' (1 日 1 メッセージ互換)。pull-to-refresh は別経路 (SabiService)。
  Future<Map<String, dynamic>> fetchHomeBootstrap({String? timeSegment}) async {
    final res = await _apiClient.dio.get(
      '/home/',
      queryParameters: (timeSegment != null && timeSegment.isNotEmpty)
          ? {'time_segment': timeSegment}
          : null,
    );
    return res.data as Map<String, dynamic>;
  }
}
