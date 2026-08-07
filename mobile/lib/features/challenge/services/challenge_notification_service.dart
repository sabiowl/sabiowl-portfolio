// 【FEAT-509】チャレンジ結果 opt-in 通知サービス
//
// 毎月 1 日 08:00 (ローカルタイム) に「先月のチャレンジ結果をご確認ください」を予約。
// default OFF、ユーザーが Settings で明示的に ON にした場合のみ発火。
// tap 後は notification_deep_link.dart 経由で /home に遷移、
// v1.0.5 Option A (bootstrapPendingChallengeRewardsProvider) の SnackBar と連動。

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/l10n/service_l10n.dart';  // 【FEAT-489 Phase 2D】BuildContext なし層の l10n
import '../../../core/services/notification_service.dart';

// ── NotificationScheduler 抽象インターフェース (テスト用 Fake 注入を可能にする) ────
abstract class NotificationScheduler {
  Future<void> zonedSchedule(
    int id,
    String title,
    String body,
    tz.TZDateTime scheduledDate,
    NotificationDetails notificationDetails, {
    required AndroidScheduleMode androidScheduleMode,
    required UILocalNotificationDateInterpretation uiLocalNotificationDateInterpretation,
    String? payload,
  });
  Future<void> cancel(int id);
  Future<List<PendingNotificationRequest>> pendingNotificationRequests();
}

// ── 本番用: FlutterLocalNotificationsPlugin をラップ ────────────────────────────
class FlutterLocalNotificationScheduler implements NotificationScheduler {
  final FlutterLocalNotificationsPlugin _plugin;
  const FlutterLocalNotificationScheduler(this._plugin);

  @override
  Future<void> zonedSchedule(
    int id,
    String title,
    String body,
    tz.TZDateTime scheduledDate,
    NotificationDetails notificationDetails, {
    required AndroidScheduleMode androidScheduleMode,
    required UILocalNotificationDateInterpretation uiLocalNotificationDateInterpretation,
    String? payload,
  }) =>
      _plugin.zonedSchedule(
        id, title, body, scheduledDate, notificationDetails,
        androidScheduleMode: androidScheduleMode,
        uiLocalNotificationDateInterpretation: uiLocalNotificationDateInterpretation,
        payload: payload,
      );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() =>
      _plugin.pendingNotificationRequests();
}

// ── ChallengeNotificationService ──────────────────────────────────────────────
class ChallengeNotificationService {
  static const _kEnabledKey = 'challenge_result_notif_enabled';
  static const _notifId = 42509; // FEAT-509 固有 ID (他 notification と衝突回避)

  final NotificationScheduler _scheduler;

  const ChallengeNotificationService(this._scheduler);

  /// opt-in フラグを取得。default OFF。
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabledKey) ?? false;
  }

  /// toggle 変更。ON なら scheduleMonthlyReminder、OFF なら cancelReminder を呼ぶ。
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, enabled);
    if (enabled) {
      await scheduleMonthlyReminder();
    } else {
      await cancelReminder();
    }
  }

  /// 次月 1 日 08:00 ローカルタイムに発火予約。
  /// notification_service.dart:295-328 と同パターン (UTC 絶対時刻、inexactAllowWhileIdle)。
  Future<void> scheduleMonthlyReminder() async {
    final scheduledAt = _nextMonthFirstDay(hour: 8);
    // 過去の時刻はスキップ（余裕を 30 秒持たせる）
    if (scheduledAt.isBefore(DateTime.now().add(const Duration(seconds: 30)))) {
      return;
    }

    final utcDt = scheduledAt.toUtc();
    final tzScheduled = tz.TZDateTime.utc(
      utcDt.year, utcDt.month, utcDt.day, utcDt.hour, utcDt.minute,
    );

    // 【FEAT-489 Phase 2D】通知文言 / チャンネル名は locale 依存。BuildContext を
    // 持たない service 層なので ServiceL10n 経由で解決する。チャンネル id
    // ('challenge_result') は notification_service.dart の _challengeChannel と同値。
    final l10n = ServiceL10n.current;
    await _scheduler.zonedSchedule(
      _notifId,
      l10n.challengeNotificationResultTitle,
      l10n.challengeNotificationResultBodySabi_message,
      tzScheduled,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'challenge_result',
          l10n.coreNotificationChallengeChannelName,
          channelDescription: l10n.coreNotificationChallengeChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: 'challenge_result', // tap 時 deep link 用
    );
  }

  /// 予約を cancel する。toggle OFF 時に呼ぶ。
  Future<void> cancelReminder() async {
    await _scheduler.cancel(_notifId);
  }

  /// 端末再起動 / OS 削除で予約が消えている場合に再予約する。app 起動時に呼ぶ。
  Future<void> rescheduleIfNeeded() async {
    if (!await isEnabled()) return;
    final pending = await _scheduler.pendingNotificationRequests();
    if (!pending.any((r) => r.id == _notifId)) {
      await scheduleMonthlyReminder();
    }
  }

  // 次月 1 日指定時刻のローカル DateTime を返す。
  static DateTime _nextMonthFirstDay({required int hour}) {
    final now = DateTime.now();
    return DateTime(now.year, now.month + 1, 1, hour, 0);
  }
}

// ── Riverpod Provider ─────────────────────────────────────────────────────────
final challengeNotificationServiceProvider = Provider<ChallengeNotificationService>((ref) {
  return ChallengeNotificationService(
    FlutterLocalNotificationScheduler(NotificationService.localNotifications),
  );
});
