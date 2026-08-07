// 【FEAT-509】ChallengeNotificationService 契約テスト (4 件)
//
// 検証対象:
//   T1: isEnabled() default = false
//   T2: setEnabled(true) → zonedSchedule 呼出 + SharedPreferences 永続化
//   T3: setEnabled(false) → cancel(42509) 呼出 + SharedPreferences 永続化
//   T4: rescheduleIfNeeded() + enabled=true + pending 0 件 → 再予約される

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:sabiowl/features/challenge/services/challenge_notification_service.dart';

// ── FakeNotificationScheduler ────────────────────────────────────────────────

class FakeNotificationScheduler implements NotificationScheduler {
  int zonedScheduleCalls = 0;
  final List<int> cancelledIds = [];
  List<PendingNotificationRequest> pendingRequests = [];

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
  }) async {
    zonedScheduleCalls++;
  }

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async =>
      pendingRequests;
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    // tz.TZDateTime.utc() が内部で使うタイムゾーンデータを初期化
    tz_data.initializeTimeZones();
  });

  group('FEAT-509: ChallengeNotificationService 契約テスト', () {
    late FakeNotificationScheduler fake;
    late ChallengeNotificationService service;

    setUp(() {
      fake = FakeNotificationScheduler();
      service = ChallengeNotificationService(fake);
    });

    // ────────────────────────────────────────────────────────────────────────
    // T1: isEnabled() default = false
    // ────────────────────────────────────────────────────────────────────────
    test('T1: isEnabled() はデフォルト false を返す', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await service.isEnabled(), isFalse, reason: 'default OFF (opt-in 原則)');
    });

    // ────────────────────────────────────────────────────────────────────────
    // T2: setEnabled(true) → zonedSchedule 呼出 + SharedPreferences 永続化
    // ────────────────────────────────────────────────────────────────────────
    test('T2: setEnabled(true) → scheduleMonthlyReminder が呼ばれ SharedPreferences に true が保存される', () async {
      SharedPreferences.setMockInitialValues({});
      await service.setEnabled(true);
      expect(
        fake.zonedScheduleCalls,
        1,
        reason: 'zonedSchedule が 1 回呼ばれる (次月 1 日 08:00 予約)',
      );
      expect(
        await service.isEnabled(),
        isTrue,
        reason: 'SharedPreferences に true が永続化される',
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T3: setEnabled(false) → cancel(42509) 呼出 + SharedPreferences 永続化
    // ────────────────────────────────────────────────────────────────────────
    test('T3: setEnabled(false) → cancel(42509) が呼ばれ SharedPreferences に false が保存される', () async {
      SharedPreferences.setMockInitialValues({'challenge_result_notif_enabled': true});
      await service.setEnabled(false);
      expect(
        fake.cancelledIds,
        contains(42509),
        reason: 'cancel(42509) が呼ばれる (FEAT-509 固有 notif ID)',
      );
      expect(
        await service.isEnabled(),
        isFalse,
        reason: 'SharedPreferences に false が永続化される',
      );
    });

    // ────────────────────────────────────────────────────────────────────────
    // T4: rescheduleIfNeeded() + enabled=true + pending 0 件 → 再予約される
    // ────────────────────────────────────────────────────────────────────────
    test('T4: rescheduleIfNeeded() で enabled=true かつ pending 0 件 → scheduleMonthlyReminder が呼ばれる', () async {
      SharedPreferences.setMockInitialValues({'challenge_result_notif_enabled': true});
      fake.pendingRequests = []; // 端末再起動 / OS 削除後の状態 (予約なし)
      await service.rescheduleIfNeeded();
      expect(
        fake.zonedScheduleCalls,
        1,
        reason: '予約が消えていたため再予約される',
      );
    });
  });
}
