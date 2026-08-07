import 'package:flutter/foundation.dart';  // debugPrint

import '../../../core/api/api_client.dart';
import '../../../core/cache/cache_service.dart';  // 【FEAT-280】
import '../../../core/constants/feature_flags.dart';  // 【FEAT-373】gcalPushEnabled gate
import '../../../core/services/toast_center.dart';  // 【FEAT-247】
import '../../calendar/services/google_calendar_sync_service.dart';  // 【FEAT-244/268】
import '../models/timeline_models.dart';
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】

class TimelineService {
  TimelineService(this._apiClient, this._googleCalendarSync, this._cache);
  final ApiClient                  _apiClient;
  final GoogleCalendarSyncService  _googleCalendarSync;  // 【FEAT-244/268】Google push 用
  final CacheService               _cache;                // 【FEAT-280】write 後 invalidate 用

  /// 【FEAT-280】write 操作後の cache invalidate 用 prefix（provider 側と一致）。
  static const String _timelineCachePrefix = 'timeline_events:';
  static const String _calendarBootstrapCachePrefix = 'calendar_bootstrap:';
  static const String _homeBootstrapCacheKey = 'home_bootstrap';

  void _invalidateAfterWrite() {
    // fire-and-forget で全関連キャッシュを無効化（write の完了を遅らせない）
    // 日付跨ぎの編集（リスケ）にも対応するため timeline は全日付の prefix 削除。
    // ignore: discarded_futures
    _cache.invalidateByPrefix(_timelineCachePrefix);
    // ignore: discarded_futures
    _cache.invalidateByPrefix(_calendarBootstrapCachePrefix);
    // ignore: discarded_futures
    _cache.invalidate(_homeBootstrapCacheKey);
  }

  /// 【FEAT-247】fire-and-forget Google push 失敗時のサビ口調トースト本文。
  /// `calendar_page` の callback 購読方式（FEAT-244）はページ単位の限定通知で
  /// ホーム / add_event_page 経由の追加で silent failure になっていたため、
  /// `ToastCenter` 経由で全画面共通の SnackBar に切り替えている。
  /// 【FEAT-489 Phase 2F-a】locale 依存になったため `const` → getter 化。
  static String get _googlePushFailedMessage =>
      ServiceL10n.current.timelineGooglePushFailedSabi_message;

  /// 指定日のイベント一覧を取得する
  Future<List<TimelineEvent>> fetchEvents(DateTime date) async {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final res = await _apiClient.dio.get(
      '/timeline/',
      queryParameters: {'date': dateStr},
    );
    final list = res.data as List<dynamic>;
    return list
        .map((e) => TimelineEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 新規イベントを作成する
  Future<TimelineEvent> createEvent(Map<String, dynamic> data) async {
    debugPrint('[TimelineService.createEvent] request data: $data');
    final TimelineEvent event;
    try {
      final res = await _apiClient.dio.post('/timeline/', data: data);
      debugPrint('[TimelineService.createEvent] response status=${res.statusCode} data=${res.data}');
      event = TimelineEvent.fromJson(res.data as Map<String, dynamic>);
    } catch (e, st) {
      // 【FEAT-244 診断】HTTP / JSON パース失敗の真因を可視化。
      debugPrint('[TimelineService.createEvent] API or parse failed: $e\n$st');
      rethrow;  // 呼び出し元の catch (e, st) で再度ハンドルされる
    }
    // 【FEAT-280】write 後にキャッシュ無効化（同期は走らない、次回 read で fresh）
    _invalidateAfterWrite();
    // 【FEAT-244】Google 連携時のみ fire-and-forget で push。
    // 未連携時は _ensureCalendarAccessToken が null を返してサイレントに飛ぶ。
    // 【FEAT-244 診断】fire-and-forget 呼び出し自体が同期的に例外を投げる
    // 可能性（GoogleSignIn の static 初期化失敗等）を遮断するため try/catch で
    // 包む。await しない分、ここで catch しなければ呼び出し元（add_event_page）
    // の SnackBar が「追加失敗」を誤表示してしまう。
    try {
      _pushToGoogleInBackground(event);
    } catch (e, st) {
      debugPrint('[TimelineService.createEvent] push start failed (event still saved): $e\n$st');
    }
    return event;
  }

  /// イベントを削除する
  Future<void> deleteEvent(int id) async {
    // 【FEAT-244】DELETE 後は googleEventId を取れないため、削除前に取得しておく。
    String? googleId;
    try {
      final res = await _apiClient.dio.get('/timeline/$id/');
      googleId = (res.data as Map<String, dynamic>)['google_event_id'] as String?;
    } catch (_) {
      // 取得失敗時は Google 側削除をスキップ（ローカル削除は実行する）
      googleId = null;
    }

    await _apiClient.dio.delete('/timeline/$id/');
    _invalidateAfterWrite();  // 【FEAT-280】

    if (googleId != null && googleId.isNotEmpty) {
      try {
        _deleteFromGoogleInBackground(googleId);
      } catch (e, st) {
        debugPrint('[TimelineService.deleteEvent] delete start failed: $e\n$st');
      }
    }
  }

  /// イベントのタイトル・時刻・カテゴリ等を一括更新する
  Future<TimelineEvent> updateEvent(int id, Map<String, dynamic> data) async {
    final res = await _apiClient.dio.patch('/timeline/$id/', data: data);
    final event = TimelineEvent.fromJson(res.data as Map<String, dynamic>);
    _invalidateAfterWrite();  // 【FEAT-280】
    // 【FEAT-244】Google にも push 済みの予定は追随更新
    if (event.googleEventId != null && event.googleEventId!.isNotEmpty) {
      try {
        _updateInGoogleInBackground(event);
      } catch (e, st) {
        debugPrint('[TimelineService.updateEvent] update start failed: $e\n$st');
      }
    }
    return event;
  }

  /// タイムライン予定を完了にして EXP・ダイヤを受け取る。
  ///
  /// すでに完了済みの場合は EXP = 0・diamond = false が返る（冪等）。
  /// 未完了→完了のときだけ EXP とダイヤが付与される。
  Future<TimelineReward> completeEventWithReward(int id) async {
    final res  = await _apiClient.dio.post('/timeline/$id/complete/');
    final data = res.data as Map<String, dynamic>;
    _invalidateAfterWrite();  // 【FEAT-280】
    return TimelineReward(
      expGain:            data['exp_gain']             as int?  ?? 0,
      diamondEarned:      data['diamond_earned']       as bool? ?? false,
      onTimeBonusAwarded: data['on_time_bonus_awarded'] as bool? ?? false,
      onTimeBonusCoin:    data['on_time_bonus_coin']    as int?  ?? 0,
      // 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス
      todayLoginBonus:    data['today_login_bonus']    as Map<String, dynamic>?,
      // 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント popup 候補
      friendGiftCandidate:
          data['friend_gift_candidate'] as Map<String, dynamic>?,
      // 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
      puzzlePieceAwarded:
          data['puzzle_piece_awarded'] as Map<String, dynamic>?,
    );
  }

  /// タイムライン予定の完了を取り消す（誤タップ救済）。
  ///
  /// BUG-B: 旧来の PATCH `/timeline/<id>/ {is_completed: false}` は
  /// シリアライザの read_only_fields で silently 無視されていた。
  /// 専用エンドポイントを使い、意図的な取り消しのみを反映させる。
  /// EXP・ダイヤは戻さない（冪等）。
  Future<TimelineEvent> uncompleteEvent(int id) async {
    final res  = await _apiClient.dio.post('/timeline/$id/uncomplete/');
    final data = res.data as Map<String, dynamic>;
    _invalidateAfterWrite();  // 【FEAT-280】
    return TimelineEvent.fromJson(data['event'] as Map<String, dynamic>);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 【FEAT-244】fire-and-forget Google push ヘルパー（UI ブロックなし）
  // ──────────────────────────────────────────────────────────────────────────

  /// 新規 push: 成功時は Backend にも `google-link` で ID を保存。
  /// 失敗時は ToastCenter 経由でサビ口調 SnackBar を全画面に通知（FEAT-247）。
  void _pushToGoogleInBackground(TimelineEvent event) {
    // 【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push 機能廃止 (gcalPushEnabled=false)。
    // 復元: feature_flags.dart の gcalPushEnabled を true に戻す + 法務文書更新 (§9 参照)。
    if (!FeatureFlags.gcalPushEnabled) {
      debugPrint('[TimelineService._pushToGoogleInBackground] '
          'FEAT-373: gcalPushEnabled=false, push disabled in v1.0');
      return;
    }
    () async {
      try {
        final googleId = await _googleCalendarSync.pushToGoogle(
          title:     event.title,
          date:      event.date,
          startTime: _formatTime(event.startTime),
          endTime:   _formatTime(event.endTime),
          memo:      event.memo,
        );
        if (googleId != null && googleId.isNotEmpty) {
          await _apiClient.dio.post(
            '/timeline/${event.id}/google-link/',
            data: {'google_event_id': googleId},
          );
        }
        // googleId == null は「未連携 / スコープ未付与」= サイレント成功扱い。
      } catch (e) {
        debugPrint('[TimelineService] Google push failed: $e');
        ToastCenter.showWarning(_googlePushFailedMessage);
      }
    }();
  }

  void _updateInGoogleInBackground(TimelineEvent event) {
    // 【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push 機能廃止。
    if (!FeatureFlags.gcalPushEnabled) {
      debugPrint('[TimelineService._updateInGoogleInBackground] '
          'FEAT-373: gcalPushEnabled=false, push disabled in v1.0');
      return;
    }
    final googleId = event.googleEventId;
    if (googleId == null || googleId.isEmpty) return;
    () async {
      try {
        await _googleCalendarSync.updateInGoogle(
          googleEventId: googleId,
          title:         event.title,
          date:          event.date,
          startTime:     _formatTime(event.startTime),
          endTime:       _formatTime(event.endTime),
          memo:          event.memo,
        );
      } catch (e) {
        debugPrint('[TimelineService] Google update failed: $e');
        ToastCenter.showWarning(_googlePushFailedMessage);
      }
    }();
  }

  void _deleteFromGoogleInBackground(String googleEventId) {
    // 【FEAT-373 (2026-05-29)】v1.0 で Google Calendar push 機能廃止。
    if (!FeatureFlags.gcalPushEnabled) {
      debugPrint('[TimelineService._deleteFromGoogleInBackground] '
          'FEAT-373: gcalPushEnabled=false, push disabled in v1.0');
      return;
    }
    () async {
      try {
        await _googleCalendarSync.deleteFromGoogle(googleEventId);
      } catch (e) {
        debugPrint('[TimelineService] Google delete failed: $e');
        // 削除経路はローカル削除済みでも、Google 側に古い予定が残ると
        // 「Sabiowl で消したのに Google に残っている」幽霊状態になるため、
        // ユーザーへ穏やかに通知する（FEAT-247）。
        ToastCenter.showWarning(_googlePushFailedMessage);
      }
    }();
  }

  /// `TimeOfDay?` → `'HH:MM'` 形式の文字列。null は null を返す（終日イベント）。
  String? _formatTime(dynamic t) {
    if (t == null) return null;
    final hour   = t.hour   as int;
    final minute = t.minute as int;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
}

/// タイムライン予定の完了で得たリワード
class TimelineReward {
  final int  expGain;
  final bool diamondEarned;
  // 【FEAT-419 (2026-06-10)】予定時刻 ±15 分以内ボーナス
  final bool onTimeBonusAwarded;
  final int  onTimeBonusCoin;
  // 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナス。non-null で 7 日カレンダー演出表示。
  final Map<String, dynamic>? todayLoginBonus;
  // 【FEAT-452 (2026-06-20)】当日 3 回目のタスク達成でフレンドプレゼント popup 候補。
  // non-null なら timeline_provider が friendGiftCandidateProvider に set して確認ダイアログ発火。
  final Map<String, dynamic>? friendGiftCandidate;
  // 【FEAT-479 (2026-07-06)】その日初回タスク達成でパズルピース (grey) 付与。
  // non-null なら timeline_provider が puzzlePieceAwardedProvider に set して overlay 発火。
  final Map<String, dynamic>? puzzlePieceAwarded;

  const TimelineReward({
    required this.expGain,
    required this.diamondEarned,
    this.onTimeBonusAwarded = false,
    this.onTimeBonusCoin    = 0,
    this.todayLoginBonus,
    this.friendGiftCandidate,
    this.puzzlePieceAwarded,
  });
}
