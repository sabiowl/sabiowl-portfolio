/// 【FEAT-467 (2026-07-02)】タスク候補 — タイトル入力 popup の選択肢。
///
/// Backend `/api/task-suggestions/?type=<event|todo|habit>` のレスポンスを
/// そのままマッピングする。plain class + fromJson パターン (freezed 不使用)。
///
/// 【2026-07-07】端末ローカル (SharedPreferences) にユーザーが追加したカスタム
/// 候補を保存するため、type ごとに form state を再現するための nullable field を
/// 追加した。Backend レスポンスにはこれらの field は含まれない (null になる)。
/// custom 保存経路 (`CustomSuggestionStore.upsert`) では該当 field を注入し、
/// 次回同じ title を選択した時に caller (add_event_page / add_todo_page /
/// add_habit_page) が form state を復元する。
///
/// ## Nullable field の用途 (type 別)
///
/// | field       | event | todo | habit | 説明 |
/// |-------------|:-----:|:----:|:-----:|------|
/// | timeSlot    |  ✅   |      |       | 'none' / 'am' / 'pm' / 'custom' |
/// | memo        |  ✅   | ✅   |  ✅   | 自由記述 |
/// | priority    |       | ✅   |       | 'low' / 'medium' / 'high' |
/// | difficulty  |       | ✅   |       | 'easy' / 'normal' / 'hard' / 'legendary' |
/// | habitType   |       |      |  ✅   | 'count' / 'checklist' |
/// | frequency   |       |      |  ✅   | 'daily' / 'weekly' / 'monthly' |
/// | resetCycle  |       |      |  ✅   | 'daily' / 'weekly' / 'monthly' / 'yearly' |
class TaskSuggestion {
  final int    id;
  final String type;
  final String title;
  final String category;
  final String emoji;
  final String hint;
  final int    order;

  // ── 【2026-07-07】端末ローカル custom 保存用 nullable field ────────────
  // Backend レスポンスには含まれない (null)。custom upsert で該当 type の
  // form state を注入する。次回同 title を選択したとき form 自動入力に使う。
  final String? timeSlot;    // event
  final String? memo;        // event / todo / habit
  final String? priority;    // todo
  final String? difficulty;  // todo
  final String? habitType;   // habit
  final String? frequency;   // habit
  final String? resetCycle;  // habit

  const TaskSuggestion({
    required this.id,
    required this.type,
    required this.title,
    required this.category,
    required this.emoji,
    required this.hint,
    required this.order,
    this.timeSlot,
    this.memo,
    this.priority,
    this.difficulty,
    this.habitType,
    this.frequency,
    this.resetCycle,
  });

  factory TaskSuggestion.fromJson(Map<String, dynamic> json) => TaskSuggestion(
        id:         json['id']       as int,
        type:       json['type']     as String,
        title:      json['title']    as String,
        category:   json['category'] as String? ?? '',
        emoji:      json['emoji']    as String? ?? '',
        hint:       json['hint']     as String? ?? '',
        order:      json['order']    as int? ?? 0,
        // 【2026-07-07】nullable field 読出。Backend レスポンスには存在しない
        // ので通常は null (JSON 未定義キーは Map から null が返る)。
        timeSlot:   json['timeSlot']   as String?,
        memo:       json['memo']       as String?,
        priority:   json['priority']   as String?,
        difficulty: json['difficulty'] as String?,
        habitType:  json['habitType']  as String?,
        frequency:  json['frequency']  as String?,
        resetCycle: json['resetCycle'] as String?,
      );

  /// 【2026-07-07】端末ローカル (SharedPreferences) 保存用シリアライズ。
  ///
  /// `CustomSuggestionStore` が JSON list として persist する。
  /// Backend からは受け取り専用なので `fromJson` のみで足りていたが、
  /// ローカルカスタム候補の書き込み経路が加わったため対称的な `toJson` を追加。
  /// nullable field も含めて書き出す (null は JSON に載る = 明示 null)。
  Map<String, dynamic> toJson() => {
        'id':         id,
        'type':       type,
        'title':      title,
        'category':   category,
        'emoji':      emoji,
        'hint':       hint,
        'order':      order,
        'timeSlot':   timeSlot,
        'memo':       memo,
        'priority':   priority,
        'difficulty': difficulty,
        'habitType':  habitType,
        'frequency':  frequency,
        'resetCycle': resetCycle,
      };
}
