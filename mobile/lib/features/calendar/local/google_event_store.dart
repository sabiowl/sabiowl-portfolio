import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// 【FEAT-426】Google カレンダー予定 1 件分のローカルモデル。
///
/// プライバシー保護のため、予定本文 (タイトル / 時刻 / メモ) は端末内の
/// SQLite (`LocalGoogleEventStore`) のみに保存し、Backend へは送信しない。
/// 完了状態の Multi-device 同期は `GoogleEventCompletion` (Backend) が担う。
@immutable
class GoogleEvent {
  const GoogleEvent({
    required this.googleEventId,
    required this.title,
    required this.date,
    this.startTime,
    this.endTime,
    this.memo = '',
    required this.lastSyncedAt,
  });

  final String    googleEventId;
  final String    title;
  final DateTime  date;
  final TimeOfDay? startTime;
  final TimeOfDay? endTime;
  final String    memo;
  final DateTime  lastSyncedAt;

  factory GoogleEvent.fromMap(Map<String, Object?> map) {
    return GoogleEvent(
      googleEventId: map['google_event_id'] as String,
      title:         map['title'] as String,
      date:          DateTime.parse(map['date'] as String),
      startTime:     _parseTime(map['start_time'] as String?),
      endTime:       _parseTime(map['end_time'] as String?),
      memo:          map['memo'] as String? ?? '',
      lastSyncedAt:  DateTime.parse(map['last_synced_at'] as String),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'google_event_id': googleEventId,
      'title':           title,
      'date':            _formatDate(date),
      'start_time':      startTime == null ? null : _formatTime(startTime!),
      'end_time':        endTime == null ? null : _formatTime(endTime!),
      'memo':            memo,
      'last_synced_at':  lastSyncedAt.toIso8601String(),
    };
  }

  static TimeOfDay? _parseTime(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split(':');
    if (parts.length < 2) return null;
    final hour   = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  static String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 【FEAT-426】Google カレンダー予定本文を端末内 SQLite に保存するストア。
///
/// 設計 Y (ハイブリッド): Backend には予定本文を送信しない。同期は
/// [GoogleCalendarSyncService] が Google Calendar API から取得した予定を
/// 本ストアへ [upsert] することで完結する。
class LocalGoogleEventStore {
  static const _kDbName        = 'sabiowl_google_events.db';
  static const _kSchemaVersion = 1;

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      join(dir, _kDbName),
      version: _kSchemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
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
    await db.execute(
        'CREATE INDEX idx_google_events_date ON google_events(date)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 【Pre-mortem 想定】v2 以降のスキーマ変更時はここに ALTER TABLE を追記する。
    // v1 → v1 では何もしない。
  }

  /// [event] を upsert する（`google_event_id` が既存なら更新）。
  Future<void> upsert(GoogleEvent event) async {
    final db = await _database;
    await db.insert(
      'google_events',
      event.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// [from] 〜 [to]（両端含む）の予定を日付昇順で返す。
  Future<List<GoogleEvent>> queryByDateRange(DateTime from, DateTime to) async {
    final db = await _database;
    final rows = await db.query(
      'google_events',
      where: 'date >= ? AND date <= ?',
      whereArgs: [GoogleEvent._formatDate(from), GoogleEvent._formatDate(to)],
      orderBy: 'date ASC, start_time ASC',
    );
    return rows.map(GoogleEvent.fromMap).toList();
  }

  /// 全件の `google_event_id` 一覧を返す（同期時の差分削除判定用）。
  Future<Set<String>> allGoogleEventIds() async {
    final db = await _database;
    final rows = await db.query('google_events', columns: ['google_event_id']);
    return rows.map((r) => r['google_event_id'] as String).toSet();
  }

  /// 指定 `google_event_id` の予定を削除する。
  Future<void> delete(String googleEventId) async {
    final db = await _database;
    await db.delete(
      'google_events',
      where: 'google_event_id = ?',
      whereArgs: [googleEventId],
    );
  }

  /// 全予定を削除する（連携解除 / ログアウト時）。
  Future<int> clearAll() async {
    final db = await _database;
    return db.delete('google_events');
  }
}
