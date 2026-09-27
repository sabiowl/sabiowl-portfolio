import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/analytics/sentry_breadcrumb_interceptor.dart';
import 'package:sabiowl/core/analytics/sentry_breadcrumb_scrubber.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 【BUG-160 (2026-09-12)】HTTP breadcrumb を**安全に**有効化する。
///
/// 🔴 **本 BUG は「有効化」ではなく「安全に有効化」が主題である。**
/// 素のまま入れると `friends/<int:player_id>/profile/` の
/// `PlayerProfile.id` と `friend_id` が Sentry に入り、
/// プライバシーポリシーが名指しで削除を約束しているものが送られる。
///
/// ## 🔴 1 と 3 は対で書く
///
/// 「42 を含まない」だけを書くと **URL を丸ごと捨てる実装**で緑になり、
/// 本 BUG の目的 (どのエンドポイントで何が起きたか) が達成されない。
///
/// ## 🔴 2 は単独で書く
///
/// `friend_id` の値は**数値ではない**ので、パスの数値規則では捕まらない。
/// **規則を 1 本書いて満足すると、必ずここが漏れる。**

// ── 応答を差し替える fake adapter ────────────────────────────────────────────

class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status, {this.body = '{"ok":true}'});
  final int status;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 収集した breadcrumb を `beforeBreadcrumb` 相当で通してから溜める。
///
/// ⚠️ 実 Sentry hub を起動せず、**本番と同じ順序**
/// (interceptor が積む → フックが伏せる) を再現する。
class _BreadcrumbSink {
  final List<Breadcrumb> raw = [];
  final List<Breadcrumb> scrubbed = [];

  void add(Breadcrumb crumb) {
    raw.add(crumb);
    final out = scrubHttpBreadcrumb(crumb, Hint());
    if (out != null) scrubbed.add(out);
  }

  Breadcrumb get only {
    expect(scrubbed, hasLength(1),
        reason: 'HTTP breadcrumb が 1 件だけ積まれるはず');
    return scrubbed.single;
  }

  String get url => only.data!['url'] as String;
}

Dio _dioWith(_BreadcrumbSink sink, HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://sabiowl-backend.example/api',
    validateStatus: (_) => true,
  ))..httpClientAdapter = adapter;
  dio.interceptors.add(SentryBreadcrumbInterceptor(addBreadcrumb: sink.add));
  return dio;
}

void main() {
  group('BUG-160 §3-1/2/3 URL の伏せ字', () {
    test('🔴 1: パスの数値セグメントが残らない', () {
      expect(
        scrubBreadcrumbUrl('https://x.example/api/friends/42/profile/'),
        isNot(contains('42')),
        reason: 'PlayerProfile.id がそのまま Sentry に入る。'
            'プライバシーポリシーが削除を名指しで約束しているものである',
      );
    });

    test('🔵 3: 伏せてもエンドポイントは識別できる', () {
      // 🔴 1 と対。URL を丸ごと捨てる実装だとここが落ちる。
      expect(
        scrubBreadcrumbUrl('https://x.example/api/friends/42/profile/'),
        'https://x.example/api/friends/{id}/profile/',
      );
      expect(
        scrubBreadcrumbUrl('https://x.example/api/habits/17/count/'),
        'https://x.example/api/habits/{id}/count/',
      );
    });

    test('🔴 2: friend_id の値が残らない（数値規則では捕まらない）', () {
      final out = scrubBreadcrumbUrl(
          'https://x.example/api/friends/?friend_id=ABC123');
      expect(out, isNot(contains('ABC123')),
          reason: 'friend_id は公開コードだが per-user の識別子である。'
              '値が数値でないのでパスの規則では捕まらない');
      expect(out, contains('friend_id'),
          reason: 'キー名まで消すと、何を叩いたのかが分からなくなる');
    });

    test('無害と実測したクエリは値を残す', () {
      final out = scrubBreadcrumbUrl(
          'https://x.example/api/gacha/?tier=daily&limit=20');
      expect(out, contains('tier=daily'));
      expect(out, contains('limit=20'));
    });

    test('⚠️ 許可していないクエリ名は既定で伏せる', () {
      // 🔴 拒否リストにすると、あとで追加されたものが既定で漏れる。
      //    許可制なら、失敗したときに安全側へ倒れる。
      final out = scrubBreadcrumbUrl(
          'https://x.example/api/whatever/?some_future_key=secret-value');
      expect(out, isNot(contains('secret-value')));
      expect(out, contains('{redacted}'));
    });

    test('末尾スラッシュとクエリ無しの URL が壊れない', () {
      expect(
        scrubBreadcrumbUrl('https://x.example/api/health/'),
        'https://x.example/api/health/',
      );
    });

    test('壊れた URL でも例外にしない', () {
      expect(scrubBreadcrumbUrl('::::'), isNotNull);
    });
  });

  group('BUG-160 §3-4/5 interceptor が積むもの', () {
    test('🔴 4: status code が入る（429 が並ぶことが見える）', () async {
      final sink = _BreadcrumbSink();
      await _dioWith(sink, _StatusAdapter(429)).get('/gacha/pull/');

      expect(sink.only.data!['status_code'], 429,
          reason: '本 BUG の目的そのもの。'
              '429 が 1 本だけか全 API に出ているかを breadcrumb で見たい');
      expect(sink.only.data!['method'], 'GET');
      expect(sink.only.type, 'http');
    });

    test('エラー応答でも breadcrumb が積まれる', () async {
      final sink = _BreadcrumbSink();
      final dio = _dioWith(sink, _StatusAdapter(500));
      dio.options.validateStatus = (code) => code != null && code < 400;
      try {
        await dio.get('/player/');
      } catch (_) {
        // DioException は握る。breadcrumb が積まれたかだけを見る。
      }
      expect(sink.only.data!['status_code'], 500,
          reason: '落ちたときの 1 本が残らないと、調査で一番見たいものが無い');
    });

    test('🔴 5: request / response body が入らない', () async {
      final sink = _BreadcrumbSink();
      await _dioWith(
        sink,
        _StatusAdapter(200, body: '{"name":"朝のストレッチ"}'),
      ).post('/habits/', data: {'name': '夜の読書', 'memo': '個人的なメモ'});

      final dump = sink.only.data.toString();
      expect(dump, isNot(contains('夜の読書')),
          reason: '習慣名がそのまま Sentry に入る。'
              'breadcrumb は beforeSend の対象外なので消えない');
      expect(dump, isNot(contains('個人的なメモ')));
      expect(dump, isNot(contains('朝のストレッチ')),
          reason: 'response body も同じ理由で入れてはならない');
    });

    test('🔴 ヘッダーが入らない（Authorization が漏れる）', () async {
      final sink = _BreadcrumbSink();
      final dio = _dioWith(sink, _StatusAdapter(200));
      dio.options.headers['Authorization'] = 'Token super-secret';
      await dio.get('/player/');

      final dump = sink.only.data.toString();
      expect(dump, isNot(contains('super-secret')));
      expect(dump.toLowerCase(), isNot(contains('authorization')));
    });

    test('🔴 interceptor が積んだ生 URL がフックで伏せられる', () async {
      final sink = _BreadcrumbSink();
      await _dioWith(sink, _StatusAdapter(200))
          .get('/friends/42/profile/', queryParameters: {'friend_id': 'ABC123'});

      // 空振り検出: そもそも 1 件積まれていること。
      expect(sink.raw, hasLength(1), reason: 'interceptor が breadcrumb を積んでいない');
      expect(sink.url, isNot(contains('42')));
      expect(sink.url, isNot(contains('ABC123')));
      expect(sink.url, contains('/friends/{id}/profile/'),
          reason: '伏せる目的は行を隠すことであって、'
              'エンドポイントを隠すことではない');
    });
  });

  group('BUG-160 §3-6 BUG-159 の方針を壊していないこと', () {
    test('🔴 beforeSend の user: null が維持されている', () {
      final source = _readSource('lib/main.dart');
      expect(source, contains('beforeSend'),
          reason: '走査が壊れている (beforeSend が見つからない)');
      expect(source, contains('user: null'),
          reason: 'イベント本体から user を落とす方針 (BUG-159 §1) が外れている。'
              'プライバシーポリシーが名指しで約束している');
    });

    test('⚠️ breadcrumb の伏せ字は beforeBreadcrumb 側で行う', () {
      final source = _readSource('lib/main.dart');
      expect(source, contains('beforeBreadcrumb'),
          reason: 'フックが登録されていない = 生の URL がそのまま送られる');
      expect(source, contains('scrubHttpBreadcrumb'));
      // 🔴 beforeSend 側でまとめて触る形にすると、
      //    breadcrumb の種類が増えるたびに漏れる。
      final beforeSendLine = source
          .split('\n')
          .firstWhere((l) => l.contains('options.beforeSend'), orElse: () => '');
      expect(beforeSendLine, isNot(contains('readcrumb')),
          reason: 'beforeSend で breadcrumb を触っている。'
              '1 件ずつ通る beforeBreadcrumb で処理すること');
    });

    test('interceptor が ApiClient に登録されている', () {
      final source = _readSource('lib/core/api/api_client.dart');
      expect(source, contains('SentryBreadcrumbInterceptor'),
          reason: '登録されていないと breadcrumb が 1 本も積まれない');
    });
  });
}

/// 走査対象を読む。テストの作業ディレクトリは `mobile/`。
String _readSource(String relativePath) {
  final f = File(relativePath);
  if (!f.existsSync()) {
    throw StateError('走査対象が見つからない: $relativePath');
  }
  return f.readAsStringSync();
}
