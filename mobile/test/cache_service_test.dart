// 【FEAT-280】CacheService の契約テスト。
//
// 検証対象:
//   - set / get の往復（Map / List）
//   - TTL 切れの取得（古いデータでも返ること）
//   - invalidate / invalidateByPrefix
//   - clearForPlayerSwitch (Pre-mortem #2: 他人データ混入防止)
//   - garbageCollect (Pre-mortem #3: 容量爆発防止)
//   - feature flag (CacheConfig.enabled = false 時は no-op になること) — 実環境では
//     `--dart-define=CACHE_ENABLED=false` でビルドして検証する。Dart の `const`
//     束縛により単体テストでは flag 切替不可のため、本ファイルでは扱わない。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/cache/cache_service.dart';

void main() {
  group('CacheService set/get round-trip', () {
    late SharedPreferences prefs;
    late CacheService cache;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      cache = CacheService(prefs);
    });

    test('setMap then getMap returns same data + isFresh=true', () async {
      await cache.setMap(
        'home',
        {'name': 'alice', 'level': 5},
        ttl: const Duration(hours: 1),
      );
      final entry = cache.getMap('home');
      expect(entry, isNotNull);
      expect(entry!.data, {'name': 'alice', 'level': 5});
      expect(entry.isFresh, isTrue);
    });

    test('setList then getList returns same data', () async {
      await cache.setList(
        'habits',
        [
          {'id': 1, 'name': 'A'},
          {'id': 2, 'name': 'B'},
        ],
        ttl: const Duration(hours: 1),
      );
      final entry = cache.getList('habits');
      expect(entry, isNotNull);
      expect(entry!.data, hasLength(2));
      expect((entry.data[0] as Map)['id'], 1);
    });

    test('expired entry is still returned with isFresh=false', () async {
      // 過去の時刻を強制保存（jsonEncode で書き込んだ後、SharedPreferences の
      // 中身を期限切れタイムスタンプに書き換える）
      await cache.setMap('expired', {'x': 1}, ttl: const Duration(seconds: 1));
      // 期限切れまで待たずに、内部的に期限切れ扱いさせるための ttl=負値で再設定はできないため、
      // 短い待機で対応。
      await Future.delayed(const Duration(milliseconds: 1500));
      final entry = cache.getMap('expired');
      expect(entry, isNotNull);
      expect(entry!.isFresh, isFalse, reason: 'TTL 切れでも data は返る（fallback として）');
    });

    test('missing key returns null', () {
      expect(cache.getMap('nonexistent'), isNull);
      expect(cache.getList('nonexistent'), isNull);
    });

    test('corrupt JSON is silently dropped on read', () async {
      // 直接 prefs に壊れた JSON を書き込む
      await prefs.setString('cache_v1:bad', '{not-json');
      final entry = cache.getMap('bad');
      expect(entry, isNull, reason: '壊れたエントリは null を返す');
      expect(prefs.getString('cache_v1:bad'), isNull,
          reason: '読み取り時に自動削除される');
    });
  });

  group('invalidate operations', () {
    late CacheService cache;
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      cache = CacheService(prefs);
      await cache.setMap('home', {'x': 1}, ttl: const Duration(hours: 1));
      await cache.setMap(
        'timeline_events:2026-06-01',
        {'a': 1},
        ttl: const Duration(hours: 1),
      );
      await cache.setMap(
        'timeline_events:2026-06-02',
        {'b': 2},
        ttl: const Duration(hours: 1),
      );
    });

    test('invalidate removes single key', () async {
      await cache.invalidate('home');
      expect(cache.getMap('home'), isNull);
      // 他のキーは残る
      expect(cache.getMap('timeline_events:2026-06-01'), isNotNull);
    });

    test('invalidateByPrefix removes all matching keys', () async {
      await cache.invalidateByPrefix('timeline_events:');
      expect(cache.getMap('timeline_events:2026-06-01'), isNull);
      expect(cache.getMap('timeline_events:2026-06-02'), isNull);
      // prefix 不一致のキーは残る
      expect(cache.getMap('home'), isNotNull);
    });
  });

  group('Pre-mortem #2: clearForPlayerSwitch (account switch leakage prevention)',
      () {
    test('clearForPlayerSwitch removes ALL cache entries', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);

      // 既存ユーザーのキャッシュを多種類保存
      await cache.setMap('home', {'name': 'alice'}, ttl: const Duration(hours: 1));
      await cache.setList(
        'timeline_events:2026-06-01',
        [{'id': 1}],
        ttl: const Duration(hours: 1),
      );
      await cache.setMap(
        'calendar_bootstrap:2026-06:2026-06-01',
        {'data': 'old'},
        ttl: const Duration(hours: 1),
      );

      // 非キャッシュキー（auth token 等）も保存しておき、削除対象外か確認
      await prefs.setString('hg_token', 'user_token_xyz');
      await prefs.setString('some_other_key', 'preserved');

      await cache.clearForPlayerSwitch();

      // 全キャッシュ消失
      expect(cache.getMap('home'), isNull);
      expect(cache.getList('timeline_events:2026-06-01'), isNull);
      expect(cache.getMap('calendar_bootstrap:2026-06:2026-06-01'), isNull);

      // 非キャッシュキーは生存
      expect(prefs.getString('hg_token'), 'user_token_xyz');
      expect(prefs.getString('some_other_key'), 'preserved');
    });

    test(
        'after clearForPlayerSwitch, new user data fetched fresh is correctly isolated',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);

      // User A のデータ
      await cache.setMap(
        'home',
        {'name': 'alice', 'level': 5},
        ttl: const Duration(hours: 1),
      );
      expect(cache.getMap('home')!.data['name'], 'alice');

      // サインアウト相当
      await cache.clearForPlayerSwitch();

      // User B サインイン直後（cache 空）
      expect(cache.getMap('home'), isNull,
          reason: 'User B のサインイン直後は cache が空 = 自分の fresh fetch が必須');

      // User B が新規 fetch して保存
      await cache.setMap(
        'home',
        {'name': 'bob', 'level': 12},
        ttl: const Duration(hours: 1),
      );
      expect(cache.getMap('home')!.data['name'], 'bob',
          reason: 'User B のデータが正しく保存され、User A のデータは混入していない');
    });
  });

  group('Pre-mortem #3: garbageCollect (storage explosion prevention)', () {
    test('GC removes entries past hard expiry (TTL × 3)', () async {
      // 起動時 GC をシミュレートするため、まずキャッシュに保存して
      // その後で SharedPreferences を直接いじって期限切れを偽装する。
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);

      // 通常の保存（TTL 1 時間 → 3 時間後に hard expire）
      await cache.setMap('recent', {'x': 1}, ttl: const Duration(hours: 1));

      // 直接 prefs に「TTL 1 時間、4 時間前に保存した」エントリを偽装書き込み
      final fourHoursAgo = DateTime.now()
          .subtract(const Duration(hours: 4))
          .millisecondsSinceEpoch;
      final threeHoursAgo = DateTime.now()
          .subtract(const Duration(hours: 3))
          .millisecondsSinceEpoch;
      final staleWrapper = {
        'cached_at_ms':  fourHoursAgo,
        'expires_at_ms': threeHoursAgo, // 3 時間前に期限切れ = TTL 1 時間
        'data':          {'old': 'data'},
      };
      // Library で reflectable していないため jsonEncode 直接利用
      // ignore: prefer_const_constructors
      await prefs.setString(
        'cache_v1:hard_expired',
        '{"cached_at_ms":${staleWrapper['cached_at_ms']},'
        '"expires_at_ms":${staleWrapper['expires_at_ms']},'
        '"data":{"old":"data"}}',
      );

      await cache.garbageCollect();

      expect(cache.getMap('recent'), isNotNull, reason: '新しいエントリは保持');
      expect(cache.getMap('hard_expired'), isNull, reason: 'TTL × 3 超は削除');
    });

    test('GC removes corrupt entries', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);

      await cache.setMap('good', {'x': 1}, ttl: const Duration(hours: 1));
      await prefs.setString('cache_v1:corrupt', '{not-json');

      await cache.garbageCollect();

      expect(cache.getMap('good'), isNotNull);
      expect(prefs.getString('cache_v1:corrupt'), isNull, reason: '壊れたエントリは GC で削除');
    });
  });

  group('approximateSizeBytes', () {
    test('returns 0 for empty cache', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);
      expect(cache.approximateSizeBytes(), 0);
    });

    test('grows with saved entries', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = CacheService(prefs);
      await cache.setMap(
        'big',
        {'data': 'x' * 1000},
        ttl: const Duration(hours: 1),
      );
      expect(cache.approximateSizeBytes(), greaterThan(1000));
    });
  });
}
