import 'dart:convert';  // 【BUG-101】FCM data payload を local notification payload に橋渡し

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// flutter_timezone は削除（BUG-06: Kotlin V1 API 非互換のため）
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../features/timeline/models/timeline_models.dart'
    show TimelineEvent;

import '../../firebase_options.dart';
import '../api/api_client.dart';
import '../l10n/service_l10n.dart';  // 【FEAT-489 Phase 2D】BuildContext なし層の l10n
import 'notification_deep_link.dart';  // 【BUG-101】通知タイプ → ルート解決

// ─────────────────────────────────────────────────
// 通知権限ステータス
// ─────────────────────────────────────────────────
enum NotifPermissionStatus {
  granted,          // 許可済み
  notDetermined,    // 未決定（まだ一度もリクエストしていない）
  permanentlyDenied // 拒否済み（設定アプリからしか変更できない）
}

// ─────────────────────────────────────────────────
// バックグラウンドメッセージハンドラ（トップレベル関数必須）
// ─────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('FCM background: ${message.notification?.title}');
}

// ─────────────────────────────────────────────────
// 通知チャンネル定義
// ─────────────────────────────────────────────────
// 【FEAT-489 Phase 2D (2026-08-02)】チャンネル名 / description が locale 依存に
// なったため `const` → getter 化。BuildContext を持たない層なので
// [ServiceL10n] 経由で現在 locale の文字列を解決する。
// チャンネル **id** は locale に依存しない (既存購読者の設定を壊さないため固定)。
AndroidNotificationChannel get _androidChannel => AndroidNotificationChannel(
      'restack_default',
      ServiceL10n.current.coreNotificationDefaultChannelName,
      description: ServiceL10n.current.coreNotificationDefaultChannelDescription,
      importance: Importance.high,
      playSound: true,
    );

// ── タイムライン予定専用チャンネル ────────────────────────────────────────
AndroidNotificationChannel get _timelineChannel => AndroidNotificationChannel(
      'restack_timeline',
      ServiceL10n.current.coreNotificationTimelineChannelName,
      description: ServiceL10n.current.coreNotificationTimelineChannelDescription,
      importance: Importance.high,
      playSound: true,
    );

// ── 【FEAT-509】チャレンジ結果通知チャンネル ──────────────────────────────
AndroidNotificationChannel get _challengeChannel => AndroidNotificationChannel(
      'challenge_result',
      ServiceL10n.current.coreNotificationChallengeChannelName,
      description: ServiceL10n.current.coreNotificationChallengeChannelDescription,
      importance: Importance.high,
      playSound: true,
    );

// ─────────────────────────────────────────────────
// NotificationService
// ─────────────────────────────────────────────────
class NotificationService {
  static String? _fcmToken;
  static String? get fcmToken => _fcmToken;

  static final _localNotifications = FlutterLocalNotificationsPlugin();

  /// 【FEAT-509】ChallengeNotificationService が同じプラグインインスタンスを参照できるよう公開。
  static FlutterLocalNotificationsPlugin get localNotifications => _localNotifications;

  /// 【BUG-101 (2026-06-14)】通知タップ deep link を集約する ValueNotifier。
  /// 以下の 3 経路すべてからここに route 文字列を書き込む:
  ///   1. FCM terminated launch (`getInitialMessage` in initialize)
  ///   2. FCM background → foreground 復帰タップ (`onMessageOpenedApp`)
  ///   3. foreground 中の local notification バナータップ
  ///     (`flutter_local_notifications.onDidReceiveNotificationResponse`)
  /// RestackApp が listen して GoRouter で遷移、消費後 `clearDeepLink()` でリセット。
  static final ValueNotifier<String?> pendingDeepLink = ValueNotifier<String?>(null);

  // ── 初期化（権限リクエストは行わない） ────────────────────────────
  static Future<void> initialize() async {
    // 0. タイムゾーンデータ初期化（tz.TZDateTime.utc() に必要）
    tz_data.initializeTimeZones();

    // 1. Firebase 初期化
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // 2. バックグラウンドメッセージハンドラ登録
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // 3. flutter_local_notifications 初期化
    await _initLocalNotifications();

    // ★ 権限リクエストはここでは行わない。
    //    ホーム画面のソフトプロンプト（NotificationSoftPromptSheet）経由で実施する。

    // 4. FCM トークン取得（権限なしでも取得可能）
    await _getToken();

    // 5. フォアグラウンドハンドラ設定（ローカル通知でバナー表示）
    _setupForegroundHandler();

    // 6. 通知タップ時のハンドリング（アプリがバックグラウンドから復帰した場合）
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('FCM tapped from background: ${message.notification?.title}');
      // 【BUG-101】message.data から notif_type / related_id を読んで deep link 解決
      _enqueueDeepLinkFromData(message.data);
    });

    // 【BUG-101】Terminated state からの起動時 (タップで app launch された場合) の捕捉。
    // RestackApp 起動完了後に pendingDeepLink を listen して遷移する。
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      debugPrint('FCM tapped from terminated: ${initial.notification?.title}');
      _enqueueDeepLinkFromData(initial.data);
    }
  }

  /// 【BUG-101】FCM data (Map) または local notification payload (decoded JSON) から
  /// notif_type / related_id を読み、ルートを解決して `pendingDeepLink` に書き込む。
  /// 未知タイプ or notif_type 欠落時は no-op (crash させない)。
  static void _enqueueDeepLinkFromData(Map<String, dynamic> data) {
    final type = data['notif_type'];
    if (type is! String || type.isEmpty) return;
    final relatedId = NotificationDeepLink.parseRelatedId(
      data['related_id'] is String ? data['related_id'] as String : null,
    );
    final route = NotificationDeepLink.resolveRoute(type, relatedId);
    if (route == null) return;
    pendingDeepLink.value = route;
  }

  /// 【BUG-101】RestackApp が遷移完了後に呼び出して pendingDeepLink を null リセット。
  static void clearDeepLink() {
    pendingDeepLink.value = null;
  }

  // ── 権限ステータス確認 ────────────────────────────────────────────
  static Future<NotifPermissionStatus> checkPermissionStatus() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      switch (settings.authorizationStatus) {
        case AuthorizationStatus.authorized:
        case AuthorizationStatus.provisional:
          return NotifPermissionStatus.granted;
        case AuthorizationStatus.denied:
          return NotifPermissionStatus.permanentlyDenied;
        case AuthorizationStatus.notDetermined:
          return NotifPermissionStatus.notDetermined;
      }
    } else {
      // Android
      final status = await ph.Permission.notification.status;
      if (status.isGranted) return NotifPermissionStatus.granted;
      if (status.isPermanentlyDenied) {
        return NotifPermissionStatus.permanentlyDenied;
      }
      return NotifPermissionStatus.notDetermined;
    }
  }

  // ── 権限リクエスト ─────────────────────────────────────────────────
  static Future<NotifPermissionStatus> requestPermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint('FCM permission: ${settings.authorizationStatus}');
      switch (settings.authorizationStatus) {
        case AuthorizationStatus.authorized:
        case AuthorizationStatus.provisional:
          return NotifPermissionStatus.granted;
        case AuthorizationStatus.denied:
          return NotifPermissionStatus.permanentlyDenied;
        case AuthorizationStatus.notDetermined:
          return NotifPermissionStatus.notDetermined;
      }
    } else {
      // Android
      final status = await ph.Permission.notification.request();
      if (status.isGranted) return NotifPermissionStatus.granted;
      if (status.isPermanentlyDenied) {
        return NotifPermissionStatus.permanentlyDenied;
      }
      return NotifPermissionStatus.notDetermined;
    }
  }

  // ── FCM トークンをサーバーに登録 ──────────────────────────────────
  static Future<void> registerTokenWithServer(ApiClient apiClient) async {
    final token = _fcmToken;
    if (token == null || token.isEmpty) return;
    try {
      // BUG-2026-04: 旧実装は POST /push/subscribe/ に送っていたが、
      // PushSubscribeView は Web Push 用（endpoint / p256dh / auth 必須）で
      // FCM トークンを受け付けない。常に 400 で silent fail し、ソフトプロンプトで
      // 通知許可した直後のユーザーは次回アプリ再起動まで push が届かなかった。
      // PlayerNotifier._tryRegisterFcmToken と同じ PATCH /player/ {fcm_token}
      // 経路に統一する。
      await apiClient.dio.patch('/player/', data: {'fcm_token': token});
      debugPrint('FCM token registered with server (player.fcm_token)');
    } catch (e) {
      debugPrint('FCM token registration error: $e');
    }
  }

  // ── 設定アプリを開く ──────────────────────────────────────────────
  static Future<void> openAppSettings() async {
    await ph.openAppSettings();
  }

  // ── flutter_local_notifications 初期化 ──────────────────────────
  static Future<void> _initLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false, // FCM 側で権限を取る
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await _localNotifications.initialize(
      initSettings,
      // 【BUG-101】foreground 中に表示した local notification をタップした際、
      // payload (JSON 文字列、_setupForegroundHandler で message.data をエンコード) を
      // decode して deep link を解決する。
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final decoded = json.decode(payload);
          if (decoded is Map<String, dynamic>) {
            _enqueueDeepLinkFromData(decoded);
          }
        } catch (e) {
          // 旧形式 / corrupt payload は無視 (timeline 通知等は payload を持たない)
          debugPrint('local notification payload decode failed: $e');
        }
      },
    );

    // Android 通知チャンネルを作成（8.0 以上で必須）
    //
    // 【2026-08-02】この時点の名前は **必ず日本語**になる。`initialize()` は
    // `main()` の冒頭で呼ばれ、locale が確定するのは `prefs` 取得後の
    // `resolveInitialLocale()` (main.dart)、`ServiceL10n` が実 locale に同期
    // されるのは `MaterialApp.builder` (= `runApp` の後) だからである。
    // `ServiceL10n._current` の初期値は ja なので、英語ユーザーの
    // 「設定 > アプリ > Sabiowl > 通知」に日本語のチャンネル名が並ぶ。
    //
    // ここでは作るだけにして、正しい名前への差し替えは locale 確定後に
    // [refreshChannelsIfLocaleChanged] が行う (チャンネル id は locale 非依存
    // に固定してあるので、同 id で再作成すれば name / description が更新される)。
    await _createChannels();

    // iOS: フォアグラウンド通知をバナー+音で表示
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  /// 3 つの Android 通知チャンネルを現在の locale の名前で作成する。
  ///
  /// チャンネル **id** は locale 非依存に固定してあるので、同 id で再作成すると
  /// Android 側は name / description だけを更新する (ユーザーが変更した
  /// 音量・重要度等の設定は保持される)。iOS ではプラグインが null を返すため
  /// 何も起きない。
  static Future<void> _createChannels() async {
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;
    await androidPlugin.createNotificationChannel(_androidChannel);
    await androidPlugin.createNotificationChannel(_timelineChannel);
    await androidPlugin.createNotificationChannel(_challengeChannel); // FEAT-509
  }

  /// 最後にチャンネルを作った時の locale。null = まだ一度も作っていない。
  static String? _channelsLocale;

  /// locale が変わっていたら通知チャンネル名を作り直す。
  ///
  /// `MaterialApp.builder` から `ServiceL10n.syncFrom` の直後に呼ぶ想定。
  /// builder は再 build のたびに走るので、**locale が変わった時だけ**実際の
  /// 作成を行う (毎フレーム platform channel を叩かないため)。
  ///
  /// - 起動時: `initialize()` が ja で作った名前を、locale 確定後に上書きする
  /// - 実行時の言語切替: 切替 → 再 build → ここが走って名前が追従する
  ///
  /// 失敗しても握り潰す。チャンネル名が古いままでも通知自体は届くので、
  /// ここで例外を投げて起動を止める価値はない。
  static Future<void> refreshChannelsIfLocaleChanged() async {
    final locale = ServiceL10n.current.localeName;
    if (locale == _channelsLocale) return;
    _channelsLocale = locale;
    try {
      await _createChannels();
    } catch (e) {
      debugPrint('notification channel refresh failed: $e');
    }
  }

  // ── FCM トークン取得 ──────────────────────────────────────────────
  static Future<void> _getToken() async {
    try {
      _fcmToken = await FirebaseMessaging.instance.getToken();
      debugPrint('FCM token: $_fcmToken');

      // トークンが更新された場合も再取得
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        debugPrint('FCM token refreshed: $newToken');
      });
    } catch (e) {
      debugPrint('FCM token error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // タイムライン予定通知
  // ─────────────────────────────────────────────────────────────────────────

  /// 指定イベントのローカル通知を [scheduledAt] にスケジュールする。
  ///
  /// - [id]: 通知 ID = event.id（キャンセル・上書きに使用）
  /// - [title]: 予定タイトル
  /// - [scheduledAt]: 通知を発火する絶対日時（ローカルタイム）
  static Future<void> scheduleTimelineEventNotification({
    required int      id,
    required String   title,
    required DateTime scheduledAt,
  }) async {
    // 過去の時刻はスキップ（余裕を 30 秒持たせる）
    if (scheduledAt.isBefore(DateTime.now().add(const Duration(seconds: 30)))) {
      return;
    }

    // UTC ベースでスケジュール（flutter_timezone 不要・タイムゾーン設定不要）
    // scheduledAt はローカルタイムの DateTime なので .toUtc() でエポック秒を正確に変換する
    final utcDt       = scheduledAt.toUtc();
    final tzScheduled = tz.TZDateTime.utc(
      utcDt.year, utcDt.month, utcDt.day, utcDt.hour, utcDt.minute,
    );

    final l10n = ServiceL10n.current;
    final channel = _timelineChannel;
    await _localNotifications.zonedSchedule(
      id,
      l10n.coreNotificationTimelineEventTitle(title),
      l10n.coreNotificationTimelineEventBody,
      tzScheduled,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority:   Priority.high,
          playSound:  true,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
      // 【FEAT-226】Doze（端末スリープ省電力）を尊重するため inexactAllowWhileIdle に変更。
      // 習慣・予定通知は ±5 分の遅延が許容範囲。深夜帯のバッテリードレインを大幅削減。
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  /// 指定 ID の通知をキャンセルする。
  static Future<void> cancelTimelineEventNotification(int id) async {
    await _localNotifications.cancel(id);
  }

  // ── 【FEAT-273】タイムライン予定の +15 分未完了リマインダー ────────────────

  /// 【FEAT-273】通知 ID オフセット。
  /// 既存 `scheduleTimelineEventNotification` の id (= event.id) と衝突回避。
  /// event.id 最大値が 1 億未満想定なので 0x40000000 (約 10.7 億) で安全。
  static const int _uncompletedReminderIdOffset = 0x40000000;

  /// 【FEAT-273】未完了リマインダーのデフォルトオフセット（分）。
  static const int kUncompletedReminderOffsetMinutes = 15;

  /// 【FEAT-273】予定の開始時刻 +N 分後に「未完了の場合に発火」するリマインダー。
  ///
  /// - 通知 ID = event.id + [_uncompletedReminderIdOffset]（既存通知と独立管理）
  /// - 完了/削除時は [cancelTimelineUncompletedReminder] で個別キャンセル
  /// - 「未完了判定」は OS スケジューラー発火時点ではできないため、
  ///   完了時にキャンセルすることで「未完了なら発火」を構造的に成立させる
  /// - 通知文は CLAUDE.md「サビの口調ルール」遵守（〜いかがでしょうか採用形）
  static Future<void> scheduleTimelineUncompletedReminder({
    required int      id,
    required String   title,
    required DateTime scheduledAt,
    int offsetMinutes = kUncompletedReminderOffsetMinutes,
  }) async {
    final reminderAt = scheduledAt.add(Duration(minutes: offsetMinutes));
    if (reminderAt.isBefore(DateTime.now().add(const Duration(seconds: 30)))) {
      return;
    }

    final utcDt = reminderAt.toUtc();
    final tzScheduled = tz.TZDateTime.utc(
      utcDt.year, utcDt.month, utcDt.day, utcDt.hour, utcDt.minute,
    );

    final l10n = ServiceL10n.current;
    final channel = _timelineChannel;
    await _localNotifications.zonedSchedule(
      id + _uncompletedReminderIdOffset,
      l10n.coreNotificationTimelineUncompletedTitle(title),
      l10n.coreNotificationTimelineUncompletedBody,
      tzScheduled,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority:   Priority.high,
          playSound:  true,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
      // 【FEAT-226】Doze（端末スリープ省電力）を尊重するため inexactAllowWhileIdle に変更。
      // 習慣・予定通知は ±5 分の遅延が許容範囲。深夜帯のバッテリードレインを大幅削減。
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  /// 【FEAT-273】予定 ID に対応する未完了リマインダーをキャンセル。
  /// 完了マーク時 / 削除時に呼ぶことで「未完了なら発火」を構造的に成立させる。
  static Future<void> cancelTimelineUncompletedReminder(int id) async {
    await _localNotifications.cancel(id + _uncompletedReminderIdOffset);
  }

  /// Todo タスクの期日通知をスケジュールする。
  ///
  /// - [id]: 通知 ID（Todo の hashCode ベース）
  /// - [title]: タスク名
  /// - [scheduledAt]: 通知発火する日時（ローカルタイム）
  static Future<void> scheduleTaskNotification({
    required int      id,
    required String   title,
    required DateTime scheduledAt,
  }) async {
    // 過去の時刻はスキップ
    if (scheduledAt.isBefore(
        DateTime.now().add(const Duration(seconds: 30)))) {
      return;
    }

    final utcDt       = scheduledAt.toUtc();
    final tzScheduled = tz.TZDateTime.utc(
      utcDt.year, utcDt.month, utcDt.day, utcDt.hour, utcDt.minute,
    );

    final l10n = ServiceL10n.current;
    final channel = _timelineChannel;
    await _localNotifications.zonedSchedule(
      id,
      l10n.coreNotificationTaskDueTitle(title),
      l10n.coreNotificationTaskDueBody,
      tzScheduled,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,   // タイムラインと同じチャンネル流用
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority:   Priority.high,
          playSound:  true,
          icon:       '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
      // 【FEAT-226】Doze（端末スリープ省電力）を尊重するため inexactAllowWhileIdle に変更。
      // 習慣・予定通知は ±5 分の遅延が許容範囲。深夜帯のバッテリードレインを大幅削減。
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  /// 今日のイベント一覧をもとにタイムライン通知を再スケジュールする。
  ///
  /// 呼び出し前にリスト内の全通知をキャンセルし、未完了 ＋ 未来 ＋ startTime あり
  /// の条件を満たすイベントのみ再登録する。
  ///
  /// 【FEAT-273】[includeUncompletedReminder] が true なら +15 分未完了リマインダーも
  /// 合わせてスケジュール。ユーザーがマイページで明示 ON にしたときのみ true で呼ぶ。
  ///
  /// 【FEAT-286】重要な制約: 本メソッドは **`timelineEventsProvider(today)` の listener
  /// から呼ばれる** ため、**「今日の予定」のみ** が対象。明日以降の予定は当日アプリを
  /// 起動して timelineEventsProvider(明日) が発火するまで OS タイマー登録は走らない。
  /// reminder_settings_page.dart の説明文言もこの制約を明示している。
  static Future<void> scheduleTodayTimelineNotifications(
    List<TimelineEvent> events, {
    bool includeUncompletedReminder = false,
  }) async {
    final status = await checkPermissionStatus();
    if (status != NotifPermissionStatus.granted) return;

    final now = DateTime.now();

    // ① リスト内の全イベント通知を一旦キャンセル（完了済みも含む）
    for (final e in events) {
      await _localNotifications.cancel(e.id);
      // 【FEAT-273】未完了リマインダーも合わせてキャンセル（再スケジュール前の cleanup）
      await _localNotifications.cancel(e.id + _uncompletedReminderIdOffset);
    }

    // ② 未来 ＋ 未完了 ＋ startTime ありのイベントのみ再スケジュール
    for (final e in events) {
      if (e.isCompleted) continue;
      final startTime = e.startTime;
      if (startTime == null) continue;

      final scheduledDt = DateTime(
        e.date.year,
        e.date.month,
        e.date.day,
        startTime.hour,
        startTime.minute,
      );
      if (scheduledDt.isBefore(now.add(const Duration(seconds: 30)))) continue;

      await scheduleTimelineEventNotification(
        id:          e.id,
        title:       e.title,
        scheduledAt: scheduledDt,
      );

      // 【FEAT-273】設定 ON のときのみ +15 分未完了リマインダーも追加。
      // scheduleTimelineUncompletedReminder 側で reminderAt が過去ならスキップする
      // ため、ここでも一律呼んで安全（過去予定は内部で skip される）。
      if (includeUncompletedReminder) {
        await scheduleTimelineUncompletedReminder(
          id:          e.id,
          title:       e.title,
          scheduledAt: scheduledDt,
        );
      }
    }
  }

  // ── フォアグラウンドハンドラ ──────────────────────────────────────
  static void _setupForegroundHandler() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('FCM foreground: ${message.notification?.title}');

      final notification = message.notification;
      if (notification == null) return;

      // flutter_local_notifications でバナー表示
      // 【BUG-101】message.data を JSON encode して payload に持ち回し、タップ時に
      // onDidReceiveNotificationResponse が deep link を解決できるようにする。
      final payload = message.data.isEmpty ? null : json.encode(message.data);
      final channel = _androidChannel;
      _localNotifications.show(
        notification.title.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: payload,
      );
    });
  }
}
