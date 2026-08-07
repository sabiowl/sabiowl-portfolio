import 'package:dio/dio.dart';
import 'package:flutter/material.dart';  // 【BUG-68】debugPrint / 【FEAT-426】TimeOfDay
import 'package:google_sign_in/google_sign_in.dart'; // FEAT-114
import '../../../core/api/api_client.dart';
import '../../../core/constants/feature_flags.dart';  // 【FEAT-373】gcalPushEnabled gate
import '../local/google_event_store.dart';  // 【FEAT-426】
import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2F-a】

/// 【FEAT-268】Google Calendar 連携専用サービス（CalendarService から責務分割）。
///
/// 元の `CalendarService` から Google API を叩く全メソッド（sync / push / update /
/// delete / reconcile / retry / unsync）を移動した。CalendarService 自体は Backend
/// `/calendar/*` への薄い HTTP クライアントとして保ち、Google 関連は本サービスへ集約。
///
/// 分割前の `CalendarService` は 653 LOC（fetch 系 ~50 + Google 系 ~580）と肥大化
/// していたが、Google 系は OAuth トークン管理 + Google Calendar Events API + Backend
/// との往復という独立した文脈を持つため、Backend fetch とは別ファイルにする方が
/// 凝集度が上がる。
class GoogleCalendarSyncService {
  final ApiClient _apiClient;
  final LocalGoogleEventStore _store;  // 【FEAT-426】
  GoogleCalendarSyncService(this._apiClient, this._store);

  // 【FEAT-244】push 同期のため read/write 両方が必要。最小権限原則で
  // `calendar.events`（イベント単位の読み書き、カレンダー設定変更不可）を要求。
  // 旧 `calendar.readonly` から変更したため、既存連携ユーザーには次回連携時 or
  // 初回 push 時に OAuth 再承諾ダイアログが表示される（Google API の仕様）。
  static const _calendarScope =
      'https://www.googleapis.com/auth/calendar.events';

  // FEAT-114: Calendar scope 専用の GoogleSignIn インスタンス
  // アカウント連携用（settings_service）とは別インスタンスで scope を分ける
  static final _googleSignIn = GoogleSignIn(scopes: [_calendarScope]);

  // 【FEAT-274】Sabiowl 起源イベントを Google カレンダー側で識別するための
  // メタデータキー。タイトルに `【Sabiowl】` プレフィックスを付与する旧方式
  // (FEAT-244) は UX 上のノイズが大きいため、Google Calendar API の
  // `extendedProperties.private` で source 識別する方式に変更。
  // ユーザーには「30 分ジョギング」として綺麗に表示される。
  //
  // 旧プレフィックス対応 (後方互換): backend 側で `【Sabiowl】` を含む既存
  // イベントは strip 処理して取り込む。新規 push 分はプレフィックスなし。
  static const _extendedPropertySourceKey   = 'source';
  static const _extendedPropertySourceValue = 'sabiowl';

  /// Google カレンダーの予定をインポートする。
  ///
  /// 戻り値: {'created': N, 'updated': N, 'skipped': N}
  /// キャンセル時: null を返す（エラーなし）
  /// エラー時: Exception を throw
  ///
  /// FEAT-114: フロントエンド主導型の同期。バックエンドに Google トークンを
  /// 保存せず、毎回 GoogleSignIn.signInSilently() で取得したアクセストークンを
  /// 使って Google Calendar Events API を直接叩く。
  Future<Map<String, int>?> syncGoogleCalendar() async {
    // ── Step 1: Google サインイン（Calendar scope 付き）──────────────────────
    // サイレントサインインを試みる。失敗時は明示的サインインへフォールバック。
    var account = await _googleSignIn.signInSilently();
    account ??= await _googleSignIn.signIn();
    if (account == null) return null; // ユーザーがキャンセルした場合

    // BUG-42: signInSilently() は OS のキャッシュアカウントを返すため、
    // settings_service.linkWithGoogle() がスコープなしでサインインした
    // 既存セッションが返り、accessToken に calendar.readonly が付与されない
    // 状態で API を叩くと 403 になる問題があった。
    // requestScopes は付与済みなら即 true（UI なし）、未付与なら OS の
    // 承認ダイアログを表示するため、ここで明示的に確保する。
    final hasScope = await _googleSignIn.requestScopes([_calendarScope]);
    if (!hasScope) {
      throw Exception('Google カレンダーへのアクセスが許可されませんでした');
    }

    final googleAuth  = await account.authentication;
    final accessToken = googleAuth.accessToken;
    if (accessToken == null) {
      throw Exception('Google アクセストークンの取得に失敗しました');
    }

    // ── Step 2: 同期期間を計算 ──────────────────────────────────────────────
    final now     = DateTime.now();
    final timeMin = DateTime(now.year, now.month - 3, 1);  // 3 ヶ月前の月初
    final timeMax = DateTime(now.year, now.month + 4, 0);  // 3 ヶ月後の月末

    // ── Step 3: Google Calendar Events API を呼び出し ──────────────────────
    final gcalResponse = await Dio().get(
      'https://www.googleapis.com/calendar/v3/calendars/primary/events',
      queryParameters: {
        'timeMin':      timeMin.toUtc().toIso8601String(),
        'timeMax':      timeMax.toUtc().toIso8601String(),
        'singleEvents': 'true',
        'orderBy':      'startTime',
        'maxResults':   '500',
      },
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    if (gcalResponse.statusCode != 200) {
      throw Exception('Google Calendar API エラー: ${gcalResponse.statusCode}');
    }

    final items = gcalResponse.data['items'] as List<dynamic>? ?? [];

    // ── Step 4〜5【FEAT-426】イベントを変換し LocalGoogleEventStore へ upsert ──
    // 設計 Y (ハイブリッド): 予定本文は Backend へ送信せず、端末内 SQLite に
    // 直接保存する。Backend には completion 状態 (GoogleEventCompletion) のみ。
    final existingIds = await _store.allGoogleEventIds();
    final currentIds  = <String>{};
    int created = 0;
    int updated = 0;
    int skipped = 0;
    final syncedAt = DateTime.now();  // upsert 時の last_synced_at

    for (final item in items) {
      // キャンセル済みはスキップ
      if (item['status'] == 'cancelled') continue;

      final externalId = item['id'] as String? ?? '';
      if (externalId.isEmpty) continue;

      // 【FEAT-274】extendedProperties.private.source = 'sabiowl' であれば
      // Sabiowl 自身が push したイベント。ローカルには既に Backend TimelineEvent
      // として存在するため、Google 由来として二重表示しないようスキップする。
      final extendedProps = item['extendedProperties'] as Map<String, dynamic>?;
      final privateProps  = extendedProps?['private'] as Map<String, dynamic>?;
      final extendedSource = privateProps?[_extendedPropertySourceKey] as String?;
      if (extendedSource == _extendedPropertySourceValue) {
        skipped++;
        continue;
      }

      final rawTitle   = item['summary'] as String? ??
          ServiceL10n.current.calendarImportUntitledEvent;
      final title      = rawTitle.length > 100
          ? rawTitle.substring(0, 100)
          : rawTitle;
      final memo       = item['description'] as String? ?? '';

      // 日付・時刻を解析（終日イベントは start.date、時刻ありは start.dateTime）
      final startRaw   = item['start'] as Map<String, dynamic>?;
      final endRaw     = item['end']   as Map<String, dynamic>?;
      final dateStr    = (startRaw?['date'] ?? startRaw?['dateTime'] ?? '') as String;
      final startDtStr = startRaw?['dateTime'] as String?;
      final endDtStr   = endRaw?['dateTime']   as String?;

      if (dateStr.length < 10) continue; // 日付が取得できなければスキップ

      TimeOfDay? startTime;
      TimeOfDay? endTime;
      if (startDtStr != null) {
        final dt = DateTime.tryParse(startDtStr)?.toLocal();
        if (dt != null) startTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
      }
      if (endDtStr != null) {
        final dt = DateTime.tryParse(endDtStr)?.toLocal();
        if (dt != null) endTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
      }

      currentIds.add(externalId);
      await _store.upsert(GoogleEvent(
        googleEventId: externalId,
        title:         title,
        date:          DateTime.parse(dateStr.substring(0, 10)),
        startTime:     startTime,
        endTime:       endTime,
        memo:          memo,
        lastSyncedAt:  syncedAt,
      ));
      if (existingIds.contains(externalId)) {
        updated++;
      } else {
        created++;
      }
    }

    // ── Step 5.5【FEAT-253/426】Google 側削除イベントの追随（幽霊状態解消）──
    // 今回の取得期間内 (timeMin〜timeMax) のローカル予定のうち、Google 側の
    // 最新一覧 (currentIds) に含まれないものは削除済みとみなしローカルからも削除。
    int deletedFollowup = 0;
    final localInWindow = await _store.queryByDateRange(timeMin, timeMax);
    for (final e in localInWindow) {
      if (!currentIds.contains(e.googleEventId)) {
        await _store.delete(e.googleEventId);
        deletedFollowup++;
      }
    }

    // ── Step 6【FEAT-244】Sabiowl → Google 一括 push（双方向同期の後半） ──
    // google_event_id 未設定 & source != 'google' のローカル予定をすべて push し、
    // 成功した分だけ Backend に google-link で保存。エラーは全体を止めない。
    //
    // 【FEAT-373 (2026-05-29)】v1.0 で push 機能廃止。Step 6 全体を skip し
    // pushed=0 / pushFailed=0 のまま次の集計ステップへ進む。
    // sync 方向 (Google → Sabiowl, Steps 1-5.5) は引き続き動作する。
    int pushed     = 0;
    int pushFailed = 0;
    if (FeatureFlags.gcalPushEnabled) {
      try {
        // 【FEAT-256】旧 `?unpushed_to_google=true` から `?pending_google_push=true` に移行。
        // 意味はほぼ同等だが、ストレートな bool 比較で読みやすく、auto-retry とも共有できる。
        final unpushedRes = await _apiClient.dio.get(
          '/timeline/',
          queryParameters: {'pending_google_push': 'true'},
        );
        final unpushedList = unpushedRes.data as List<dynamic>;
        // 【FEAT-253/256 hotfix】push 失敗の真因が catch (_) で握り潰されて見えない
        // 問題を解消。失敗時に debugPrint で Google API レスポンス内容を出力し、
        // 401/403/400 等の判別を可能にする。
        debugPrint('[syncPushLoop] start: ${unpushedList.length} pending events');
        for (final raw in unpushedList) {
          final ev = raw as Map<String, dynamic>;
          try {
            final googleId = await _pushSingleEvent(
              accessToken: accessToken,
              title:       ev['title']      as String? ?? '',
              dateStr:     ev['date']       as String? ?? '',
              startTime:   ev['start_time'] as String?,
              endTime:     ev['end_time']   as String?,
              memo:        ev['memo']       as String? ?? '',
            );
            if (googleId != null) {
              await _apiClient.dio.post(
                '/timeline/${ev['id']}/google-link/',
                data: {'google_event_id': googleId},
              );
              pushed++;
            } else {
              // _pushSingleEvent が null を返した（response.data.id 不在等）
              pushFailed++;
              debugPrint('[syncPushLoop] id=${ev['id']} title="${ev['title']}" → null googleId');
            }
          } catch (e) {
            pushFailed++;
            // 最初の数件だけ詳細ログを出して大量出力を抑制
            if (pushFailed <= 5) {
              debugPrint(
                '[syncPushLoop] FAILED id=${ev['id']} title="${ev['title']}" '
                'date=${ev['date']} start=${ev['start_time']} end=${ev['end_time']}: $e',
              );
            }
          }
        }
        debugPrint('[syncPushLoop] done: pushed=$pushed, failed=$pushFailed');
      } catch (e) {
        // unpushed 取得自体が失敗した場合は静かに飛ばす（取り込みは成功扱い）
        debugPrint('[syncPushLoop] outer error (unpushed fetch failed): $e');
      }
    } else {
      debugPrint('[GoogleCalendarSyncService.syncGoogleCalendar] '
          'FEAT-373: gcalPushEnabled=false, Step 6 push loop skipped (v1.0)');
    }

    return {
      'created':          created,
      'updated':          updated,
      'skipped':          skipped,
      'pushed':           pushed,
      'push_failed':      pushFailed,
      // 【FEAT-253/426】Google 側削除追随の集計（SnackBar 表示に使う）
      'deleted_followup': deletedFollowup,
    };
  }

  /// 【FEAT-212 + BUG-68 + FEAT-426】Google カレンダー取り込み + Push 同期を解除する。
  ///
  /// 設計 Y (ハイブリッド): 予定本文は端末内 [LocalGoogleEventStore] のみに保存
  /// されているため、`clearAll()` で端末内データをすべて削除する。あわせて
  /// **ローカルの GoogleSignIn キャッシュも破棄**することで、解除後の Sabiowl
  /// 予定追加が **元 Google カレンダーに push されないこと**を保証する。
  ///
  /// 【BUG-68 修正】: FEAT-212 時点では「OAuth は維持して再同期 UX を滑らかにする」
  /// 設計だったが、FEAT-244 で push 機能が追加されてから「OAuth 維持 = push も
  /// 継続」という副作用が露呈したため、`_googleSignIn.signOut()` でローカル
  /// キャッシュを破棄する。`signOut()` は OAuth grant 自体は revoke しないので、
  /// 再同期時はアカウント選択のみで scope 承諾不要（OS 側で承諾済み）。
  ///
  /// 戻り値: `{'deleted': N}`
  Future<Map<String, dynamic>> unsyncGoogleCalendar() async {
    // Step 1【FEAT-426】端末内 LocalGoogleEventStore をすべて削除
    final deleted = await _store.clearAll();

    // 【BUG-68】Step 2: ローカル GoogleSignIn キャッシュを破棄。
    // これがないと、解除後も `_ensureCalendarAccessToken()` 経由で push が走り、
    // 元連携 Google カレンダーに予定が出現してしまう。
    // signOut() は best-effort（ローカルキャッシュクリアのみで OAuth 自体は維持）
    // なので、失敗してもローカル削除は完了済みのため、解除完了として扱う。
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      // ログのみ。ローカル削除は成功しているので呼び出し元には伝えない。
      debugPrint(
        '[GoogleCalendarSyncService.unsyncGoogleCalendar] _googleSignIn.signOut failed: $e',
      );
    }

    return {'deleted': deleted};
  }

  // ────────────────────────────────────────────────────────────────────────
  // 【FEAT-244】Sabiowl → Google push 系メソッド
  // ────────────────────────────────────────────────────────────────────────

  /// アクセストークン取得ヘルパー（連携なし or スコープ未付与時は null を返す）
  ///
  /// `TimelineService` の fire-and-forget 経路から呼ばれるため、未連携時に
  /// 例外で UI を止めず、サイレントに null を返して呼び元で `if (token == null)`
  /// 早期 return する設計。
  Future<String?> _ensureCalendarAccessToken() async {
    // signInSilently は OS にキャッシュされたアカウントを返す（UI なし）。
    // 未連携時は null。
    final account = await _googleSignIn.signInSilently();
    if (account == null) return null;

    // requestScopes は付与済みなら true（UI なし）、未付与なら OS の承諾ダイアログ
    // を表示する。fire-and-forget 経路で初回 push 時にダイアログが出る可能性あり。
    final hasScope = await _googleSignIn.requestScopes([_calendarScope]);
    if (!hasScope) return null;

    final auth = await account.authentication;
    return auth.accessToken;
  }

  /// Sabiowl の予定を Google カレンダーに POST する。
  ///
  /// 戻り値: 成功時は Google 側 event ID / 連携なし or スコープ未付与時は null /
  /// 失敗時は Exception を throw。
  Future<String?> pushToGoogle({
    required String   title,
    required DateTime date,
    String? startTime,  // 'HH:MM' 形式（時刻ありイベント）
    String? endTime,
    String  memo = '',
  }) async {
    final accessToken = await _ensureCalendarAccessToken();
    if (accessToken == null) return null;

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return _pushSingleEvent(
      accessToken: accessToken,
      title:       title,
      dateStr:     dateStr,
      startTime:   startTime,
      endTime:     endTime,
      memo:        memo,
    );
  }

  /// 既存の Google イベントを更新する（編集経路）。
  ///
  /// 戻り値: 連携なし / 未付与時は no-op。失敗時は Exception を throw。
  Future<void> updateInGoogle({
    required String   googleEventId,
    required String   title,
    required DateTime date,
    String? startTime,
    String? endTime,
    String  memo = '',
  }) async {
    final accessToken = await _ensureCalendarAccessToken();
    if (accessToken == null) return;

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final body = _buildGoogleEventBody(
      summary:     title,  // 【FEAT-274】プレフィックスなし、source は extendedProperties で識別
      dateStr:     dateStr,
      startTime:   startTime,
      endTime:     endTime,
      description: memo,
    );

    final res = await Dio().patch(  // PATCH で部分更新
      'https://www.googleapis.com/calendar/v3/calendars/primary/events/$googleEventId',
      data: body,
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        // 410 (削除済み) / 404 を「無視」できるよう 500 未満は通す
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    // 200 = 更新成功、410/404 = 既に削除済み（Google 側で消えていれば追随 OK）
    if (res.statusCode != 200 && res.statusCode != 410 && res.statusCode != 404) {
      throw Exception('Google Calendar update failed: ${res.statusCode}');
    }
  }

  /// 既存の Google イベントを削除する（削除経路）。
  ///
  /// 410 Gone（既に削除済み）も成功扱い。連携なし時は no-op。
  Future<void> deleteFromGoogle(String googleEventId) async {
    final accessToken = await _ensureCalendarAccessToken();
    if (accessToken == null) return;

    final res = await Dio().delete(
      'https://www.googleapis.com/calendar/v3/calendars/primary/events/$googleEventId',
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    if (res.statusCode != 204 && res.statusCode != 410 && res.statusCode != 404) {
      throw Exception('Google Calendar delete failed: ${res.statusCode}');
    }
  }

  /// アクセストークン確保済み前提で 1 件 push する内部ヘルパー。
  /// `pushToGoogle` と `syncGoogleCalendar` の Step 6 から共通利用。
  Future<String?> _pushSingleEvent({
    required String accessToken,
    required String title,
    required String dateStr,  // 'YYYY-MM-DD'
    String? startTime,
    String? endTime,
    required String memo,
  }) async {
    final body = _buildGoogleEventBody(
      summary:     title,  // 【FEAT-274】プレフィックスなし、source は extendedProperties で識別
      dateStr:     dateStr,
      startTime:   startTime,
      endTime:     endTime,
      description: memo,
    );

    final res = await Dio().post(
      'https://www.googleapis.com/calendar/v3/calendars/primary/events',
      data: body,
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('Google Calendar push failed: ${res.statusCode}');
    }
    final data = res.data;
    if (data is Map && data['id'] is String) {
      return data['id'] as String;
    }
    return null;
  }

  /// Google Calendar イベント body 構築ヘルパー（push / update 共通）。
  /// 時刻なし → 終日イベント / 時刻あり → タイムゾーン付きイベント。
  Map<String, dynamic> _buildGoogleEventBody({
    required String  summary,
    required String  dateStr,  // 'YYYY-MM-DD'
    String? startTime,         // 'HH:MM'
    String? endTime,
    required String  description,
  }) {
    // 【FEAT-274】Sabiowl 起源イベントの識別用メタデータ。
    // タイトルにプレフィックスを付ける旧方式と異なり、ユーザーには見えない
    // が API レスポンスには含まれる。Backend 側はこれを見て「Sabiowl が
    // push したイベント」と判別できる。
    final extendedProperties = {
      'private': {
        _extendedPropertySourceKey: _extendedPropertySourceValue,
      },
    };

    if (startTime == null || endTime == null) {
      // 終日イベント（Google の仕様: end.date は exclusive で翌日を渡すべきだが、
      // Sabiowl 内部では同日扱いのため簡易化して同日を渡す。実機で違和感が
      // あれば翌日に変更可能。MVP 範囲では同日固定。）
      return {
        'summary':            summary,
        'description':        description,
        'start':              {'date': dateStr},
        'end':                {'date': dateStr},
        'extendedProperties': extendedProperties,
      };
    }

    // 時刻ありイベント。タイムゾーンは端末のローカル名を試行、フォールバックで
    // Asia/Tokyo（Sabiowl の主要利用想定）。
    //
    // 【FEAT-256 hotfix】時刻文字列の形式不一致を吸収:
    //   - 新規作成経路: _formatTime(TimeOfDay) → 'HH:MM' (5 文字)
    //   - 既存予定経路: Backend TimeField シリアライザ → 'HH:MM:SS' (8 文字)
    // 両方を 'HH:MM' に正規化してから ':00' を appending することで、
    // 'YYYY-MM-DDTHH:MM:00' という Google API 正規形式に統一。
    // 旧実装は HH:MM:SS に :00 をさらに足して 'HH:MM:SS:00' という
    // 不正形式を作っていて Google API が 400 を返していた（FEAT-256 で
    // 既存 52 件一括 push 時に全失敗で顕在化）。
    final tz = _localTimeZoneName();
    final normStart = startTime.length >= 5 ? startTime.substring(0, 5) : startTime;
    final normEnd   = endTime.length   >= 5 ? endTime.substring(0, 5)   : endTime;
    final start = '${dateStr}T$normStart:00';
    final end   = '${dateStr}T$normEnd:00';
    return {
      'summary':            summary,
      'description':        description,
      'start':              {'dateTime': start, 'timeZone': tz},
      'end':                {'dateTime': end,   'timeZone': tz},
      'extendedProperties': extendedProperties,
    };
  }

  /// 端末ローカル TZ 名を IANA 形式で返す。`DateTime.now().timeZoneName` は
  /// 'JST' のような略称が返ることがあり Google API が拒否するため、固定で
  /// 'Asia/Tokyo' を返す（Sabiowl は日本ユーザー主体、将来必要なら拡張）。
  String _localTimeZoneName() => 'Asia/Tokyo';

  // ────────────────────────────────────────────────────────────────────────
  // 【FEAT-256】Pending push の auto-retry（アプリ起動 / resume 時に呼ばれる）
  // ────────────────────────────────────────────────────────────────────────

  /// 起動直後 / バックグラウンド復帰時に呼ぶ pending push の自動再試行。
  ///
  /// - Backend `/timeline/?pending_google_push=true` で未 push の予定リスト取得
  /// - 最大 5 件まで個別に push 試行（過剰負荷防止）
  /// - 各 push は fire-and-forget、失敗してもログのみ
  ///
  /// 連携なし or token 取得失敗時はサイレントに何もしない。呼出元（main.dart の
  /// `AppLifecycleState.resumed` リスナー等）から try/catch で更に守る必要なし。
  ///
  /// [gcalPushEnabled] は呼び出し側で `player.gcalPushEnabled` を渡す。
  /// 【FEAT-372 (2026-05-28)】BUG-74 defense-in-depth:
  /// Backend reconcile (Phase 1-2) で pending=True 予定を DB レベルで消去するが、
  /// migration 未適用環境 / Backend 障害時の二重防御として Flutter 側でも
  /// gcal_push_enabled=False ユーザーの push を構造的に遮断する。
  /// `gcalPushEnabled` の default=true は旧呼び出しコードとの後方互換のため。
  Future<void> retryPendingPushes({bool gcalPushEnabled = true}) async {
    // 【FEAT-373 (2026-05-29)】v1.0 で push 機能廃止 — 全 push 経路をまとめて遮断。
    // 復元: feature_flags.dart の gcalPushEnabled を true に変更 (FEAT-373 §9 参照)。
    if (!FeatureFlags.gcalPushEnabled) {
      debugPrint('[GoogleCalendarSyncService.retryPendingPushes] '
          'FEAT-373: gcalPushEnabled=false, push disabled in v1.0');
      return;
    }
    // 【FEAT-372】BUG-74 defense-in-depth: gcal_push_enabled=False なら全 push をスキップ
    if (!gcalPushEnabled) {
      debugPrint('[GoogleCalendarSyncService.retryPendingPushes] '
          'gcal_push_enabled=false → skip all pushes (FEAT-372 defense-in-depth)');
      return;
    }
    try {
      final accessToken = await _ensureCalendarAccessToken();
      if (accessToken == null) return;

      final res = await _apiClient.dio.get(
        '/timeline/',
        queryParameters: {'pending_google_push': 'true'},
      );
      final list = res.data as List<dynamic>;
      if (list.isEmpty) return;

      // 5 件まで（過剰負荷防止）
      for (final raw in list.take(5)) {
        final ev = raw as Map<String, dynamic>;
        try {
          final googleId = await _pushSingleEvent(
            accessToken: accessToken,
            title:       ev['title']      as String? ?? '',
            dateStr:     ev['date']       as String? ?? '',
            startTime:   ev['start_time'] as String?,
            endTime:     ev['end_time']   as String?,
            memo:        ev['memo']       as String? ?? '',
          );
          if (googleId != null && googleId.isNotEmpty) {
            await _apiClient.dio.post(
              '/timeline/${ev['id']}/google-link/',
              data: {'google_event_id': googleId},
            );
          }
        } catch (e) {
          debugPrint('[GoogleCalendarSyncService.retryPendingPushes] item failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[GoogleCalendarSyncService.retryPendingPushes] outer error: $e');
    }
  }
}
