// ── カレンダー日別データ ───────────────────────────────────────
class CalendarDayHabit {
  final int id;
  final String name;
  final String category;
  final bool done;
  final int count;
  final String difficulty; // 'easy'|'normal'|'hard'|'legendary'

  const CalendarDayHabit({
    required this.id,
    required this.name,
    required this.category,
    required this.done,
    required this.count,
    this.difficulty = 'normal',
  });

  factory CalendarDayHabit.fromJson(Map<String, dynamic> j) => CalendarDayHabit(
        id:         j['id'] as int,
        name:       j['name']       as String? ?? '',
        category:   j['category']   as String? ?? '',
        done:       j['done']       as bool?   ?? false,
        count:      j['count']      as int?    ?? 0,
        difficulty: j['difficulty'] as String? ?? 'normal',
      );
}

/// 月次カレンダーグリッドで表示するタイムライン予定（FEAT-108）
class CalendarTimelineEvent {
  final int    id;
  final String title;
  final String category;  // habit / health / work / rest / social / other
  final String iconKey;
  final bool   isCompleted;

  const CalendarTimelineEvent({
    required this.id,
    required this.title,
    required this.category,
    required this.iconKey,
    required this.isCompleted,
  });

  factory CalendarTimelineEvent.fromJson(Map<String, dynamic> j) =>
      CalendarTimelineEvent(
        id:          j['id']           as int? ?? 0,
        title:       j['title']        as String? ?? '',
        category:    j['category']     as String? ?? 'other',
        iconKey:     j['icon_key']     as String? ?? 'event',
        isCompleted: j['is_completed'] as bool?   ?? false,
      );
}

class CalendarDay {
  final DateTime date;
  final int day;
  final int dow; // 0=日, 1=月, …, 6=土
  final bool isToday;
  final bool isFuture;
  final int completed;
  final int total;
  final int pct; // 0/25/50/75/100
  final int exp; // その日の獲得EXP合計
  final List<CalendarDayHabit> habits;
  final bool isRestDay;                            // 休息日フラグ
  final int  todosPending;                         // 未完了 Todo 数
  final bool todosHighPriority;                    // 高優先度 Todo が 1 件以上あるか
  // FEAT-108: タイムライン予定（月次グリッドのチップ表示用）
  final List<CalendarTimelineEvent> timelineEvents;

  const CalendarDay({
    required this.date,
    required this.day,
    required this.dow,
    required this.isToday,
    required this.isFuture,
    required this.completed,
    required this.total,
    required this.pct,
    required this.exp,
    required this.habits,
    this.isRestDay         = false,
    this.todosPending      = 0,
    this.todosHighPriority = false,
    this.timelineEvents    = const [],             // FEAT-108
  });

  factory CalendarDay.fromJson(Map<String, dynamic> j) => CalendarDay(
        // NEW-13: tryParse でクラッシュ回避。不正フォーマット時は今日の日付にフォールバック。
        date: DateTime.tryParse(j['date'] as String? ?? '') ?? DateTime.now(),
        day: j['day'] as int,
        dow: j['dow'] as int? ?? 0,
        isToday: j['is_today'] as bool? ?? false,
        isFuture: j['is_future'] as bool? ?? false,
        completed: j['completed'] as int? ?? 0,
        total: j['total'] as int? ?? 0,
        pct: j['pct'] as int? ?? 0,
        exp: j['exp'] as int? ?? 0,
        habits: (j['habits'] as List<dynamic>?)
                ?.map((e) => CalendarDayHabit.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        isRestDay:          j['is_rest_day']       as bool? ?? false,
        todosPending:       j['todo_pending']       as int?  ?? 0,
        todosHighPriority:  j['todo_high_pending']  as bool? ?? false,
        // FEAT-108: タイムライン予定
        timelineEvents: (j['timeline_events'] as List<dynamic>?)
                ?.map((e) => CalendarTimelineEvent.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

class CalendarSummary {
  final int totalCompletions;
  final int completionRate;
  final int currentStreak;
  final int daysWithAny;
  final int pastDays;
  final int totalHabits;

  const CalendarSummary({
    required this.totalCompletions,
    required this.completionRate,
    required this.currentStreak,
    required this.daysWithAny,
    required this.pastDays,
    required this.totalHabits,
  });

  factory CalendarSummary.fromJson(Map<String, dynamic> j) => CalendarSummary(
        totalCompletions: j['total_completions'] as int? ?? 0,
        completionRate: j['completion_rate'] as int? ?? 0,
        currentStreak: j['current_streak'] as int? ?? 0,
        daysWithAny: j['days_with_any'] as int? ?? 0,
        pastDays: j['past_days'] as int? ?? 0,
        totalHabits: j['total_habits'] as int? ?? 0,
      );
}

class CalendarData {
  final int year;
  final int month;
  final List<CalendarDay> days;
  final CalendarSummary summary;

  const CalendarData({
    required this.year,
    required this.month,
    required this.days,
    required this.summary,
  });

  factory CalendarData.fromJson(Map<String, dynamic> j) => CalendarData(
        year: j['year'] as int,
        month: j['month'] as int,
        days: (j['days'] as List<dynamic>)
            .map((e) => CalendarDay.fromJson(e as Map<String, dynamic>))
            .toList(),
        summary: CalendarSummary.fromJson(j['summary'] as Map<String, dynamic>),
      );

  /// date → CalendarDay のマップ（日付文字列キー）
  Map<DateTime, CalendarDay> get dayMap =>
      {for (final d in days) DateTime(d.date.year, d.date.month, d.date.day): d};
}

// ── ストリーク ─────────────────────────────────────────────────
class SevenDayHabit {
  final int id;
  final String name;
  final bool done;
  final int count;

  const SevenDayHabit({
    required this.id,
    required this.name,
    required this.done,
    required this.count,
  });

  factory SevenDayHabit.fromJson(Map<String, dynamic> j) => SevenDayHabit(
        id: j['id'] as int,
        name: j['name'] as String? ?? '',
        done: j['done'] as bool? ?? false,
        count: j['count'] as int? ?? 0,
      );
}

class SevenDayEntry {
  final DateTime date;
  final String label; // 月〜日
  final bool isToday;
  final List<SevenDayHabit> habits;

  const SevenDayEntry({
    required this.date,
    required this.label,
    required this.isToday,
    required this.habits,
  });

  int get completedCount => habits.where((h) => h.done).length;
  int get totalCount => habits.length;

  factory SevenDayEntry.fromJson(Map<String, dynamic> j) => SevenDayEntry(
        // NEW-13: tryParse でクラッシュ回避。不正フォーマット時は今日の日付にフォールバック。
        date: DateTime.tryParse(j['date'] as String? ?? '') ?? DateTime.now(),
        label: j['label'] as String? ?? '',
        isToday: j['is_today'] as bool? ?? false,
        habits: (j['habits'] as List<dynamic>?)
                ?.map((e) => SevenDayHabit.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class StreakHabit {
  final int id;
  final String name;
  final String category;
  final int streak;
  final int bestStreak;

  const StreakHabit({
    required this.id,
    required this.name,
    required this.category,
    required this.streak,
    required this.bestStreak,
  });

  factory StreakHabit.fromJson(Map<String, dynamic> j) => StreakHabit(
        id: j['id'] as int,
        name: j['name'] as String? ?? '',
        category: j['category'] as String? ?? '',
        streak: j['streak'] as int? ?? 0,
        bestStreak: j['best_streak'] as int? ?? 0,
      );
}

class StreakData {
  final int currentStreak;
  final int bestStreak;
  final int daysToRecord;
  final List<SevenDayEntry> sevenDays;
  final List<StreakHabit> habitStreaks;

  const StreakData({
    required this.currentStreak,
    required this.bestStreak,
    required this.daysToRecord,
    required this.sevenDays,
    required this.habitStreaks,
  });

  factory StreakData.fromJson(Map<String, dynamic> j) => StreakData(
        currentStreak: j['current_streak'] as int? ?? 0,
        bestStreak: j['best_streak'] as int? ?? 0,
        daysToRecord: j['days_to_record'] as int? ?? 0,
        sevenDays: (j['seven_days'] as List<dynamic>?)
                ?.map((e) => SevenDayEntry.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        habitStreaks: (j['habit_streaks'] as List<dynamic>?)
                ?.map((e) => StreakHabit.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

// ── 統計・分析 ─────────────────────────────────────────────────
class HabitRate {
  final int id;
  final String name;
  final String category;
  final int completed;
  final int pastDays;
  final int rate;

  const HabitRate({
    required this.id,
    required this.name,
    required this.category,
    required this.completed,
    required this.pastDays,
    required this.rate,
  });

  factory HabitRate.fromJson(Map<String, dynamic> j) => HabitRate(
        id: j['id'] as int,
        name: j['name'] as String? ?? '',
        category: j['category'] as String? ?? '',
        completed: j['completed'] as int? ?? 0,
        pastDays: j['past_days'] as int? ?? 0,
        rate: j['rate'] as int? ?? 0,
      );
}

class DowAvg {
  final int dow;
  final String label;
  final int? rate; // null = データなし

  const DowAvg({required this.dow, required this.label, this.rate});

  factory DowAvg.fromJson(Map<String, dynamic> j) => DowAvg(
        dow: j['dow'] as int,
        label: j['label'] as String? ?? '',
        rate: j['rate'] as int?,
      );
}

class ComparisonMonth {
  final int year;
  final int month;
  final int total;
  final int rate;

  const ComparisonMonth({
    required this.year,
    required this.month,
    required this.total,
    required this.rate,
  });

  factory ComparisonMonth.fromJson(Map<String, dynamic> j) => ComparisonMonth(
        year: j['year'] as int,
        month: j['month'] as int,
        total: j['total'] as int? ?? 0,
        rate: j['rate'] as int? ?? 0,
      );
}

class InsightData {
  final String? bestHabitName;
  final int bestHabitRate;
  final String? worstHabitName;
  final int worstHabitRate;
  final String? weakDowLabel;
  final int weakDowRate;

  const InsightData({
    this.bestHabitName,
    required this.bestHabitRate,
    this.worstHabitName,
    required this.worstHabitRate,
    this.weakDowLabel,
    required this.weakDowRate,
  });

  factory InsightData.fromJson(Map<String, dynamic> j) => InsightData(
        bestHabitName: j['best_habit_name'] as String?,
        bestHabitRate: j['best_habit_rate'] as int? ?? 0,
        worstHabitName: j['worst_habit_name'] as String?,
        worstHabitRate: j['worst_habit_rate'] as int? ?? 0,
        weakDowLabel: j['weak_dow_label'] as String?,
        weakDowRate: j['weak_dow_rate'] as int? ?? 0,
      );
}

class StatsData {
  final int year;
  final int month;
  final List<HabitRate> habitRates;
  final List<DowAvg> dowAvgs;
  final ComparisonMonth? prevMonth;
  final ComparisonMonth? currMonth;
  final int totalDiff;
  final int rateDiff;
  final InsightData insight;

  const StatsData({
    required this.year,
    required this.month,
    required this.habitRates,
    required this.dowAvgs,
    this.prevMonth,
    this.currMonth,
    required this.totalDiff,
    required this.rateDiff,
    required this.insight,
  });

  factory StatsData.fromJson(Map<String, dynamic> j) {
    final heatmap = j['dow_heatmap'] as Map<String, dynamic>?;
    final comparison = j['comparison'] as Map<String, dynamic>?;
    return StatsData(
      year: j['year'] as int,
      month: j['month'] as int,
      habitRates: (j['habit_rates'] as List<dynamic>?)
              ?.map((e) => HabitRate.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      dowAvgs: (heatmap?['dow_avgs'] as List<dynamic>?)
              ?.map((e) => DowAvg.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      prevMonth: comparison?['prev'] != null
          ? ComparisonMonth.fromJson(comparison!['prev'] as Map<String, dynamic>)
          : null,
      currMonth: comparison?['curr'] != null
          ? ComparisonMonth.fromJson(comparison!['curr'] as Map<String, dynamic>)
          : null,
      totalDiff: comparison?['total_diff'] as int? ?? 0,
      rateDiff: comparison?['rate_diff'] as int? ?? 0,
      insight: InsightData.fromJson(
          j['insight'] as Map<String, dynamic>? ?? {}),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 草グラフ（ヒートマップ）モデル
// ─────────────────────────────────────────────────────────────

class HeatmapDay {
  final String date;      // 'YYYY-MM-DD'
  final int completed;    // 達成した習慣数
  final int exp;          // 獲得EXP
  final int pct;          // 量子化済み達成率 (0/25/50/75/100)
  final bool isToday;

  const HeatmapDay({
    required this.date,
    required this.completed,
    required this.exp,
    required this.pct,
    required this.isToday,
  });

  // BUG-G: バックエンドが空集計やキー欠落を返した場合でもクラッシュしないよう
  // すべての必須フィールドを null safe にする。
  factory HeatmapDay.fromJson(Map<String, dynamic> json) => HeatmapDay(
        date:      json['date']     as String? ?? '',
        completed: json['completed'] as int?   ?? 0,
        exp:       json['exp']       as int?   ?? 0,
        pct:       json['pct']       as int?   ?? 0,
        isToday:   json['is_today']  as bool?  ?? false,
      );
}

class HeatmapData {
  final List<HeatmapDay> days;
  final int totalHabits;

  const HeatmapData({required this.days, required this.totalHabits});

  factory HeatmapData.fromJson(Map<String, dynamic> json) => HeatmapData(
        days: (json['days'] as List<dynamic>?)
                ?.map((e) => HeatmapDay.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        totalHabits: json['total_habits'] as int? ?? 0,
      );
}

// ─────────────────────────────────────────────────────────────
// P1-3: カレンダー画面の bootstrap データ（3 in 1）
// ─────────────────────────────────────────────────────────────

/// `/api/calendar/bootstrap/?year=...&month=...&date=...` レスポンスモデル。
/// 月次グリッド・ストリーク・日次詳細の 3 データセットを 1 レスポンスにまとめる。
class CalendarBootstrapData {
  final CalendarData calendar;
  final StreakData   streak;
  final DailyData    daily;

  const CalendarBootstrapData({
    required this.calendar,
    required this.streak,
    required this.daily,
  });

  factory CalendarBootstrapData.fromJson(Map<String, dynamic> json) =>
      CalendarBootstrapData(
        calendar: CalendarData.fromJson(json['calendar'] as Map<String, dynamic>),
        streak:   StreakData.fromJson(json['streak']     as Map<String, dynamic>),
        daily:    DailyData.fromJson(json['daily']       as Map<String, dynamic>),
      );

  /// 【FEAT-504】Google イベント merge 後に daily を置換するため。
  CalendarBootstrapData copyWith({DailyData? daily}) => CalendarBootstrapData(
        calendar: calendar,
        streak:   streak,
        daily:    daily ?? this.daily,
      );
}

// ── 日別詳細データ（CAL-01）────────────────────────────────────────────────

/// 日別習慣アイテム（通常習慣用）
class DailyHabit {
  final int id;
  final String name;
  final String category;
  final String difficulty;
  final String priority; // 'high'|'medium'|'low'
  final bool done;
  final int count;

  const DailyHabit({
    required this.id,
    required this.name,
    required this.category,
    required this.difficulty,
    required this.priority,
    required this.done,
    required this.count,
  });

  factory DailyHabit.fromJson(Map<String, dynamic> j) => DailyHabit(
        id:         j['id']         as int,
        name:       j['name']       as String? ?? '',
        category:   j['category']   as String? ?? '',
        difficulty: j['difficulty'] as String? ?? 'normal',
        priority:   j['priority']   as String? ?? 'medium',
        done:       j['done']       as bool?   ?? false,
        count:      j['count']      as int?    ?? 0,
      );
}

/// 日別 ToDo アイテム
class DailyTodo {
  final int id;
  final String name;
  final String priority; // 'high'|'medium'|'low'
  final DateTime? dueDate;
  final bool done;

  const DailyTodo({
    required this.id,
    required this.name,
    required this.priority,
    required this.dueDate,
    required this.done,
  });

  factory DailyTodo.fromJson(Map<String, dynamic> j) => DailyTodo(
        id:       j['id']       as int,
        name:     j['name']     as String? ?? '',
        priority: j['priority'] as String? ?? 'medium',
        dueDate:  j['due_date'] != null
            ? DateTime.tryParse(j['due_date'] as String)
            : null,
        done:     j['done']     as bool?   ?? false,
      );
}

/// カレンダー日次ビューのタイムライン予定
class DailyTimeline {
  final int     id;
  final String  title;
  final String  category;
  final String  iconKey;
  final String? startTime;      // 'HH:MM' or null
  final String? endTime;        // 'HH:MM' or null
  final bool    isCompleted;
  final String  memo;
  final String  source;         // BUG-17: 'local' | 'google' | 'apple'
  final String? googleEventId;  // 【FEAT-504】Google カレンダー由来のみ非 null

  const DailyTimeline({
    required this.id,
    required this.title,
    required this.category,
    required this.iconKey,
    this.startTime,
    this.endTime,
    required this.isCompleted,
    this.memo         = '',
    this.source       = 'local',
    this.googleEventId,
  });

  factory DailyTimeline.fromJson(Map<String, dynamic> j) => DailyTimeline(
        id:          j['id']           as int,
        title:       j['title']        as String? ?? '',
        category:    j['category']     as String? ?? 'other',
        iconKey:     j['icon_key']     as String? ?? 'event',
        startTime:   j['start_time']   as String?,
        endTime:     j['end_time']     as String?,
        isCompleted: j['is_completed'] as bool?   ?? false,
        memo:        j['memo']         as String? ?? '',
        source:      j['source']       as String? ?? 'local',
      );

  /// 【FEAT-504 (2026-07-29)】LocalGoogleEventStore の GoogleEvent から合成。
  /// id は hashCode 反転で負値を割り当て、サーバー id との衝突を防ぐ。
  factory DailyTimeline.fromGoogleEvent({
    required String googleEventId,
    required String title,
    String? startTime,
    String? endTime,
    String? memo,
    bool isCompleted = false,
  }) =>
      DailyTimeline(
        id:            -(googleEventId.hashCode.abs()),
        googleEventId: googleEventId,
        title:         title,
        category:      'その他',
        iconKey:       'event',
        startTime:     startTime,
        endTime:       endTime,
        isCompleted:   isCompleted,
        memo:          memo ?? '',
        source:        'google',
      );

  /// 外部カレンダー（Google / Apple 等）由来のイベントかどうか
  bool get isExternal => source != 'local';
}

/// `/api/calendar/daily/` レスポンスモデル
class DailyData {
  final DateTime            date;
  final bool                isToday;
  final bool                isFuture;
  final List<DailyHabit>    habits;
  final List<DailyTodo>     todos;
  final List<DailyTimeline> timeline;

  const DailyData({
    required this.date,
    required this.isToday,
    required this.isFuture,
    required this.habits,
    required this.todos,
    this.timeline = const [],
  });

  factory DailyData.fromJson(Map<String, dynamic> j) => DailyData(
        // NEW-13: tryParse でクラッシュ回避。不正フォーマット時は今日の日付にフォールバック。
        date:     DateTime.tryParse(j['date'] as String? ?? '') ?? DateTime.now(),
        isToday:  j['is_today']  as bool? ?? false,
        isFuture: j['is_future'] as bool? ?? false,
        habits: (j['habits'] as List<dynamic>?)
                ?.map((e) => DailyHabit.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        todos: (j['todos'] as List<dynamic>?)
               ?.map((e) => DailyTodo.fromJson(e as Map<String, dynamic>))
               .toList() ??
            [],
        timeline: (j['timeline_events'] as List<dynamic>?)
                  ?.map((e) => DailyTimeline.fromJson(e as Map<String, dynamic>))
                  .toList() ??
            [],
      );

  /// 【FEAT-504】Google イベント merge 後に新しいタイムラインリストで置換するため。
  DailyData copyWith({List<DailyTimeline>? timeline}) => DailyData(
        date:     date,
        isToday:  isToday,
        isFuture: isFuture,
        habits:   habits,
        todos:    todos,
        timeline: timeline ?? this.timeline,
      );
}
