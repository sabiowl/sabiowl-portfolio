// 【FEAT-426 (2026-06-11)】LocalGoogleEventStore (sqflite) の契約テスト。
//
// 設計 Y (ハイブリッド): Google カレンダー予定の本文 (タイトル/時刻/メモ) は
// 端末内 SQLite のみに保存する。本テストは sqflite_common_ffi で
// プラットフォームチャンネルなしに以下 5 シナリオを縛る:
//   1. upsert + queryByDateRange で取得できる
//   2. upsert で同一 google_event_id は重複作成されず update される
//   3. delete で削除される
//   4. clearAll で全削除される
//   5. schema migration (onUpgrade) でデータが保持される
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sabiowl/features/calendar/local/google_event_store.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  GoogleEvent buildEvent({
    String googleEventId = 'evt-1',
    String title = '会議',
    DateTime? date,
    TimeOfDay? startTime,
    String memo = '',
    DateTime? lastSyncedAt,
  }) {
    return GoogleEvent(
      googleEventId: googleEventId,
      title: title,
      date: date ?? DateTime(2026, 6, 11),
      startTime: startTime,
      endTime: null,
      memo: memo,
      lastSyncedAt: lastSyncedAt ?? DateTime(2026, 6, 11, 9, 0),
    );
  }

  group('LocalGoogleEventStore', () {
    late LocalGoogleEventStore store;

    setUp(() {
      store = LocalGoogleEventStore();
    });

    tearDown(() async {
      await store.clearAll();
    });

    test('upsert + queryByDateRange で取得できる', () async {
      await store.upsert(buildEvent(
        googleEventId: 'evt-1',
        title: '会議A',
        date: DateTime(2026, 6, 11),
      ));

      final events = await store.queryByDateRange(
        DateTime(2026, 6, 10),
        DateTime(2026, 6, 12),
      );

      expect(events, hasLength(1));
      expect(events.first.googleEventId, 'evt-1');
      expect(events.first.title, '会議A');
    });

    test('upsert で同一 google_event_id は重複作成されず update される', () async {
      await store.upsert(buildEvent(
        googleEventId: 'evt-2',
        title: '元のタイトル',
        date: DateTime(2026, 6, 11),
      ));
      await store.upsert(buildEvent(
        googleEventId: 'evt-2',
        title: '更新後タイトル',
        date: DateTime(2026, 6, 11),
      ));

      final events = await store.queryByDateRange(
        DateTime(2026, 6, 10),
        DateTime(2026, 6, 12),
      );

      expect(events, hasLength(1));
      expect(events.first.title, '更新後タイトル');
    });

    test('delete で削除される', () async {
      await store.upsert(buildEvent(googleEventId: 'evt-3'));

      await store.delete('evt-3');

      final events = await store.queryByDateRange(
        DateTime(2026, 6, 10),
        DateTime(2026, 6, 12),
      );
      expect(events, isEmpty);
    });

    test('clearAll で全削除される', () async {
      await store.upsert(buildEvent(googleEventId: 'evt-4', date: DateTime(2026, 6, 11)));
      await store.upsert(buildEvent(googleEventId: 'evt-5', date: DateTime(2026, 6, 12)));

      final deletedCount = await store.clearAll();

      expect(deletedCount, 2);
      final ids = await store.allGoogleEventIds();
      expect(ids, isEmpty);
    });

    test('schema migration (onUpgrade) でデータが保持される', () async {
      // LocalGoogleEventStore と同一スキーマの DB を v1 で作成しデータを投入した後、
      // v2 (onUpgrade 経由) で再オープンしてもデータが保持されることを確認する。
      final dir = await databaseFactory.getDatabasesPath();
      final path = join(dir, 'sabiowl_google_events_migration_test.db');
      await databaseFactory.deleteDatabase(path);

      final v1 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE google_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                google_event_id TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                date TEXT NOT NULL,
                start_time TEXT,
                end_time TEXT,
                memo TEXT,
                last_synced_at TEXT NOT NULL
              )
            ''');
          },
        ),
      );
      await v1.insert('google_events', buildEvent(googleEventId: 'evt-6').toMap());
      await v1.close();

      final v2 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onUpgrade: (db, oldVersion, newVersion) async {
            // v1 → v2 で破壊的変更なし（FEAT-426 v1 時点の想定）
          },
        ),
      );

      final rows = await v2.query('google_events');
      expect(rows, hasLength(1));
      expect(rows.first['google_event_id'], 'evt-6');

      await v2.close();
      await databaseFactory.deleteDatabase(path);
    });
  });
}
