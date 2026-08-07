import 'package:flutter/material.dart';
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】

// ── カテゴリ別カード色（FEAT-288、4 値暫定）──────────────────────────────────
// 【FEAT-288】Backend CATEGORY_CHOICES（11 値）の真実値に統一。'メンタル' は
// migration 0066 で死語化済 → '精神' に置換。完全 11 値展開は Phase 2 で実施。
// 旧 6 カテゴリ英語コード（habit/health/work/rest/social/other）は別マッピング
// ルートで日本語値へバックフィル（マイグレーション 0065 + Flutter ローカル _load() 内）。
// 色は習慣画面（add_habit_page.dart の `_categories`）と完全に同色にすることで、
// カテゴリの視覚的同一性をアプリ全体で保つ。
const Map<String, Color> kTimelineCardColors = {
  '運動': Color(0xFFF87171),
  '学習': Color(0xFF60A5FA),
  '健康': Color(0xFF34D399),
  '精神': Color(0xFFA78BFA),
};

// ── アイコンマッピング（iconKey → IconData） ────────────────────────────────
const Map<String, IconData> kTimelineIconMap = {
  'wb_sunny':         Icons.wb_sunny_outlined,
  'restaurant':       Icons.restaurant_outlined,
  'directions_run':   Icons.directions_run,
  'menu_book':        Icons.menu_book_outlined,
  'self_improvement': Icons.self_improvement,
  'groups':           Icons.groups_outlined,
  'work':             Icons.work_outline,
  'bedtime':          Icons.bedtime_outlined,
  'event':            Icons.event_outlined,
};

/// タイムラインイベントの Dart モデル。
class TimelineEvent {
  final int       id;
  final String    title;
  final DateTime  date;
  final TimeOfDay? startTime;
  final TimeOfDay? endTime;
  final String    category;
  final String    iconKey;
  final String    memo;
  final int?      habitId;
  final bool      isCompleted;
  /// 【FEAT-244】Sabiowl → Google push 後に保存される Google 側イベント ID。
  /// 編集・削除時に Google 側を追随更新するために使う。null = 未 push。
  final String?   googleEventId;
  /// 【FEAT-426】true = Google カレンダー由来（LocalGoogleEventStore から merge）。
  /// この場合 [id] は実 Backend PK ではなくプレースホルダーであり、完了トグルは
  /// `GoogleEventCompletionService` 経由で [googleEventId] を使う。
  final bool      isGoogleOrigin;

  const TimelineEvent({
    required this.id,
    required this.title,
    required this.date,
    this.startTime,
    this.endTime,
    required this.category,
    required this.iconKey,
    this.memo = '',
    this.habitId,
    required this.isCompleted,
    this.googleEventId,
    this.isGoogleOrigin = false,
  });

  factory TimelineEvent.fromJson(Map<String, dynamic> json) {
    // BUG-D: 不正なペイロード（null / 空文字 / 非数値）を受け取っても
    // タイムライン画面が真っ白にならないよう全フィールドを null safe にする。
    TimeOfDay? parseTime(String? t) {
      if (t == null || t.isEmpty) return null;
      final parts = t.split(':');
      if (parts.length < 2) return null;
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h == null || m == null) return null;
      return TimeOfDay(hour: h, minute: m);
    }

    return TimelineEvent(
      id:          json['id']          as int?    ?? 0,
      title:       json['title']       as String? ?? '',
      date:        DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
      startTime:   parseTime(json['start_time'] as String?),
      endTime:     parseTime(json['end_time']   as String?),
      category:    json['category']    as String? ?? 'other',
      iconKey:     json['icon_key']    as String? ?? 'event',
      memo:        json['memo']        as String? ?? '',
      habitId:     json['habit']       as int?,
      isCompleted: json['is_completed'] as bool?  ?? false,
      // 【FEAT-244】Backend Serializer の read_only field。null = 未 push。
      googleEventId: json['google_event_id'] as String?,
    );
  }

  /// 開始〜終了の表示文字列（例: 07:00 - 07:30）
  String get timeRangeLabel {
    if (startTime == null) return ServiceL10n.current.timelineEventNoTimeLabel;
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (endTime == null) return fmt(startTime!);
    return '${fmt(startTime!)} - ${fmt(endTime!)}';
  }

  /// 所要時間（分）。startTime / endTime が null なら 0
  int get durationMinutes {
    if (startTime == null || endTime == null) return 0;
    return (endTime!.hour * 60 + endTime!.minute) -
        (startTime!.hour * 60 + startTime!.minute);
  }

  /// isCompleted を反転したコピーを返す（楽観的 UI 用）
  TimelineEvent copyWith({bool? isCompleted, String? googleEventId}) {
    return TimelineEvent(
      id:          id,
      title:       title,
      date:        date,
      startTime:   startTime,
      endTime:     endTime,
      category:    category,
      iconKey:     iconKey,
      memo:        memo,
      habitId:     habitId,
      isCompleted: isCompleted   ?? this.isCompleted,
      // 【FEAT-244】push 完了直後の楽観的更新で googleEventId を差し込む用途
      googleEventId: googleEventId ?? this.googleEventId,
      isGoogleOrigin: isGoogleOrigin,
    );
  }

  /// 【FEAT-426】[GoogleEvent]（ローカル DB）+ Backend completion 状態を
  /// マージして [TimelineEvent] 互換の表示用モデルを組み立てる。
  ///
  /// [id] は実 Backend PK が存在しないため負数のプレースホルダーを使う
  /// （`google_event_id` の hashCode、衝突時も完了トグルは
  /// [isGoogleOrigin] + [googleEventId] 経由のため実害なし）。
  factory TimelineEvent.fromGoogleEvent({
    required String googleEventId,
    required String title,
    required DateTime date,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    String memo = '',
    required bool isCompleted,
  }) {
    return TimelineEvent(
      id:          -googleEventId.hashCode.abs() - 1,
      title:       title,
      date:        date,
      startTime:   startTime,
      endTime:     endTime,
      category:    'other',
      iconKey:     'event',
      memo:        memo,
      isCompleted: isCompleted,
      googleEventId:  googleEventId,
      isGoogleOrigin: true,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TimelineTemplate — デフォルト予定テンプレート
// ─────────────────────────────────────────────────────────────────────────────

/// copyWith の nullable フィールド（timeSlot）向けセンチネル。
const Object _kTimelineTemplateSentinel = Object();

/// 時間帯プリセット一覧。
/// （id, ラベル, 絵文字, startHour, startMinute, endHour, endMinute）
/// id == 'custom' のものは -1 を sentinel とし、時刻を手動入力させる。
/// 【FEAT-489 Phase 2F-a】ラベルが locale 依存になったため `const` → getter 化。
/// 第 1 要素 (id) は保存値 (`TimelineTemplate.timeSlot`) の key なので **不変**。
/// BuildContext を持たない model 層なので [ServiceL10n] 経由で解決する。
List<(String, String, String, int, int, int, int)> get kTimeSlotPresets => [
      ('morning',   ServiceL10n.current.timelineTimeSlotMorning,   '☀️',  6,  0,  8,  0),
      ('noon',      ServiceL10n.current.timelineTimeSlotNoon,      '🌤️', 12,  0, 13,  0),
      ('afternoon', ServiceL10n.current.timelineTimeSlotAfternoon, '🌆', 15,  0, 17,  0),
      ('evening',   ServiceL10n.current.timelineTimeSlotEvening,   '🌙', 20,  0, 22,  0),
      ('custom',    ServiceL10n.current.timelineTimeSlotCustom,    '🕐', -1, -1, -1, -1),
    ];

/// ユーザーが毎日自動挿入したい「定型予定」を表すモデル。
///
/// SharedPreferences に JSON として保存し、[TimelineTemplatesNotifier] で管理する。
/// [isEnabled] が true の予定は、その日の初回起動時にタイムラインへ自動作成される。
class TimelineTemplate {
  final String  id;
  final String  title;
  final int     startHour;
  final int     startMinute;
  final int     endHour;
  final int     endMinute;
  final String  category;
  final String  iconKey;
  final bool    isEnabled;
  /// [kTimeSlotPresets] の id、または null（未設定 = カスタム）。
  final String? timeSlot;
  /// 【FEAT-196】サビメッセージ等を保存するメモ。
  /// `timelineAutoCreateProvider` のテンプレート自動展開時にサーバーへ送信され、
  /// 作成された [TimelineEvent.memo] に反映される。
  /// 既存ユーザーの SharedPreferences には未保存のため、[fromJson] では空文字
  /// フォールバック付き。テンプレート編集 UI への入力欄追加は本 FEAT のスコープ外
  /// （内部利用にとどめる方針 — PM 合意 (b)）。
  final String  memo;

  const TimelineTemplate({
    required this.id,
    required this.title,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.category,
    required this.iconKey,
    this.isEnabled = true,
    this.timeSlot,
    this.memo = '',
  });

  /// 全フィールドを個別に上書きできる copyWith。
  /// [timeSlot] のみ nullable なため sentinel パターンを使用。
  TimelineTemplate copyWith({
    String?  id,
    String?  title,
    int?     startHour,
    int?     startMinute,
    int?     endHour,
    int?     endMinute,
    String?  category,
    String?  iconKey,
    bool?    isEnabled,
    Object?  timeSlot = _kTimelineTemplateSentinel,
    String?  memo,
  }) {
    return TimelineTemplate(
      id:          id          ?? this.id,
      title:       title       ?? this.title,
      startHour:   startHour   ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      endHour:     endHour     ?? this.endHour,
      endMinute:   endMinute   ?? this.endMinute,
      category:    category    ?? this.category,
      iconKey:     iconKey     ?? this.iconKey,
      isEnabled:   isEnabled   ?? this.isEnabled,
      timeSlot: identical(timeSlot, _kTimelineTemplateSentinel)
          ? this.timeSlot
          : timeSlot as String?,
      memo:        memo        ?? this.memo,
    );
  }

  Map<String, dynamic> toJson() => {
    'id':          id,
    'title':       title,
    'startHour':   startHour,
    'startMinute': startMinute,
    'endHour':     endHour,
    'endMinute':   endMinute,
    'category':    category,
    'iconKey':     iconKey,
    'isEnabled':   isEnabled,
    if (timeSlot != null) 'timeSlot': timeSlot,
    'memo':        memo,
  };

  factory TimelineTemplate.fromJson(Map<String, dynamic> json) {
    return TimelineTemplate(
      id:          json['id']          as String,
      title:       json['title']       as String,
      startHour:   json['startHour']   as int,
      startMinute: json['startMinute'] as int,
      endHour:     json['endHour']     as int,
      endMinute:   json['endMinute']   as int,
      category:    json['category']    as String,
      iconKey:     json['iconKey']     as String,
      isEnabled:   json['isEnabled']   as bool? ?? true,
      timeSlot:    json['timeSlot']    as String?,
      // 【FEAT-196】既存ユーザーには memo フィールドが未保存のため空文字フォールバック
      memo:        json['memo']        as String? ?? '',
    );
  }
}

/// アプリ初期値テンプレート。
///
/// 【FEAT-196】FEAT-179 で導入したサーバー側 `seed_default._DEFAULT_TIMELINE_EVENTS`
/// と二重管理になっていた問題を解消するため、本テンプレートを 4 件（起床/ランチ/
/// 昼寝/就寝）に拡張し、サーバー側のタイムライン seed は撤回した。`memo` に
/// サビ口調のメッセージを仕込んでおき、`timelineAutoCreateProvider` がテンプレートを
/// 個別予定として自動展開する際にサーバー側 TimelineEvent.memo に反映される。
/// 【FEAT-208】全 category を CLAUDE.md 4 値（運動/学習/健康/メンタル）の「健康」に
/// 統一。FEAT-196 では 'health'（英語コード）を使っていたが、FEAT-201 の習慣カテゴリ
/// 4 値統一と整合させ、タイムラインも `'健康'` を使う。既存ユーザーの SharedPreferences
/// に保存された旧コード値（habit / health / work / rest / social / other）は
/// `TimelineTemplatesNotifier._load()` 内で自動バックフィルされる。
///
/// 【新規 (2026-06-25)】PM 指示により 4 件 → 7 件構成に拡張:
/// 起床(07:00-08:00) / モーニング(08:00-09:00) / ランチ(12:00-13:00) /
/// 昼寝(12:30-13:00) / おやつ(15:00-15:30) / ディナー(19:00-21:00) /
/// 就寝(22:00-23:59) の 7 件。新規登録ユーザーが初日からタイムラインを
/// 「整った 1 日のリズム」として体感できることを意図する。
///
/// 既存ユーザー (SharedPreferences に旧 4 件テンプレートが保存済) は
/// `TimelineTemplatesNotifier._load()` で個別 customization を保持するため
/// 影響なし。新規登録 (SharedPreferences 未保存) のみ本 7 件構成が適用される。
///
/// 注: 「就寝 22:00-24:00」の指示は TimeOfDay (hour 0-23) 制約により 23:59 で
/// 代替実装。ユーザー操作で 22:00-23:59 に丸めて表示される。
/// 注: 「ランチ 12:00-13:00 + 昼寝 12:30-13:00」は重複しているが、PM 指示通り
/// honor (タイムライン上は両方並列に表示される)。
/// 【FEAT-489 Phase 2F-a】title / memo が locale 依存になったため `const` → getter 化。
///
/// 本リストは **SharedPreferences が空のときの初期値** としてのみ使われる
/// (`TimelineTemplatesNotifier`)。一度保存された後はユーザーデータなので、
/// locale を切り替えても既存の保存済みテンプレートは書き換わらない
/// (= 「英語に切り替えたら自分で編集した予定名が消えた」事故が起きない設計)。
///
/// `id` / `category` / `iconKey` は保存値・API 値なので **不変**。
List<TimelineTemplate> get kDefaultTemplates => <TimelineTemplate>[
  TimelineTemplate(
    id:          'wake',
    title:       ServiceL10n.current.timelineTemplateWakeTitle,
    startHour:   7,
    startMinute: 0,
    endHour:     8,
    endMinute:   0,
    category:    '健康',
    iconKey:     'wb_sunny',
    isEnabled:   true,
    memo:        ServiceL10n.current.timelineTemplateWakeMemoSabi_message,
  ),
  TimelineTemplate(
    id:          'morning',
    title:       ServiceL10n.current.timelineTemplateMorningTitle,
    startHour:   8,
    startMinute: 0,
    endHour:     9,
    endMinute:   0,
    category:    '健康',
    iconKey:     'restaurant',
    isEnabled:   true,
    memo:        ServiceL10n.current.timelineTemplateMorningMemoSabi_message,
  ),
  TimelineTemplate(
    id:          'lunch',
    title:       ServiceL10n.current.timelineTemplateLunchTitle,
    startHour:   12,
    startMinute: 0,
    endHour:     13,
    endMinute:   0,
    category:    '健康',
    iconKey:     'restaurant',
    isEnabled:   true,
    memo:        ServiceL10n.current.timelineTemplateLunchMemoSabi_message,
  ),
  TimelineTemplate(
    id:          'nap',
    title:       ServiceL10n.current.timelineTemplateNapTitle,
    startHour:   12,
    startMinute: 30,
    endHour:     13,
    endMinute:   0,
    category:    '健康',
    iconKey:     'self_improvement',
    isEnabled:   true,
    memo:        ServiceL10n.current.timelineTemplateNapMemoSabi_message,
  ),
  TimelineTemplate(
    id:          'snack',
    title:       ServiceL10n.current.timelineTemplateSnackTitle,
    startHour:   15,
    startMinute: 0,
    endHour:     15,
    endMinute:   30,
    category:    '健康',
    iconKey:     'restaurant',
    isEnabled:   true,
    memo:        ServiceL10n.current.timelineTemplateSnackMemoSabi_message,
  ),
  TimelineTemplate(
    id:          'dinner',
    title:       ServiceL10n.current.timelineTemplateDinnerTitle,
    startHour:   19,
    startMinute: 0,
    endHour:     21,
    endMinute:   0,
    category:    '健康',
    iconKey:     'restaurant',
    isEnabled:   true,
    memo:        ServiceL10n.current.timelineTemplateDinnerMemoSabi_message,
  ),
  TimelineTemplate(
    id:          'sleep',
    title:       ServiceL10n.current.timelineTemplateSleepTitle,
    startHour:   22,
    startMinute: 0,
    endHour:     23,
    endMinute:   59,
    category:    '健康',
    iconKey:     'bedtime',
    isEnabled:   true,
    memo:        ServiceL10n.current.timelineTemplateSleepMemoSabi_message,
  ),
];
