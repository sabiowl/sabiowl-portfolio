import 'dart:convert';
import 'package:flutter/foundation.dart';  // 【FEAT-370】debugPrint (offline skip log)
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/dio_error_helper.dart';  // 【FEAT-402】
import '../../../core/cache/cache_config.dart';  // 【FEAT-280】
import '../../../core/cache/cache_service.dart';  // 【FEAT-280】
import '../../../core/cache/connectivity_indicator.dart';  // 【FEAT-280】
import '../../../core/services/connectivity_service.dart';  // 【FEAT-370】isOnlineProvider
import '../../calendar/providers/calendar_provider.dart';  // 【FEAT-244/268/426】
import '../../calendar/services/google_event_completion_service.dart';  // 【FEAT-426】
import '../models/timeline_models.dart';
import '../services/timeline_service.dart';

export '../models/timeline_models.dart';

/// 【FEAT-280】timelineEventsProvider のキャッシュキープレフィックス。
/// `timeline_events:YYYY-MM-DD` で日付単位の名前空間を切る。
/// `invalidateByPrefix('timeline_events:')` で全日付一括クリア可能。
const _kTimelineEventsCachePrefix = 'timeline_events:';

/// 【FEAT-506 (2026-07-29)】デフォルト予定 auto-create の Global toggle キー。
/// OFF なら timelineAutoCreateProvider が早期 return し、per-template toggle の
/// 状態に関係なく全 default 予定作成を停止する。default: true。
const _kAutoCreateEnabledKey = 'timeline_auto_create_enabled';

/// Global toggle の現在値を SharedPreferences から取得。
Future<bool> _isAutoCreateEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kAutoCreateEnabledKey) ?? true;
}

String _timelineCacheKey(DateTime date) {
  final ymd = '${date.year}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  return '$_kTimelineEventsCachePrefix$ymd';
}

/// 当日 / 未来 → 短 TTL、過去 → 長 TTL。
Duration _timelineTtl(DateTime date) {
  final now      = DateTime.now();
  final today    = DateTime(now.year, now.month, now.day);
  final targetDay = DateTime(date.year, date.month, date.day);
  return targetDay.isBefore(today)
      ? CacheConfig.timelinePast
      : CacheConfig.timelineToday;
}

/// 【FEAT-280】write 操作（create/update/delete）後に呼ぶ：
/// 全日付の timeline キャッシュを無効化する。
/// 日付跨ぎの編集（リスケ）にも対応するため安全側の prefix 削除を採用。
Future<void> invalidateTimelineCache(Ref ref) async {
  await ref.read(cacheServiceProvider)
      .invalidateByPrefix(_kTimelineEventsCachePrefix);
}

// 【2026-07-07】FEAT-163「最近の予定」機能撤廃に伴い、SharedPreferences キー定数と
// 保存件数上限を削除。既存端末に残っている 'recent_event_titles_v1' キーは
// SharedPreferences に orphan として残るが、読出コードを撤去したため実質無害
// (次回 clear 系のメンテで自然消滅、explicit cleanup migration は不要)。

// ── サービス ───────────────────────────────────────────────────────────────
final timelineServiceProvider = Provider<TimelineService>((ref) {
  // 【FEAT-244/268】GoogleCalendarSyncService を依存注入。createEvent / updateEvent /
  // deleteEvent 後段で fire-and-forget の Google push を起動するために必要。
  // 【FEAT-280】CacheService も注入し、write 後にキャッシュ invalidate する。
  return TimelineService(
    ref.watch(apiClientProvider),
    ref.watch(googleCalendarSyncServiceProvider),
    ref.watch(cacheServiceProvider),
  );
});

// ── 選択中の日付（時刻を切り捨てた "今日" で初期化） ─────────────────────
final selectedDateProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

// ── タイムラインイベント（日付をキーに autoDispose） ─────────────────────
//
// 【FEAT-280】SWR 化: FutureProvider.family → StreamProvider.family。
// キャッシュ即時 yield → 並行 API fetch → 差分があれば fresh yield。
// オフライン時は cached を維持して ConnectivityIndicator.markOffline。
// 既存 consumer `.when(data:, loading:, error:)` パターンは変更不要。
final timelineEventsProvider =
    StreamProvider.autoDispose.family<List<TimelineEvent>, DateTime>(
  (ref, date) async* {
    final service = ref.watch(timelineServiceProvider);
    final cache   = ref.read(cacheServiceProvider);
    final conn    = ref.read(connectivityProvider.notifier);
    final cacheKey = _timelineCacheKey(date);

    // 1. キャッシュ即時表示（List<Map> → List<TimelineEvent> に変換）
    final cached = cache.getList(cacheKey);
    List<TimelineEvent>? cachedEvents;
    // 【20260729 review §8-2 対応】直前に yield した「merge 済み」リスト。
    // fresh 側の差分判定はこれと比較する（理由は下記 2. のコメント参照）。
    List<TimelineEvent>? lastYielded;
    if (cached != null) {
      try {
        cachedEvents = cached.data
            .map((e) => TimelineEvent.fromJson(e as Map<String, dynamic>))
            .toList();
        // 【20260729 review §2 対応】cached 経路では fetchCompletions=false:
        // 端末内 store のみで即 yield、completions の HTTP 往復を待たない。
        lastYielded = await _mergeWithGoogleEvents(
          ref, date, cachedEvents,
          fetchCompletions: false,
        );
        yield lastYielded;
      } catch (_) {
        // パース失敗（モデル変更等）→ キャッシュ破棄
        await cache.invalidate(cacheKey);
        cachedEvents = null;
        lastYielded  = null;
      }
    }

    // 2. API fetch を試行
    if (cachedEvents != null) conn.markFetching();
    try {
      final fresh = await service.fetchEvents(date);
      // 【20260729 review §8-2 対応】completions 込みで merge してから差分判定する。
      //
      // 旧実装は `_eventListsEqual(cachedEvents, fresh)` = **backend イベント同士**
      // を比較していた。Google 予定は backend の TimelineEvent 行ではないため、
      // 完了状態がどう変わってもこの比較には現れず、「キャッシュが生きていて
      // backend 予定に変化がない」という最も普通のケースで fresh yield ごと skip
      // されていた。§2 対応で cached 経路から completions を外した結果、
      // completions を取得する経路が fresh yield ただ 1 つになったため、この skip は
      // 「Google 予定の完了チェックが一度も反映されない」= 完了したはずの記録が
      // Home から消えて見える退行になっていた（過去日は TTL 7 日間継続）。
      //
      // 比較対象を「実際に yield する merge 済みリスト」に変えることで、
      // backend 行が同一でも Google 予定の完了状態が変われば差分として検出される。
      // `_eventListsEqual` は googleEventId / isCompleted を比較項目に含むため、
      // チラつき防止という本来の意図はそのまま保たれる。
      final freshMerged = await _mergeWithGoogleEvents(ref, date, fresh);
      if (lastYielded == null || !_eventListsEqual(lastYielded, freshMerged)) {
        yield freshMerged;
      }
      // 保存: TimelineEvent を List<Map> に変換
      final freshJson = fresh.map(_timelineEventToJson).toList();
      await cache.setList(
        cacheKey,
        freshJson,
        ttl: _timelineTtl(date),
      );
      conn.markOnline();
    } catch (e) {
      // 【FEAT-402】真のネットワーク系のみ markOffline、HTTP 4xx/5xx 等は
      // markOnline 維持 (サーバー応答あり = 実質オンライン)。
      if (isNetworkError(e)) {
        conn.markOffline(e.toString());
      } else {
        conn.markOnline();
      }
      if (cachedEvents == null) rethrow;
    }
  },
);

/// TimelineEvent の JSON 化（fromJson と対称）。
/// `created_at` / `google_event_id` 等の read_only フィールドも保存して
/// 復元時に元の状態を完全に再現する。
Map<String, dynamic> _timelineEventToJson(TimelineEvent e) {
  return {
    'id':              e.id,
    'title':           e.title,
    'date':            '${e.date.year}-'
        '${e.date.month.toString().padLeft(2, '0')}-'
        '${e.date.day.toString().padLeft(2, '0')}',
    'start_time':      e.startTime == null
        ? null
        : '${e.startTime!.hour.toString().padLeft(2, '0')}:'
          '${e.startTime!.minute.toString().padLeft(2, '0')}:00',
    'end_time':        e.endTime == null
        ? null
        : '${e.endTime!.hour.toString().padLeft(2, '0')}:'
          '${e.endTime!.minute.toString().padLeft(2, '0')}:00',
    'category':        e.category,
    'icon_key':        e.iconKey,
    'memo':            e.memo,
    'habit':           e.habitId,
    'is_completed':    e.isCompleted,
    'google_event_id': e.googleEventId,
  };
}

/// イベントリストの等価判定（UI 瞬き防止）。
/// 主要フィールド（id / title / time / completed）を比較。
bool _eventListsEqual(List<TimelineEvent> a, List<TimelineEvent> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.id != y.id ||
        x.title != y.title ||
        x.isCompleted != y.isCompleted ||
        x.startTime != y.startTime ||
        x.endTime != y.endTime ||
        x.category != y.category ||
        x.memo != y.memo ||
        x.googleEventId != y.googleEventId) {
      return false;
    }
  }
  return true;
}

/// 【FEAT-426】Backend TimelineEvent（source='local'）に LocalGoogleEventStore
/// の Google 由来予定 + Backend completion 状態をマージして返す。
///
/// 【Pre-mortem S4】sqflite 初期化失敗（端末ストレージ逼迫等）時は例外を握り潰し
/// `backendEvents` のみで継続表示する（タイムライン全体を壊さない）。
///
/// 【20260729 review §2 懸念点 1 対応】`fetchCompletions` フラグ追加。
/// cached yield 経路では `false` を渡す = 端末 store のみで即 yield し、
/// completions の HTTP 往復 (Render コールドスタート時最大 60 秒) を待たない。
/// 完了チェックは直後の fresh yield (デフォルト true) で確定する。
Future<List<TimelineEvent>> _mergeWithGoogleEvents(
  Ref ref,
  DateTime date,
  List<TimelineEvent> backendEvents, {
  bool fetchCompletions = true,
}) async {
  try {
    final store = ref.read(localGoogleEventStoreProvider);
    final googleEvents = await store.queryByDateRange(date, date);
    if (googleEvents.isEmpty) return backendEvents;

    Map<String, GoogleEventCompletion> completions = {};
    if (fetchCompletions) {
      try {
        final completionService = ref.read(googleEventCompletionServiceProvider);
        final list = await completionService.fetchAll(dateFrom: date, dateTo: date);
        completions = {for (final c in list) c.googleEventId: c};
      } catch (_) {
        // オフライン等で取得失敗 → 完了状態は未反映のまま表示（次回 invalidate で再取得）
      }
    }

    final merged = <TimelineEvent>[
      ...backendEvents,
      ...googleEvents.map((g) {
        final completion = completions[g.googleEventId];
        return TimelineEvent.fromGoogleEvent(
          googleEventId: g.googleEventId,
          title:         g.title,
          date:          g.date,
          startTime:     g.startTime,
          endTime:       g.endTime,
          memo:          g.memo,
          isCompleted:   completion?.isCompleted ?? false,
        );
      }),
    ];

    merged.sort((a, b) {
      final at = a.startTime;
      final bt = b.startTime;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return (at.hour * 60 + at.minute).compareTo(bt.hour * 60 + bt.minute);
    });

    return merged;
  } catch (e) {
    debugPrint('[timelineEventsProvider] Google event merge failed: $e');
    return backendEvents;
  }
}

// ── 週アンカー日付（週ページングの基準日） ─────────────────────────────────
/// TimelineDateStrip の PageView がどの週を表示中かを管理する。
/// 初期値は今日。カレンダーピッカーや "今日" ボタンで更新される。
final weekAnchorDateProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

// ── 週の日付一覧（weekAnchorDate を中央とした前後 3 日 = 計 7 日） ─────────
final weekDatesProvider = Provider<List<DateTime>>((ref) {
  final base = ref.watch(weekAnchorDateProvider);
  // index 0 = anchor-3, index 3 = anchor（中央）, index 6 = anchor+3
  return List.generate(7, (i) => base.add(Duration(days: i - 3)));
});

// ─────────────────────────────────────────────────────────────────────────────
// TimelineTemplate — デフォルト予定テンプレート管理
// ─────────────────────────────────────────────────────────────────────────────

const _kTemplatesKey = 'timeline_templates_v1';

/// テンプレート一覧の StateNotifier。
/// 初期値は [kDefaultTemplates]。SharedPreferences に JSON で永続化。
class TimelineTemplatesNotifier
    extends StateNotifier<List<TimelineTemplate>> {
  TimelineTemplatesNotifier() : super(List.of(kDefaultTemplates)) {
    _load();
  }

  /// 開始時刻（時 × 60 + 分）の昇順でソートした新しいリストを返す
  List<TimelineTemplate> _sortedByTime(List<TimelineTemplate> list) {
    final sorted = List.of(list);
    sorted.sort((a, b) {
      final aMin = a.startHour * 60 + a.startMinute;
      final bMin = b.startHour * 60 + b.startMinute;
      return aMin.compareTo(bMin);
    });
    return sorted;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_kTemplatesKey);
    if (raw == null) return; // 未保存は初期値のまま
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => TimelineTemplate.fromJson(e as Map<String, dynamic>))
          .toList();

      // 【FEAT-208】既存ユーザーの SharedPreferences に保存された旧カテゴリ（英語コード値、
      // FEAT-147 当時の 13 値）を CLAUDE.md 4 値（運動/学習/健康/メンタル）に
      // 自動バックフィル。バックエンド側はマイグレーション 0065 で同等処理済み。
      const localCategoryRemap = <String, String>{
        'study':    '学習',
        'business': '学習',
        'creative': '学習',
        'work':     '学習',
        'exercise': '運動',
        'fitness':  '運動',
        'beauty':   '運動',
        'health':   '健康',
        'rest':     '健康',
        'habit':    '健康',
        // 【FEAT-307】FEAT-213 真実値 11 値に統一。'メンタル' は migration 0066 で
        // '精神' にリネーム済 (死語化)。旧 SharedPreferences 英語キーから
        // 正しい日本語 11 値へ remap (5/23 P0 積み残し解消)。
        'mental':   '精神',
        'social':   '社交',
        'other':    'その他',
      };
      var didMigrate = false;
      final migrated = list.map((t) {
        final newCat = localCategoryRemap[t.category];
        if (newCat == null) return t;
        didMigrate = true;
        return t.copyWith(category: newCat);
      }).toList();

      state = _sortedByTime(migrated);

      // バックフィルが発生した場合のみ保存し直し（無駄な書き込みを避ける）
      if (didMigrate) {
        await _save();
      }
    } catch (_) {
      state = List.of(kDefaultTemplates); // パース失敗時は初期値へ
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kTemplatesKey,
      jsonEncode(state.map((t) => t.toJson()).toList()),
    );
  }

  /// 有効/無効をトグル
  ///
  /// 【FEAT-208】有効化した場合、当日の `createdIds` リストから該当 ID を削除する。
  /// これにより同日内で「無効化 → 再有効化」したテンプレートも自動作成プロバイダー
  /// の対象に戻り、当日のタイムラインに即時反映される。
  ///
  /// 旧実装は `toggle()` 内で `_save()` するだけで、`timelineAutoCreateProvider` が
  /// `createdIds.contains(t.id)` を見て作成対象外と判定するため、無効化 → 再有効化
  /// しても当日のタイムラインに復活しなかった。
  Future<void> toggle(String id) async {                // FEAT-143: async に変更
    state = [
      for (final t in state)
        if (t.id == id) t.copyWith(isEnabled: !t.isEnabled) else t,
    ];
    await _save();                                       // FEAT-143: await に変更

    // 【FEAT-208】有効化したケースのみ、当日の createdIds から該当 ID を除去して
    // 自動作成の再実行を許可する（無効化方向の場合は既存挙動を維持）。
    final updated = state.firstWhere(
      (t) => t.id == id,
      orElse: () => kDefaultTemplates.first,
    );
    if (updated.isEnabled) {
      await _removeFromCreatedIds(id);
    }
  }

  /// 【FEAT-208】当日の自動作成済み ID リストから指定 ID を削除する。
  /// 翌日以降は本処理不要（_autoCreatedKey が日次でキー化されているため）。
  Future<void> _removeFromCreatedIds(String templateId) async {
    final prefs = await SharedPreferences.getInstance();
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final key   = _autoCreatedKey(today);

    final rawCreated = prefs.getString(key);
    if (rawCreated == null) return;

    try {
      final createdIds = Set<String>.from(
        (jsonDecode(rawCreated) as List<dynamic>).map((e) => e.toString()),
      );
      if (createdIds.remove(templateId)) {
        await prefs.setString(key, jsonEncode(createdIds.toList()));
      }
    } catch (_) {
      // パース失敗時は何もしない（次回読み込み時に空扱いされる）
    }
  }

  /// テンプレートを追加（開始時刻順に自動ソート）
  Future<void> add(TimelineTemplate template) async {   // FEAT-143: async に変更
    state = _sortedByTime([...state, template]);
    await _save();                                       // FEAT-143: await に変更
  }

  /// テンプレートを削除
  void remove(String id) {
    state = state.where((t) => t.id != id).toList();
    _save();
  }

  /// テンプレートを更新（開始時刻変更時も自動ソート）
  void update(TimelineTemplate updated) {
    state = _sortedByTime([
      for (final t in state)
        if (t.id == updated.id) updated else t,
    ]);
    _save();
  }
}

final timelineTemplatesProvider =
    StateNotifierProvider<TimelineTemplatesNotifier, List<TimelineTemplate>>(
  (_) => TimelineTemplatesNotifier(),
);

// ── 自動作成プロバイダー ──────────────────────────────────────────────────────

String _autoCreatedKey(DateTime date) =>
    'timeline_auto_created_'
    '${date.year}'
    '${date.month.toString().padLeft(2, '0')}'
    '${date.day.toString().padLeft(2, '0')}';

/// 指定日に対してデフォルトテンプレートを1回だけ自動作成する。
///
/// - 作成済みテンプレート ID の JSON リストで二重作成を防ぐ。
///   （旧 boolean フラグからの移行: getString で null が返れば再作成が走る）
/// - テンプレートは SharedPreferences から直接読み込み、race condition を解消。
/// - 当日に追加・有効化された新規テンプレートも次回起動時に自動追加される。
/// - 作成後は [timelineEventsProvider] を invalidate してリストを更新する。
final timelineAutoCreateProvider =
    FutureProvider.autoDispose.family<void, DateTime>((ref, date) async {
  // 【FEAT-370 (2026-05-28)】BUG-70 構造解消: offline 時は POST を完全スキップ。
  //
  // 旧 BUG-T 短期対応 (失敗時も `createdIds` に追加 → 再 POST 抑止) は「成功 ロスト
  // ケース」専用の防衛で、offline → online 復帰時の **意図的な再起動** に対しては
  // 機能しない。connectivity_plus の OS レベル offline 検知で **副作用そのものを
  // 抑止** することで、Backend に重複行を作らない構造に変える。
  //
  // online 復帰時は本 provider が再 build されて POST が走る (autoDispose + family)。
  // ProviderContainer のテストで `isOnlineProvider.overrideWithValue(false/true)`
  // 切替で挙動を検証する。
  final isOnline = ref.watch(isOnlineProvider);
  if (!isOnline) {
    debugPrint('[timelineAutoCreate] offline detected → skip POST for $date');
    return;
  }

  // 【FEAT-506 (2026-07-29)】user が Global toggle を OFF にしていれば
  // per-template の状態に関係なく作成を skip。既存 default 予定は残る。
  final autoCreateEnabled = await _isAutoCreateEnabled();
  if (!autoCreateEnabled) {
    debugPrint('[timelineAutoCreate] auto-create disabled by user → skip POST for $date');
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final key   = _autoCreatedKey(date);

  // ── 作成済みテンプレート ID の Set を取得（JSON リスト形式）────────
  final rawCreated = prefs.getString(key); // null または JSON 文字列
  final createdIds = rawCreated != null
      ? Set<String>.from(
          (jsonDecode(rawCreated) as List<dynamic>).map((e) => e.toString()),
        )
      : <String>{};

  // ── テンプレートを SharedPreferences から直接読み込み（race condition 解消）──
  final rawTemplates = prefs.getString(_kTemplatesKey);
  List<TimelineTemplate> templates;
  if (rawTemplates == null) {
    templates = kDefaultTemplates;
  } else {
    try {
      templates = (jsonDecode(rawTemplates) as List<dynamic>)
          .map((e) => TimelineTemplate.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      templates = kDefaultTemplates;
    }
  }

  // ── まだ作成されていない有効テンプレートだけを対象にする ──────────
  final toCreate = templates
      .where((t) => t.isEnabled && !createdIds.contains(t.id))
      .toList();

  if (toCreate.isNotEmpty) {
    final service = ref.read(timelineServiceProvider);
    final dateStr = '${date.year}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

    for (final t in toCreate) {
      try {
        await service.createEvent({
          'title':      t.title,
          'date':       dateStr,
          'start_time': '${t.startHour.toString().padLeft(2, '0')}:'
              '${t.startMinute.toString().padLeft(2, '0')}:00',
          'end_time':   '${t.endHour.toString().padLeft(2, '0')}:'
              '${t.endMinute.toString().padLeft(2, '0')}:00',
          'category':   t.category,
          'icon_key':   t.iconKey,
          // 【FEAT-196】テンプレートに仕込まれたサビメッセージを TimelineEvent.memo に反映。
          // 既存ユーザーのテンプレートは memo 空文字なので、後方互換上も問題なし。
          if (t.memo.isNotEmpty) 'memo': t.memo,
        });
        createdIds.add(t.id);
      } catch (e) {
        // 【BUG-117 (2026-06-14)】旧 BUG-T workaround (失敗時も createdIds.add で
        // 再試行抑止) を撤去。FEAT-370 で Backend 側に UniqueConstraint
        // (player, date, title, start_time) + IntegrityError → 200 既存返却 の
        // 冪等性が入ったため、retry 時に「レスポンスロスト → 重複作成」が
        // 構造的に発生しない (Backend が既存 1 件を返すだけ)。
        //
        // 旧 workaround の害: 一度でも API 失敗 (Render cold start、deploy 中、
        // 一時的 5xx 等) で全テンプレ ID が createdIds に追加され、当日中の
        // auto-create が永久にスキップされていた = 「デフォルト予定が出ない」
        // ユーザー報告の真因。
        //
        // 新動作: 失敗時は createdIds に追加せず、次回 timelineAutoCreateProvider
        // 起動時に retry される (Backend 冪等性により重複なし)。
        debugPrint('[timelineAutoCreate] createEvent failed for ${t.id}: $e '
            '(will retry next session, Backend is idempotent via FEAT-370)');
      }
    }
  }

  // ── 作成済み ID リストを JSON で保存 ─────────────────────────────
  await prefs.setString(key, jsonEncode(createdIds.toList()));

  // ── 未作成テンプレートがあった場合のみ events を更新 ──────────────
  if (toCreate.isNotEmpty) {
    ref.invalidate(timelineEventsProvider(date));
  }
});

// 【2026-07-07】FEAT-163「最近の予定」機能撤廃。
// - `recentEventTitlesProvider` (FutureProvider) を削除
// - `saveRecentEventTitle(title)` を削除
// 撤廃理由: サジェスト検索 (TaskSuggestion master data、GET /api/task-suggestions/)
// に予定タイトル入力経路を統一する方針。ToDo / 習慣 add page には元々「最近」
// 機能が無く、予定のみ独自履歴を持っていたため UX が非対称だった。統一により
// 3 経路すべてが同じ「Backend master data 検索 → hit 無ければ新規作成」フローに。
