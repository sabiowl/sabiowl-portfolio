import 'package:flutter/foundation.dart';  // 【FEAT-504】debugPrint
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/dio_error_helper.dart';  // 【FEAT-402】
import '../../../core/cache/cache_config.dart';  // 【FEAT-280】
import '../../../core/cache/cache_service.dart';  // 【FEAT-280】
import '../../../core/cache/connectivity_indicator.dart';  // 【FEAT-280】
import '../local/google_event_store.dart';  // 【FEAT-426】
import '../models/calendar_models.dart';
import '../services/calendar_service.dart';
import '../services/google_calendar_sync_service.dart';  // 【FEAT-268】
import '../services/google_event_completion_service.dart';  // 【FEAT-426】

part 'calendar_provider.g.dart';

// ── 【FEAT-504 (2026-07-29)】Google イベント → DailyTimeline merge ────────────

/// 'HH:MM' 文字列を分でのオフセットに変換。null / 不正は 1440 (末尾ソート)。
int _dailyTimelineStartMinutes(String? t) {
  if (t == null) return 1440;
  final parts = t.split(':');
  if (parts.length < 2) return 1440;
  return (int.tryParse(parts[0]) ?? 24) * 60 + (int.tryParse(parts[1]) ?? 0);
}

/// LocalGoogleEventStore から指定日の Google イベントを取得して data.daily と merge。
/// store 失敗時はサイレントに backend-only data を返す（S3 予防策）。
///
/// 【20260729 review §2 懸念点 1 対応】`fetchCompletions` フラグ追加。
/// cached yield 経路では `false` を渡す = 端末 store のみで即 yield し、
/// completions の HTTP 往復 (Render コールドスタート時最大 60 秒) を待たない。
/// 完了チェックは直後の fresh yield (デフォルト true) で確定する。
///
/// トレードオフ: cached 経路で表示される Google 予定は「完了状態が 1 テンポ遅れて
/// 付く」= 「白画面 60 秒」より明確に軽い。
Future<CalendarBootstrapData> _mergeGoogleEventsIntoDaily(
  Ref ref,
  String date, // 'YYYY-MM-DD'
  CalendarBootstrapData data, {
  bool fetchCompletions = true,
}) async {
  try {
    final store = ref.read(localGoogleEventStoreProvider);
    final parsedDate = DateTime.tryParse(date);
    if (parsedDate == null) return data;

    final googleEvents = await store.queryByDateRange(parsedDate, parsedDate);
    if (googleEvents.isEmpty) return data;

    // Backend 完了状態を取得（fetchCompletions=false なら skip、全 isCompleted=false
    // で継続）。cached yield 経路では skip して即時性を優先、fresh yield で確定。
    Map<String, bool> completionMap = {};
    if (fetchCompletions) {
      try {
        final completionService = ref.read(googleEventCompletionServiceProvider);
        final completions = await completionService.fetchAll(
          dateFrom: parsedDate,
          dateTo:   parsedDate,
        );
        completionMap = {for (final c in completions) c.googleEventId: c.isCompleted};
      } catch (e) {
        debugPrint('[FEAT-504] completion fetch failed (fallback isCompleted=false): $e');
      }
    }

    // 【20260729 review §3 B-2 対応 (B案)】旧実装は「Backend 由来 google source を
    // 除外して重複防止」の dedup ガードを持っていたが、以下 3 点で構造的に発火不能:
    //   ① backend の daily payload (core.py:167-177) は source / google_event_id を
    //      返さない (id/title/category/icon_key/start_time/end_time/is_completed/memo のみ)
    //   ② DailyTimeline.fromJson は google_event_id を parse しない
    //      (fromGoogleEvent 経由でしか値が入らない)
    //   ③ POST /calendar/import/ は FEAT-426 で 410 Gone 化済 →
    //      新規 source='google' 行は増えず、母数は単調減少
    // Home 側 _mergeWithGoogleEvents も 6 月からガード無しで運用中、重複報告ゼロ。
    // 「守っているつもりのコードが守っていない」状態は次の重複バグ調査を遅らせるため、
    // 削除してコメントに理由明記の B案を採用。
    // 復活が必要な場合は payload に source/google_event_id を足す A案が必要。
    final newEvents = googleEvents
        .map((e) {
          String? startStr;
          if (e.startTime != null) {
            final h = e.startTime!.hour.toString().padLeft(2, '0');
            final m = e.startTime!.minute.toString().padLeft(2, '0');
            startStr = '$h:$m';
          }
          String? endStr;
          if (e.endTime != null) {
            final h = e.endTime!.hour.toString().padLeft(2, '0');
            final m = e.endTime!.minute.toString().padLeft(2, '0');
            endStr = '$h:$m';
          }
          return DailyTimeline.fromGoogleEvent(
            googleEventId: e.googleEventId,
            title:         e.title,
            startTime:     startStr,
            endTime:       endStr,
            memo:          e.memo,
            isCompleted:   completionMap[e.googleEventId] ?? false,
          );
        })
        .toList();

    if (newEvents.isEmpty) return data;

    final merged = [...data.daily.timeline, ...newEvents]
      ..sort((a, b) => _dailyTimelineStartMinutes(a.startTime)
          .compareTo(_dailyTimelineStartMinutes(b.startTime)));

    return data.copyWith(daily: data.daily.copyWith(timeline: merged));
  } catch (e) {
    debugPrint('[FEAT-504] _mergeGoogleEventsIntoDaily failed (fallback): $e');
    return data;
  }
}

/// 【FEAT-280】calendar bootstrap キャッシュキー。
/// `calendar_bootstrap:YYYY-MM:YYYY-MM-DD` で月 × 選択日の名前空間を分離。
String _calendarBootstrapCacheKey(int year, int month, String date) {
  final ym = '$year-${month.toString().padLeft(2, '0')}';
  return 'calendar_bootstrap:$ym:$date';
}

/// 当月 → 短 TTL、過去月 → 長 TTL。
Duration _calendarBootstrapTtl(int year, int month) {
  final now = DateTime.now();
  final isCurrent = year == now.year && month == now.month;
  final isFuture  = year > now.year ||
      (year == now.year && month > now.month);
  return (isCurrent || isFuture)
      ? CacheConfig.calendarCurrentMonth
      : CacheConfig.calendarPastMonth;
}

/// 【FEAT-280】write 操作後（HabitCount や TimelineComplete 等）に呼ぶ。
Future<void> invalidateCalendarBootstrapCache(Ref ref) async {
  await ref.read(cacheServiceProvider)
      .invalidateByPrefix('calendar_bootstrap:');
}

@riverpod
CalendarService calendarService(Ref ref) =>
    CalendarService(ref.watch(apiClientProvider));

/// 【FEAT-268】Google Calendar 連携専用サービスのプロバイダー。
/// 旧 `calendarServiceProvider.syncGoogleCalendar()` 等の経路は本 provider に移行。
/// 【FEAT-426】予定本文を端末内に保存するため [LocalGoogleEventStore] を注入。
@riverpod
GoogleCalendarSyncService googleCalendarSyncService(Ref ref) =>
    GoogleCalendarSyncService(
      ref.watch(apiClientProvider),
      ref.watch(localGoogleEventStoreProvider),
    );

/// 【FEAT-426】Google カレンダー予定本文のローカル保存ストア。
/// アプリ全体で 1 つの SQLite 接続を共有する（autoDispose しない）。
@Riverpod(keepAlive: true)
LocalGoogleEventStore localGoogleEventStore(Ref ref) => LocalGoogleEventStore();

/// 【FEAT-426】Google カレンダー予定の完了状態 (Multi-device 同期) サービス。
@riverpod
GoogleEventCompletionService googleEventCompletionService(Ref ref) =>
    GoogleEventCompletionService(ref.watch(apiClientProvider));

// 【FEAT-235】`calendarData` / `dailyData` provider は完全削除。
// FEAT-220 で `@Deprecated` 化、`calendar_bootstrap + timelineEvents` に経路統一済み。
// `DailyTaskSection.preloaded` を required に昇格してフォールバック経路を撤去した
// （daily_task_section.dart:30-）。現在は `calendarBootstrapProvider` の `.daily` で
// 同等データを取得する経路に集約されている。

@riverpod
Future<StreakData> streakData(Ref ref) =>
    ref.watch(calendarServiceProvider).fetchStreak();

@riverpod
Future<StatsData> statsData(Ref ref, int year, int month) =>
    ref.watch(calendarServiceProvider).fetchStats(year, month);

@riverpod
Future<HeatmapData> calendarHeatmap(Ref ref) =>
    ref.watch(calendarServiceProvider).fetchHeatmap();

/// P1-3: カレンダー画面 bootstrap（calendar + streak + daily を 1 リクエストで取得）
///
/// 【FEAT-280】Stream 化で SWR パターンに対応:
///   1. キャッシュあれば即時 yield（白画面消し）
///   2. 並行 API fetch → 成功なら fresh yield + ConnectivityIndicator.markOnline
///   3. API 失敗 + キャッシュあり → キャッシュ維持 + markOffline（例外は投げない）
///   4. API 失敗 + キャッシュなし → rethrow（呼出元 `.when(error:)` で処理）
@riverpod
Stream<CalendarBootstrapData> calendarBootstrap(
  Ref ref,
  int year,
  int month,
  String date,
) async* {
  final service = ref.watch(calendarServiceProvider);
  final cache   = ref.read(cacheServiceProvider);
  final conn    = ref.read(connectivityProvider.notifier);
  final cacheKey = _calendarBootstrapCacheKey(year, month, date);

  // 1. キャッシュ即時表示
  CalendarBootstrapData? cachedData;
  final cachedRaw = cache.getMap(cacheKey);
  if (cachedRaw != null) {
    try {
      final parsed = CalendarBootstrapData.fromJson(cachedRaw.data);
      // 【FEAT-504 + 20260729 review §2 対応】LocalGoogleEventStore と merge してから yield。
      // cached 経路では fetchCompletions=false: 端末内 store のみで即 yield、
      // completions の HTTP 往復を待たない (「キャッシュ即時表示」の約束を守る)。
      cachedData = await _mergeGoogleEventsIntoDaily(
        ref, date, parsed,
        fetchCompletions: false,
      );
      yield cachedData;
    } catch (_) {
      // パース失敗（モデル変更等）→ 破棄
      await cache.invalidate(cacheKey);
      cachedData = null;
    }
  }

  // 2. API fetch を試行（raw JSON で取得 → キャッシュ保存 + パース + yield）
  if (cachedData != null) conn.markFetching();
  try {
    final freshRaw = await service.fetchCalendarBootstrapRaw(
      year:  year,
      month: month,
      date:  date,
    );
    final fresh = CalendarBootstrapData.fromJson(freshRaw);
    // 【FEAT-504】fresh も同様に merge
    yield await _mergeGoogleEventsIntoDaily(ref, date, fresh);
    await cache.setMap(
      cacheKey,
      freshRaw,
      ttl: _calendarBootstrapTtl(year, month),
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
    if (cachedData == null) rethrow;
  }
}

// ── カレンダー → ホーム 日付ジャンプ用プロバイダー ─────────────────────────────
/// カレンダー画面からホーム画面に遷移する際に「参照したい日付」を一時保持する。
///
/// - カレンダー側: ボタン押下時に `_selectedDate` を設定してから `context.go('/home')` する
/// - ホーム側:     画面表示時にこのプロバイダーを読み取り、null 以外ならその日付の
///               タイムラインにジャンプし、読み取り後に null へリセットする
final calendarJumpDateProvider = StateProvider<DateTime?>((ref) => null);
