// 【20260729 codebase-functional-review §8-2 対応】timelineEventsProvider の
// Google 予定 completions マージ契約テスト。
//
// 背景（この 3 契約が生まれた経緯）:
//   1. FEAT-426 以来、cached yield / fresh yield の両方が
//      `_mergeWithGoogleEvents` で completions を HTTP fetch していた
//      → cached 即時表示の約束が最大 60 秒ぶら下がる（review §2 懸念点 1）。
//   2. その対応で cached 経路を `fetchCompletions: false` にした
//      → completions を取る経路が fresh yield ただ 1 つになった。
//   3. ところが fresh yield は `_eventListsEqual(cachedEvents, fresh)` の
//      条件付きで、この比較は **backend の TimelineEvent 同士** だった。
//      Google 予定は backend の行ではないため完了状態の変化が比較に現れず、
//      「キャッシュが生きていて backend 予定に変化なし」という最も普通の
//      ケースで fresh yield ごと skip → Google 予定の完了チェックが
//      一度も反映されない（過去日は TTL 7 日間継続）= review §8-2 の退行。
//   4. 差分判定の比較対象を「実際に yield する merge 済みリスト」に変更して解消。
//
// したがって本 file は「3 つの相反しやすい要求が同時に成り立つこと」を縛る:
//   契約 1: backend 予定が同一でも Google 予定の完了状態は最終的に反映される（§8-2）
//   契約 2: 最初の emit は completions の HTTP を待たない（§2 対応の即時性）
//   契約 3: 変化が無いときは余計な再 emit をしない（FEAT-280 のチラつき防止）
//
// テスト方針:
//   - native plugin 依存（sqflite / dio / connectivity）は fake + noSuchMethod で遮断
//   - CacheService のみ実物（SharedPreferences.setMockInitialValues で isolation 保証）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/cache/cache_config.dart';
import 'package:sabiowl/core/cache/cache_service.dart';
import 'package:sabiowl/features/calendar/local/google_event_store.dart';
import 'package:sabiowl/features/calendar/providers/calendar_provider.dart'
    show localGoogleEventStoreProvider, googleEventCompletionServiceProvider;
import 'package:sabiowl/features/calendar/services/google_event_completion_service.dart';
import 'package:sabiowl/features/timeline/providers/timeline_provider.dart';
import 'package:sabiowl/features/timeline/services/timeline_service.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────
// noSuchMethod を定義することで「テストで使うメソッドだけ override」できる
// （mockito 非依存、他メソッドが呼ばれたら NoSuchMethodError で検出される）。

class _FakeTimelineService implements TimelineService {
  _FakeTimelineService(this.events);
  final List<TimelineEvent> events;
  int fetchCallCount = 0;

  @override
  Future<List<TimelineEvent>> fetchEvents(DateTime date) async {
    fetchCallCount++;
    return events;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGoogleEventStore implements LocalGoogleEventStore {
  _FakeGoogleEventStore(this.events);
  final List<GoogleEvent> events;

  @override
  Future<List<GoogleEvent>> queryByDateRange(DateTime from, DateTime to) async =>
      events;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCompletionService implements GoogleEventCompletionService {
  _FakeCompletionService(this.completions);
  final List<GoogleEventCompletion> completions;

  /// 「最初の emit までに completions を取りに行っていないか」を測るカウンタ。
  int fetchCallCount = 0;

  @override
  Future<List<GoogleEventCompletion>> fetchAll({
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    fetchCallCount++;
    return completions;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── Fixtures ───────────────────────────────────────────────────────────────

final _date = DateTime(2026, 7, 29);
const _googleEventId = 'gcal-evt-abc-123';

/// backend TimelineEvent 1 件（cache と fresh で同一内容 = `_eventListsEqual` true）。
TimelineEvent _backendEvent() => TimelineEvent(
      id:          101,
      title:       '朝の準備',
      date:        _date,
      startTime:   const TimeOfDay(hour: 7, minute: 0),
      endTime:     const TimeOfDay(hour: 7, minute: 30),
      category:    '健康',
      iconKey:     'wb_sunny',
      isCompleted: false,
    );

/// cache に seed する JSON（`_timelineEventToJson` と同じ形）。
Map<String, dynamic> _backendEventJson() => {
      'id':              101,
      'title':           '朝の準備',
      'date':            '2026-07-29',
      'start_time':      '07:00:00',
      'end_time':        '07:30:00',
      'category':        '健康',
      'icon_key':        'wb_sunny',
      'memo':            '',
      'habit':           null,
      'is_completed':    false,
      'google_event_id': null,
    };

GoogleEvent _googleEvent() => GoogleEvent(
      googleEventId: _googleEventId,
      title:         '歯医者',
      date:          _date,
      startTime:     const TimeOfDay(hour: 14, minute: 0),
      endTime:       const TimeOfDay(hour: 15, minute: 0),
      lastSyncedAt:  _date,
    );

/// provider を実行し、data emit ごとに「そのリスト」と「その時点の
/// completions fetch 回数」を記録する。
Future<
    ({
      List<List<TimelineEvent>> emits,
      List<int> completionCallsAtEmit,
    })> _collectEmits(
  ProviderContainer container,
  _FakeCompletionService completionService,
) async {
  final emits = <List<TimelineEvent>>[];
  final completionCallsAtEmit = <int>[];

  final sub = container.listen<AsyncValue<List<TimelineEvent>>>(
    timelineEventsProvider(_date),
    (_, next) {
      next.whenData((list) {
        emits.add(list);
        completionCallsAtEmit.add(completionService.fetchCallCount);
      });
    },
    fireImmediately: true,
  );
  addTearDown(sub.close);

  // async* provider の yield を消化しきる（cached yield → fetch → fresh yield）。
  await pumpEventQueue();

  return (emits: emits, completionCallsAtEmit: completionCallsAtEmit);
}

ProviderContainer _buildContainer({
  required CacheService cache,
  required TimelineService timelineService,
  required LocalGoogleEventStore store,
  required GoogleEventCompletionService completionService,
}) {
  final container = ProviderContainer(
    overrides: [
      cacheServiceProvider.overrideWithValue(cache),
      timelineServiceProvider.overrideWithValue(timelineService),
      localGoogleEventStoreProvider.overrideWithValue(store),
      googleEventCompletionServiceProvider.overrideWithValue(completionService),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  // CACHE_ENABLED=false でビルドされた環境ではキャッシュ経路自体が無効になり、
  // 本 file の前提（cached yield が起きる）が崩れるため明示的に確認しておく。
  setUpAll(() {
    expect(
      CacheConfig.enabled,
      isTrue,
      reason: '本テストは cached yield 経路を前提とする',
    );
  });

  group('20260729 review §8-2: timelineEventsProvider の Google completions マージ契約',
      () {
    // ────────────────────────────────────────────────────────────────────
    // 契約 1: 退行の本体
    // ────────────────────────────────────────────────────────────────────
    test(
        '契約 1: cache 済 backend イベントと fresh が同一でも、Google 予定の完了状態は最終 emit に反映される',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);

      // cache を seed（= backend 予定が既知の状態でホームを再訪した状況）。
      await cache.setList(
        'timeline_events:2026-07-29',
        [_backendEventJson()],
        ttl: const Duration(days: 7),
      );

      // fresh も同一内容 → `_eventListsEqual(cachedEvents, fresh)` は true。
      final timelineService = _FakeTimelineService([_backendEvent()]);
      final completionService = _FakeCompletionService([
        GoogleEventCompletion(
          googleEventId:      _googleEventId,
          eventDate:          _date,
          isCompleted:        true, // ← backend には完了が記録されている
          onTimeBonusAwarded: false,
        ),
      ]);

      final container = _buildContainer(
        cache:             cache,
        timelineService:   timelineService,
        store:             _FakeGoogleEventStore([_googleEvent()]),
        completionService: completionService,
      );

      final result = await _collectEmits(container, completionService);

      expect(
        result.emits.length,
        greaterThanOrEqualTo(2),
        reason: 'backend 予定が同一でも、completions 反映のため fresh yield が必要',
      );

      final finalList = result.emits.last;
      final googleEvent = finalList.firstWhere(
        (e) => e.googleEventId == _googleEventId,
        orElse: () => throw StateError('Google 予定が merge されていない'),
      );

      expect(
        googleEvent.isCompleted,
        isTrue,
        reason: '旧実装では fresh yield が skip され false のままだった（§8-2 の退行）',
      );
      expect(googleEvent.isGoogleOrigin, isTrue);
      // backend 予定側は巻き込まれていない
      expect(finalList.any((e) => e.id == 101 && !e.isCompleted), isTrue);
    });

    // ────────────────────────────────────────────────────────────────────
    // 契約 2: §2 対応（cached 即時性）が保たれていること
    // ────────────────────────────────────────────────────────────────────
    test('契約 2: 最初の emit は completions の HTTP を待たずに返る（cached 即時表示）',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);

      await cache.setList(
        'timeline_events:2026-07-29',
        [_backendEventJson()],
        ttl: const Duration(days: 7),
      );

      final completionService = _FakeCompletionService([
        GoogleEventCompletion(
          googleEventId:      _googleEventId,
          eventDate:          _date,
          isCompleted:        true,
          onTimeBonusAwarded: false,
        ),
      ]);

      final container = _buildContainer(
        cache:             cache,
        timelineService:   _FakeTimelineService([_backendEvent()]),
        store:             _FakeGoogleEventStore([_googleEvent()]),
        completionService: completionService,
      );

      final result = await _collectEmits(container, completionService);

      expect(
        result.completionCallsAtEmit.first,
        0,
        reason: 'cached yield は fetchCompletions=false で completions を待たない',
      );
      expect(
        result.emits.first.firstWhere((e) => e.googleEventId == _googleEventId).isCompleted,
        isFalse,
        reason: '最初の emit では完了状態は未確定（1 テンポ遅れて付く）',
      );
      expect(
        result.completionCallsAtEmit.last,
        greaterThanOrEqualTo(1),
        reason: 'fresh yield 側では completions を取得しているはず',
      );
    });

    // ────────────────────────────────────────────────────────────────────
    // 契約 3: チラつき防止（FEAT-280 の元々の意図）が壊れていないこと
    // ────────────────────────────────────────────────────────────────────
    test('契約 3: Google 予定が無く backend も同一なら fresh yield は skip される（再 emit なし）',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);

      await cache.setList(
        'timeline_events:2026-07-29',
        [_backendEventJson()],
        ttl: const Duration(days: 7),
      );

      final completionService = _FakeCompletionService([]);
      final container = _buildContainer(
        cache:             cache,
        timelineService:   _FakeTimelineService([_backendEvent()]),
        store:             _FakeGoogleEventStore([]), // Google 予定なし
        completionService: completionService,
      );

      final result = await _collectEmits(container, completionService);

      expect(
        result.emits.length,
        1,
        reason: '内容が同一なら再 emit しない（比較対象を merge 済みに変えても維持）',
      );
      expect(
        completionService.fetchCallCount,
        0,
        reason: 'Google 予定ゼロなら completions は 1 度も叩かない（早期 return）',
      );
    });
  });
}
