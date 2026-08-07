// 【FEAT-504 (2026-07-29)】Calendar 画面 Google イベント merge 契約テスト。
//
// 検証対象:
//   1. DailyTimeline.fromGoogleEvent() が正しく変換できる
//      (id が負値・source='google'・startTime が 'HH:MM' 形式)
//   2. CalendarBootstrapData.copyWith() / DailyData.copyWith() が
//      既存フィールドを保持しつつ timeline のみ置換できる
//
// DI 依存 (LocalGoogleEventStore / GoogleEventCompletionService) は
// _mergeGoogleEventsIntoDaily が provider 内 try-catch で自己保護するため、
// ここでは model 層のみを単体テストで縛る。
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/calendar/models/calendar_models.dart';

CalendarBootstrapData _buildMinimalBootstrap({List<DailyTimeline> timeline = const []}) {
  return CalendarBootstrapData.fromJson({
    'calendar': {
      'year': 2026,
      'month': 7,
      'days': <dynamic>[],
      'summary': {
        'completion_rate': 0,
        'current_streak': 0,
        'days_with_any': 0,
        'past_days': 0,
        'total_habits': 0,
      },
    },
    'streak': {
      'current_streak': 5,
      'best_streak': 10,
      'days_to_record': 0,
      'seven_days': <dynamic>[],
      'habit_streaks': <dynamic>[],
    },
    'daily': {
      'date': '2026-07-29',
      'is_today': true,
      'is_future': false,
      'habits': <dynamic>[],
      'todos': <dynamic>[],
      'timeline_events': timeline
          .map((t) => {
                'id':           t.id,
                'title':        t.title,
                'category':     t.category,
                'icon_key':     t.iconKey,
                'start_time':   t.startTime,
                'end_time':     t.endTime,
                'is_completed': t.isCompleted,
                'memo':         t.memo,
                'source':       t.source,
              })
          .toList(),
    },
  });
}

void main() {
  group('FEAT-504 Calendar Google event merge 契約テスト', () {
    // ── テスト 1: DailyTimeline.fromGoogleEvent() の変換 ────────────────────
    test('1: fromGoogleEvent() は id が負値・source=google・startTime=HH:MM で変換できる',
        () {
      const googleEventId = 'event-abc-123';
      final event = DailyTimeline.fromGoogleEvent(
        googleEventId: googleEventId,
        title:         '朝の会議',
        startTime:     '09:00',
        endTime:       '10:00',
        memo:          'メモ',
        isCompleted:   true,
      );

      expect(event.id, isNegative, reason: 'hashCode 反転で負値になるはず');
      expect(event.googleEventId, equals(googleEventId));
      expect(event.source, equals('google'));
      expect(event.isExternal, isTrue);
      expect(event.title, equals('朝の会議'));
      expect(event.startTime, equals('09:00'));
      expect(event.endTime, equals('10:00'));
      expect(event.memo, equals('メモ'));
      expect(event.isCompleted, isTrue);
      expect(event.category, equals('その他'));
    });

    // ── テスト 2: copyWith() チェーンで timeline のみ置換できる ─────────────
    test('2: CalendarBootstrapData.copyWith(daily:) + DailyData.copyWith(timeline:) で timeline のみ置換し他フィールドを保持する',
        () {
      final bootstrap = _buildMinimalBootstrap();

      final googleEvent = DailyTimeline.fromGoogleEvent(
        googleEventId: 'evt-999',
        title:         '外部カレンダー予定',
        startTime:     '14:00',
      );

      final mergedDaily = bootstrap.daily.copyWith(timeline: [googleEvent]);

      // timeline が差し替わっている
      expect(mergedDaily.timeline.length, equals(1));
      expect(mergedDaily.timeline.first.googleEventId, equals('evt-999'));

      // 他フィールドは保持されている
      expect(mergedDaily.date,     equals(DateTime(2026, 7, 29)));
      expect(mergedDaily.isToday,  isTrue);
      expect(mergedDaily.isFuture, isFalse);
      expect(mergedDaily.habits,   isEmpty);
      expect(mergedDaily.todos,    isEmpty);

      // CalendarBootstrapData.copyWith() 経路
      final updatedBootstrap = bootstrap.copyWith(daily: mergedDaily);

      expect(updatedBootstrap.daily.timeline.length, equals(1));
      expect(updatedBootstrap.calendar.year,          equals(2026));
      expect(updatedBootstrap.streak.currentStreak,   equals(5));
    });
  });
}
