// 【FEAT-205】`TimeOfDay` の import は `dueTime` 削除に伴い不要化、撤去済み。
import '../../../l10n/app_localizations.dart';
import 'player.dart';  // 【FEAT-524 Phase 2】HabitLogResult.player

// チェックリストアイテム（API: text / is_done）
class ChecklistItem {
  final int id;
  final String text;
  final int order;
  final bool isDone;

  const ChecklistItem({
    required this.id,
    required this.text,
    required this.order,
    required this.isDone,
  });

  factory ChecklistItem.fromJson(Map<String, dynamic> json) {
    return ChecklistItem(
      id: json['id'] as int,
      text: json['text'] as String? ?? '',
      order: json['order'] as int? ?? 0,
      isDone: json['is_done'] as bool? ?? false,
    );
  }

  ChecklistItem copyWith({bool? isDone}) {
    return ChecklistItem(
      id: id, text: text, order: order,
      isDone: isDone ?? this.isDone,
    );
  }
}

// 今日のログ（API: today_log）
class TodayLog {
  final int count;
  final int expGained;

  const TodayLog({required this.count, required this.expGained});

  factory TodayLog.fromJson(Map<String, dynamic> json) {
    return TodayLog(
      count: json['count'] as int? ?? 0,
      expGained: json['exp_gained'] as int? ?? 0,
    );
  }
}

// 期間進捗（API: period_progress）
//
// 【重要】`done` の単位は **frequency** (達成した日数 / 週数 / 月数) であって、
// 回数の合計ではない。回数合計は [Habit.periodCount] (FEAT-520) を使うこと。
// 両者は名前が似ていて中身が違い、取り違えると BUG-73 がそのまま再発する。
class PeriodProgress {
  final int done;
  final int total;

  /// Backend が組み立てた日本語ラベル (例: `今週 3/7日`)。
  ///
  /// 【FEAT-520 §4.5】**英語 locale でも日本語のまま返ってくる**ため、
  /// 新アプリでは表示に使わない ([scope] / [unit] から組み立てる)。
  /// 旧アプリ (v1.0) がこれを表示しているので Backend からは消せない。
  final String label;

  /// 集計期間: `week` / `month` / `year`。旧 Backend では null。
  final String? scope;

  /// [done] / [total] の単位: `day` / `week` / `month`。旧 Backend では null。
  final String? unit;

  const PeriodProgress({
    required this.done,
    required this.total,
    required this.label,
    this.scope,
    this.unit,
  });

  factory PeriodProgress.fromJson(Map<String, dynamic> json) {
    return PeriodProgress(
      done: json['done'] as int? ?? 0,
      total: json['total'] as int? ?? 1,
      label: json['label'] as String? ?? '',
      scope: json['scope'] as String?,
      unit: json['unit'] as String?,
    );
  }

  double get rate => total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);

  /// 【FEAT-520 §4.5】locale に応じた進捗ラベルを組み立てる。
  ///
  /// `scope` / `unit` が無い (= Backend が古い) 場合は Backend の [label] を
  /// そのまま返す。日本語のままになるが、**表示が消えるよりはよい**。
  ///
  /// 単純な文字列連結にせず ICU plural を通すのは、英語の `1 day` / `3 days` を
  /// 正しく出すため。
  String localizedLabel(AppLocalizations l10n) {
    final amount = switch (unit) {
      'day' => l10n.habitPeriodProgressUnitDays(done, total),
      'week' => l10n.habitPeriodProgressUnitWeeks(done, total),
      'month' => l10n.habitPeriodProgressUnitMonths(done, total),
      _ => null,
    };
    if (amount == null) return label;
    return switch (scope) {
      'week' => l10n.habitPeriodProgressScopeWeek(amount),
      'month' => l10n.habitPeriodProgressScopeMonth(amount),
      'year' => l10n.habitPeriodProgressScopeYear(amount),
      _ => label,
    };
  }
}

// 習慣
class Habit {
  final int id;
  final String name;
  final String category;
  final String frequency;   // daily / weekly / monthly
  final String resetCycle;  // daily / weekly / monthly / yearly
  final String habitType;   // count / checklist
  final String difficulty;  // easy / normal / hard / legendary
  final String priority;    // low / medium / high
  final int order;
  final int streak;
  final int bestStreak;
  final int totalCount;
  final bool isActive;
  final String memo;
  final bool isPublic;
  final bool shieldActive;
  final DateTime? dueDate;
  // 【FEAT-205】dueTime は UI に time picker が存在せず、通知発火経路でも未参照の
  // 死パイプラインだったため削除（旧 BUG-2026-07 のフィールドごと）。
  final TodayLog? todayLog;
  final List<ChecklistItem> checklistItems;
  final PeriodProgress? periodProgress;

  /// 【FEAT-520】`resetCycle` 期間内の **回数の合計** (API: `period_count`)。
  ///
  /// バッジ `+N` の値。`resetCycle == 'daily'` なら [todayCount] と一致するので、
  /// 既存ユーザーの大多数 (daily + daily) では見た目が変わらない。
  ///
  /// [PeriodProgress.done] (= 達成 **日数**) とは別物。混同すると BUG-73 が再発する。
  final int periodCount;

  /// 【FEAT-520】`frequency` 期間内に 1 日でも達成したか (API: `period_done`)。
  ///
  /// カードの **外観** (取り消し線 / 減光 / 「達成済み」) の基準。
  /// **操作系 (✓ / + / −) には使わない** — 理由は [isCompletedToday] を参照。
  final bool periodDone;

  const Habit({
    required this.id,
    required this.name,
    required this.category,
    required this.frequency,
    required this.resetCycle,
    required this.habitType,
    required this.difficulty,
    required this.priority,
    required this.order,
    required this.streak,
    required this.bestStreak,
    required this.totalCount,
    required this.isActive,
    required this.memo,
    required this.isPublic,
    required this.shieldActive,
    this.dueDate,
    this.todayLog,
    required this.checklistItems,
    this.periodProgress,
    this.periodCount = 0,
    this.periodDone = false,
  });

  factory Habit.fromJson(Map<String, dynamic> json) {
    final todayLogJson = json['today_log'] as Map<String, dynamic>?;
    final progressJson = json['period_progress'] as Map<String, dynamic>?;
    final items = (json['checklist_items'] as List<dynamic>?)
            ?.map((e) => ChecklistItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    // 【FEAT-205】`parseDueTime` ヘルパーは dueTime 削除に伴い不要化、削除済み。

    return Habit(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? '運動',
      frequency: json['frequency'] as String? ?? 'daily',
      resetCycle: json['reset_cycle'] as String? ?? 'daily',
      habitType: json['habit_type'] as String? ?? 'count',
      difficulty: json['difficulty'] as String? ?? 'normal',
      priority: json['priority'] as String? ?? 'medium',
      order: json['order'] as int? ?? 0,
      streak: json['streak'] as int? ?? 0,
      bestStreak: json['best_streak'] as int? ?? 0,
      totalCount: json['total_count'] as int? ?? 0,
      isActive: json['is_active'] as bool? ?? true,
      memo: json['memo'] as String? ?? '',
      isPublic: json['is_public'] as bool? ?? true,
      shieldActive: json['shield_active'] as bool? ?? false,
      dueDate: json['due_date'] != null
          ? DateTime.tryParse(json['due_date'] as String)
          : null,
      todayLog: todayLogJson != null ? TodayLog.fromJson(todayLogJson) : null,
      checklistItems: items,
      periodProgress:
          progressJson != null ? PeriodProgress.fromJson(progressJson) : null,
      // 【FEAT-520】Backend が古い (フィールドが無い) 場合は **現行挙動に落とす**。
      // 0 / false で潰すと、更新前の Backend に繋いだ瞬間にバッジが消え、
      // 完了済みの習慣が未完了に見える。
      periodCount:
          json['period_count'] as int? ?? (todayLogJson?['count'] as int? ?? 0),
      periodDone: json['period_done'] as bool? ??
          ((todayLogJson?['count'] as int? ?? 0) > 0),
    );
  }

  // 今日のカウント
  int get todayCount => todayLog?.count ?? 0;

  /// **今日**達成したか（タスクレベル完了 OR 全項目チェック済み）。
  ///
  /// 【FEAT-520 §5.4】カードの外観は [periodDone] に移したが、本 getter は
  /// **削除も置き換えもしない**。✓ / + / − ボタンの状態と操作は今日基準のままで
  /// なければならない:
  ///
  /// Backend の `_apply_minus()` は **今日の log が 0 なら `no_op`** で何もしない
  /// (`habit_count_service.py:626`)。週次チェックリスト習慣を月曜に達成 → 火曜に
  /// ✓ を押す、という経路でボタンを [periodDone] に繋ぐと、`decrementCount` が
  /// 呼ばれて何も起きない = **タップしても無反応**になる。エラーも出ないので
  /// 実装中は気付けない。
  ///
  /// 結果として週次習慣では「カードは達成済み表示 / ボタンは未チェック」が並ぶが、
  /// これは「今週は達成済み、ただし今日はまだ」という正しい情報である。
  bool get isCompletedToday {
    if (habitType == 'checklist') {
      return todayCount > 0 ||
          (checklistItems.isNotEmpty && checklistItems.every((i) => i.isDone));
    }
    return todayLog != null && todayLog!.count > 0;
  }

  /// 【FEAT-520】`frequency` 期間内に達成したか（カードの **外観** 用）。
  ///
  /// チェックリストは「全項目チェック済み」でも達成扱いにする ([isCompletedToday]
  /// と同じ扱い)。`ChecklistItem.done_date` は日次のままなので、この経路が効くのは
  /// 当日のみ。期間内の達成は Backend の [periodDone] が拾う。
  bool get isCompletedInPeriod {
    if (habitType == 'checklist') {
      return periodDone ||
          (checklistItems.isNotEmpty && checklistItems.every((i) => i.isDone));
    }
    return periodDone;
  }

  // 進捗率（カード表示用）
  double get progress {
    if (habitType == 'checklist') {
      if (checklistItems.isEmpty) return 0.0;
      final done = checklistItems.where((i) => i.isDone).length;
      return done / checklistItems.length;
    }
    // 【FEAT-520】periodProgress が null (frequency == resetCycle) のときの
    // フォールバックを periodDone 基準に更新。weekly+weekly の習慣が週の途中で
    // 進捗 0 に戻らないようにする。
    return periodProgress?.rate ?? (isCompletedInPeriod ? 1.0 : 0.0);
  }

  // ToDo タイプ判定
  bool get isTodo => habitType == 'todo';

  /// カウント +1 の楽観的コピーを返す。
  /// todayLog が存在する場合はそのカウントをインクリメント。
  /// ない場合は仮の today ログ（expGained=0）を追加する。
  ///
  /// 【FEAT-520】バッジは [periodCount] を表示するので、ここを更新しないと
  /// 「+ を押しても数字が増えない」= BUG-73 とまったく同じ症状になる。
  /// 今日やった事実は必ずどの期間窓にも入るので [periodDone] は無条件に true。
  Habit optimisticIncrement() {
    final newLog = todayLog != null
        ? TodayLog(count: todayLog!.count + 1, expGained: todayLog!.expGained)
        : const TodayLog(count: 1, expGained: 0);
    return copyWith(
      todayLog: newLog,
      periodCount: periodCount + 1,
      periodDone: true,
    );
  }

  /// カウント -1 の楽観的コピーを返す。
  /// todayLog の count を 1 減らし、0 になる場合は todayLog を null にする。
  Habit optimisticDecrement() {
    if (todayLog == null || todayLog!.count <= 0) return this;
    final newCount = todayLog!.count - 1;
    final newLog = newCount > 0
        ? TodayLog(count: newCount, expGained: todayLog!.expGained)
        : null;
    // 【FEAT-520】periodDone を落としてよいのは「今日の分が消えた結果、
    // frequency 窓に何も残らないと断定できる」場合だけ。
    //   - 集計窓が空になった → どの窓にも何も無い
    //   - frequency == 'daily' かつ今日が 0 になった → 窓 = 今日なので false
    // frequency が weekly / monthly の場合、週の別の日に達成が残っている
    // 可能性をクライアントからは判定できないので触らない (次の refresh で正になる)。
    final newPeriodCount = (periodCount - 1).clamp(0, 1 << 31);
    final bool newPeriodDone;
    if (newPeriodCount == 0) {
      newPeriodDone = false;
    } else if (frequency == 'daily' && newCount == 0) {
      newPeriodDone = false;
    } else {
      newPeriodDone = periodDone;
    }
    return copyWith(
      todayLog: newLog,
      periodCount: newPeriodCount,
      periodDone: newPeriodDone,
    );
  }

  /// チェックリスト項目の isDone を即座に反転した楽観的コピーを返す。
  Habit optimisticToggleChecklistItem(int itemId) {
    final newItems = checklistItems.map((item) {
      if (item.id == itemId) return item.copyWith(isDone: !item.isDone);
      return item;
    }).toList();
    return copyWith(checklistItems: newItems);
  }

  // 【FEAT-489 Phase 2F-a】旧 difficultyLabel / frequencyLabel (日本語 hardcode の
  // getter) を削除。「habit_card.dart との後方互換のため残置」とコメントされていたが、
  // 実際には habit_card.dart も含め全呼び出し元が下の *L10n 版に移行済で、
  // 参照 0 件の dead code だった。

  String difficultyLabelL10n(AppLocalizations l10n) {
    switch (difficulty) {
      case 'easy':      return l10n.habitEditHabitDiffEasy;
      case 'hard':      return l10n.habitEditHabitDiffHard;
      case 'legendary': return l10n.habitEditHabitDiffLegendary;
      default:          return l10n.habitEditHabitDiffNormal;
    }
  }

  String frequencyLabelL10n(AppLocalizations l10n) {
    switch (frequency) {
      case 'weekly':  return l10n.habitAddHabitFreqWeekly;
      case 'monthly': return l10n.habitAddHabitFreqMonthly;
      default:        return l10n.habitAddHabitFreqDaily;
    }
  }

  // BUG-R: copyWith の nullable フィールド（dueDate / todayLog）は
  // 「引数省略 = 既存値維持」と「null を渡す = クリア」を区別するために sentinel
  // パターンを使う。`?? this.X` だと null を渡しても既存値が残り、
  // ToDo 期限の解除やログのリセットが silently 効かなかった。
  // checklistItems は非 nullable（空リストが「無し」）のため対象外。
  Habit copyWith({
    Object? todayLog       = _kHabitSentinel,
    Object? dueDate        = _kHabitSentinel,
    bool?   shieldActive,
    List<ChecklistItem>? checklistItems,
    bool?   isActive,
    int?    periodCount,   // 【FEAT-520】楽観的更新用
    bool?   periodDone,    // 【FEAT-520】楽観的更新用
  }) {
    return Habit(
      id: id, name: name, category: category,
      frequency: frequency, resetCycle: resetCycle,
      habitType: habitType, difficulty: difficulty,
      priority: priority,
      order: order, streak: streak, bestStreak: bestStreak,
      totalCount: totalCount,
      isActive: isActive ?? this.isActive,
      memo: memo, isPublic: isPublic,
      shieldActive: shieldActive ?? this.shieldActive,
      dueDate: identical(dueDate, _kHabitSentinel)
          ? this.dueDate
          : dueDate as DateTime?,
      // 【FEAT-205】dueTime フィールド削除に伴い copyWith からも削除。
      todayLog: identical(todayLog, _kHabitSentinel)
          ? this.todayLog
          : todayLog as TodayLog?,
      checklistItems: checklistItems ?? this.checklistItems,
      periodProgress: periodProgress,
      periodCount: periodCount ?? this.periodCount,
      periodDone: periodDone ?? this.periodDone,
    );
  }
}

/// BUG-R: copyWith の nullable フィールド向けセンチネル。
/// 引数省略時はこれが渡り、`identical(arg, _kHabitSentinel)` で「省略」と判定する。
const Object _kHabitSentinel = Object();

// サマリー
class HabitsSummary {
  final int totalHabits;
  final int completedHabits;
  final int weekRate;
  final int currentStreak;
  final int totalExpToday;

  const HabitsSummary({
    required this.totalHabits,
    required this.completedHabits,
    required this.weekRate,
    required this.currentStreak,
    required this.totalExpToday,
  });

  // API: today_total / today_completed / week_rate / current_streak / total_exp_today
  factory HabitsSummary.fromJson(Map<String, dynamic> json) {
    return HabitsSummary(
      totalHabits:    json['today_total']     as int? ?? 0,
      completedHabits: json['today_completed'] as int? ?? 0,
      weekRate:       json['week_rate']        as int? ?? 0,
      currentStreak:  json['current_streak']  as int? ?? 0,
      totalExpToday:  json['total_exp_today'] as int? ?? 0,
    );
  }

  double get completionRate =>
      totalHabits <= 0 ? 0.0 : completedHabits / totalHabits;
}

// ── 完了済み ToDo グループ（日付別）────────────────────────────
class TodoDoneGroup {
  final String date;
  final List<Habit> todos;

  const TodoDoneGroup({required this.date, required this.todos});

  factory TodoDoneGroup.fromJson(Map<String, dynamic> json) => TodoDoneGroup(
        date: json['date'] as String,
        todos: (json['todos'] as List<dynamic>)
            .map((e) => Habit.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ── ログ記録結果（レベルアップ検知用）─────────────────────────
class HabitLogResult {
  final Habit habit;
  final bool diamondEarned;
  final int expGain;
  final int bonusExp;
  final int newLevel;      // レベルアップ後のレベル（変化なければ 0）
  final int prevLevel;
  final bool isComeback;   // 休息日明けの復帰フラグ
  /// レベルアップ時の自動配分結果 { stat名: pt数 }
  /// 例: {'運動力': 4, '学習力': 2, '精神力': 3, '健康力': 1}
  /// レベルアップなし or 達成データなしの場合は空マップ
  final Map<String, int> autoAllocations;
  /// FEAT-131: 自動シールド種別 ('rest_day' | 'fruit' | null)
  final String? autoShieldType;

  /// 【FEAT-314】連続 7 / 14 / 21 / ... 日達成で +5 ダイヤが付与された場合、
  /// その streak 値（7 / 14 / 21 ...）。付与されなかった場合は null。
  final int? streakDiamondDays;

  /// 【FEAT-379 (2026-05-29)】今回付与した結晶 { crystal_key: count }。
  /// stat Lv UP 時のみ非空。LevelUpDialog の結晶演出に使う。
  final Map<String, int> crystalsAwarded;

  /// 【FEAT-398 (2026-05-31)】今回の達成で初めて日次 EXP 閾値 (25 件) に達した場合 True。
  /// Flutter 側でサビ口調 SnackBar を 1 日 1 回表示するためのシグナル。
  final bool dailyThrottleTriggered;

  /// 【FEAT-420 (2026-06-10)】予約していたストリーク保護が今回の達成で消費された場合 True。
  /// SnackBar 表示シグナル (true のときのみ streakProtectionMessage を表示)。
  final bool streakProtectionPendingConsumed;

  /// 【FEAT-420 (2026-06-10)】予約消費時のメッセージ (非消費時は null)。
  final String? streakProtectionMessage;

  /// 【FEAT-433 (2026-06-13)】当月 21 日達成で SSR 確定チケットを配布した場合 True。
  /// SnackBar 表示シグナル (1 回限り)。
  final bool monthlyTicketAwarded;

  /// 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス。
  /// non-null なら Mobile が 7 日カレンダー + スタンプ演出を表示する。
  /// keys: {amount: int, days_count: int, granted_daily_tickets: int, granted_weekly_tickets: int}
  final Map<String, dynamic>? todayLoginBonus;

  /// 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成時のフレンドプレゼント popup 候補 (JSON Map)。
  /// non-null なら Mobile 側 Notifier が `friendGiftCandidateProvider` に set して
  /// 確認ダイアログを発火する。keys: {id, name, level, friend_id,
  /// active_character_image_path, active_character_key}
  final Map<String, dynamic>? friendGiftCandidate;

  /// 【FEAT-479 (2026-07-06)】その日初回タスク達成時のパズルピース付与 (JSON Map)。
  /// non-null なら Mobile 側 Notifier が `puzzlePieceAwardedProvider` に set して
  /// PuzzlePieceOverlayModal を発火する。keys: {piece_index, new_state=1, scene_key}
  final Map<String, dynamic>? puzzlePieceAwarded;

  /// 【FEAT-524 Phase 2 (2026-08-08)】POST が返した**確定済みの** player。
  ///
  /// `POST /habits/<id>/count/` も checklist toggle も、レスポンスに
  /// `PlayerProfileSerializer` の全体を含んでいる (`habits.py:646` / `:852`)。
  /// 従来はここから `level` だけ抜いて残りを捨て、直後に
  /// `invalidate(playerNotifierProvider)` で **同じ player を取り直して**いた。
  ///
  /// 本 field を持たせて `setFromBootstrap` に流すことで `GET /player/` が 1 本消える。
  /// 旧 Backend / player を返さない経路 (minus) では null になり、
  /// 呼び出し側は従来どおり invalidate にフォールバックする。
  final Player? player;

  const HabitLogResult({
    required this.habit,
    required this.diamondEarned,
    required this.expGain,
    this.bonusExp = 0,
    required this.newLevel,
    required this.prevLevel,
    this.isComeback = false,
    this.autoAllocations = const {},
    this.autoShieldType,
    this.streakDiamondDays,
    this.crystalsAwarded = const {},
    this.dailyThrottleTriggered = false,  // 【FEAT-398】
    this.streakProtectionPendingConsumed = false,  // 【FEAT-420】
    this.streakProtectionMessage,                  // 【FEAT-420】
    this.monthlyTicketAwarded = false,             // 【FEAT-433】
    this.todayLoginBonus,                          // 【BUG-122】
    this.friendGiftCandidate,                      // 【FEAT-452】
    this.puzzlePieceAwarded,                       // 【FEAT-479】
    this.player,                                   // 【FEAT-524 Phase 2】
  });

  /// 【BUG-137 (2026-06-17)】race ガード追加: `prevLevel > 0` を必須化。
  ///
  /// 旧実装は `newLevel > prevLevel` のみで判定していたため、ログアウト → 再ログイン
  /// 直後の race condition で `playerNotifierProvider` が再フェッチ中 (`valueOrNull`
  /// が null) の状態で habit count が走ると、`prevLevel = null ?? 0 = 0` のフォール
  /// バックが発火し、Backend が返す実レベル (例 Lv.5) と比較されて「Lv.0 → Lv.5」
  /// = Lv.UP 誤発火していた。
  ///
  /// プレイヤーは必ず Lv.1 から開始するため、`prevLevel = 0` は実質的に「未知」を
  /// 示す sentinel 値。`prevLevel > 0` でこれを除外することで race を構造的に遮断
  /// する (本当の Lv.1 → Lv.2 昇格は `prevLevel = 1 > 0` で正常通過)。
  bool get leveledUp => prevLevel > 0 && newLevel > prevLevel;
}

// ── リワードトースト用データ ───────────────────────────────────────────────
/// 習慣達成時に画面下部トーストへ渡す軽量データクラス。
class HabitReward {
  final int  expGain;
  final int  bonusExp;
  final bool diamondEarned;

  const HabitReward({
    required this.expGain,
    required this.bonusExp,
    required this.diamondEarned,
  });

  /// 表示用合計 EXP（基本 + ボーナス）
  int get totalExp => expGain + bonusExp;
}

// ── 楽観的 UI 用 プレイヤー差分 ──────────────────────────────────────────
/// サーバー確定前の暫定 EXP・ダイヤ差分。
/// null = 通常状態（差分なし）
class PendingPlayerReward {
  final int expDelta;      // 暫定加算 EXP（取り消し時は 0 に戻す）
  final int diamondDelta;  // 暫定加算ダイヤ（0 or 1）

  const PendingPlayerReward({
    required this.expDelta,
    required this.diamondDelta,
  });
}

