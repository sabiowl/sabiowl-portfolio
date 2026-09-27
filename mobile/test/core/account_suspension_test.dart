// 【FEAT-541 (2026-09-06)】アカウント停止 overlay の契約テスト。
//
// ## 何を守っているか
//
// | # | 縛り | なぜ |
// |---|---|---|
// | A | 403 + `auth_account_suspended` で停止と判定する | 本 FEAT の中身 |
// | B | 🔴 **403 でも code が違えば判定しない** | 他の 403 と混ざる |
// | C | 🔴 **通信エラー / タイムアウト / 500 では判定しない** | 無実のユーザーに停止画面 |
// | D | 🔴 **ログアウトでフラグが下りる** | この機能で一番起きやすい詰み方 |
// | E | 再試行は**サーバに聞いてから**フラグを下ろす | 解除されたユーザーが戻ってこられる。⚠️ **聞かずに下ろすと「壊れたホーム画面」を見せてから停止画面に戻る** (BUG-164) |
// | F | overlay がフラグに追従して出入りする | |
// | G | 🔴 **フラグが端末に永続化されていない** | 解除後もアプリを消すまで残る |
//
// ## 🔴 C が「負の検証」である理由
//
// FEAT-483 / BootGate v1 は 5xx / timeout をメンテ扱いにして
// **「メンテしていないのにメンテ画面が出る」**を起こした。
// 同じ罠がここにもある —— **サーバーが明示的にそう言ったときだけ**信じる。
// 正の検証だけ書くと、`if (code == 403)` を `if (code >= 400)` に
// 広げても緑のまま通る。
//
// ## 🔴 D が専用テストである理由
//
// ログアウト時にフラグを消し忘れると、**ログイン画面の上に停止 overlay が
// 乗ったまま**になり、ログインボタンが押せなくなる。
// 「ログアウトできた」だけを見るテストでは捕まらない。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';  // ignore: unnecessary_import — ResponseBody の Uint8List

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/providers/account_suspension_provider.dart';
import 'package:sabiowl/core/widgets/account_suspended_overlay.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

const _kTokenKey = 'hg_token';

String _body(String code) => jsonEncode({
      'error': {'code': code, 'message': 'ダミー 🪶'},
    });

// ── secure storage の in-memory mock ─────────────────────────────────────
// ⚠️ mock しないと `MissingPluginException` が非同期に飛び、
//    全 suite 実行時だけ落ちる flaky になる。
class _FakeSecureStorage {
  final Map<String, String> values = {};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return key == null ? null : values[key];
          case 'write':
            if (key != null) values[key] = args['value'] as String? ?? '';
            return null;
          case 'delete':
            if (key != null) values.remove(key);
            return null;
          case 'readAll':
            return Map<String, String>.from(values);
          case 'deleteAll':
            values.clear();
            return null;
          case 'containsKey':
            return key != null && values.containsKey(key);
          default:
            return null;
        }
      },
    );
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  }
}

/// 指定の status / body を返すだけの adapter。
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter({required this.status, required this.body, this.throwsNetwork = false});

  final int status;
  final String body;
  final bool throwsNetwork;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (throwsNetwork) {
      throw DioException.connectionError(
        requestOptions: options, reason: 'no network',
      );
    }
    return ResponseBody.fromString(
      body, status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage storage;
  late ProviderContainer container;

  ApiClient build(_FixedAdapter adapter) {
    container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(apiClientProvider);
    c.dio.httpClientAdapter = adapter;
    return c;
  }

  Future<void> call(ApiClient client) async {
    try {
      await client.dio.get('/home/');
    } catch (_) {
      // エラーは上位に伝播する。ここで見たいのは provider の状態だけ。
    }
  }

  setUp(() {
    storage = _FakeSecureStorage();
    storage.install();
    // 通常ユーザーとしてログイン済の状態
    storage.values[_kTokenKey] = 'user-token';
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => storage.uninstall());

  // ── A: 停止と判定する ─────────────────────────────────────────────
  group('A: 403 + code で停止と判定する', () {
    test('403 + auth_account_suspended → フラグが立つ', () async {
      final client = build(_FixedAdapter(
        status: 403, body: _body(kAccountSuspendedErrorCode),
      ));
      await call(client);
      expect(container.read(accountSuspendedProvider), isTrue);
    });
  });

  // ── B / C: 負の検証 ───────────────────────────────────────────────
  group('B/C: サーバーが明示的に言ったときだけ信じる', () {
    test('🔴 403 でも code が違えばフラグは立たない', () async {
      final client = build(_FixedAdapter(
        status: 403, body: _body('some_other_permission_error'),
      ));
      await call(client);
      expect(
        container.read(accountSuspendedProvider), isFalse,
        reason: '403 という status だけをトリガにすると、権限まわりの'
            '別のエラーで停止画面が出る',
      );
    });

    test('🔴 code 無しの素の 403 でもフラグは立たない', () async {
      final client = build(_FixedAdapter(
        status: 403, body: jsonEncode({'detail': 'このアクションを実行する権限がありません。'}),
      ));
      await call(client);
      expect(container.read(accountSuspendedProvider), isFalse);
    });

    test('🔴 500 ではフラグは立たない', () async {
      final client = build(_FixedAdapter(
        status: 500, body: _body(kAccountSuspendedErrorCode),
      ));
      await call(client);
      expect(
        container.read(accountSuspendedProvider), isFalse,
        reason: 'code だけをトリガにすると、サーバー障害を停止と誤判定する',
      );
    });

    test('🔴 通信エラーではフラグは立たない', () async {
      final client = build(_FixedAdapter(
        status: 0, body: '', throwsNetwork: true,
      ));
      await call(client);
      expect(
        container.read(accountSuspendedProvider), isFalse,
        reason: '機内モードで停止画面が出ると、無実のユーザーを締め出す',
      );
    });

    test('🔴 401 ではフラグは立たない (旧挙動と混ざらない)', () async {
      // ⚠️ 通常ユーザートークンを外してから流す。付いたままだと 401 が
      //    `markSessionExpired()`（= 全 player-scoped provider の invalidate）
      //    に入り、**このテストで見たいものとは無関係な**セッション失効経路が
      //    走ってしまう。見たいのは「401 では停止フラグが立たない」だけである。
      storage.values.remove(_kTokenKey);
      final client = build(_FixedAdapter(
        status: 401, body: _body(kAccountSuspendedErrorCode),
      ));
      await call(client);
      expect(container.read(accountSuspendedProvider), isFalse);
    });
  });

  // ── D / E: フラグの下ろし方 ───────────────────────────────────────
  group('D/E: フラグを下ろす', () {
    test('🔴 clear() でフラグが下りる (ログアウト経路が呼ぶ)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(accountSuspendedProvider.notifier).markSuspended();
      expect(c.read(accountSuspendedProvider), isTrue);
      c.read(accountSuspendedProvider.notifier).clear();
      expect(
        c.read(accountSuspendedProvider), isFalse,
        reason: '消し忘れるとログイン画面の上に overlay が乗ったままになり、'
            'ログインボタンが押せなくなる',
      );
    });

    test('🔴 auth_provider の logout / markSessionExpired が clear を呼ぶ (走査)', () {
      // ⚠️ **`clear()` を直接呼ぶテストだけでは足りない。**
      //    それはリストがリスト自身と一致するのを確かめるのと同じで、
      //    **`logout()` から `clear()` の呼び出しを消しても緑のまま通る** ——
      //    実際に消して確かめたところ、`unused import` の warning でしか
      //    捕まらなかった (BUG-153 と同じ形)。
      //
      // 🔵 実経路 (`logout()` を本当に呼ぶ) は Firebase / sqflite /
      //    secure storage の後始末と非同期に競合してテストが不安定になるので、
      //    **出口が 2 つとも clear を持っていること**を走査で縛り、
      //    overlay 側のボタン経路は下の widget test で実際に踏む。
      final source = File(
        'lib/features/auth/providers/auth_provider.dart',
      ).readAsStringSync();
      for (final method in ['Future<void> logout()', 'void markSessionExpired()']) {
        final at = source.indexOf(method);
        expect(at, greaterThan(0), reason: '$method が見つからない');
        // メソッドの終端 = 列 2 の閉じ波括弧。
        final end = source.indexOf('${'\n'}  }', at);
        expect(end, greaterThan(at), reason: '$method の終端が見つからない');
        final body = source.substring(at, end);
        expect(
          body.contains('accountSuspendedProvider.notifier).clear()'), isTrue,
          reason: '$method が停止フラグを下ろしていない = '
              'ログイン画面の上に overlay が乗ったままになる',
        );
      }
    });

    test('markSuspended は冪等 (何度呼んでも true のまま)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(accountSuspendedProvider.notifier)
        ..markSuspended()
        ..markSuspended();
      expect(c.read(accountSuspendedProvider), isTrue);
      notifier.clear();
      expect(c.read(accountSuspendedProvider), isFalse);
    });
  });

  // ── G: 永続化していない ───────────────────────────────────────────
  group('G: 端末に永続化しない', () {
    test('🔴 新しい container では false から始まる (再起動相当)', () async {
      final client = build(_FixedAdapter(
        status: 403, body: _body(kAccountSuspendedErrorCode),
      ));
      await call(client);
      expect(container.read(accountSuspendedProvider), isTrue);

      // 再起動相当: 新しい ProviderContainer
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(
        fresh.read(accountSuspendedProvider), isFalse,
        reason: '永続化すると、解除してもアプリを消すまで画面が残る',
      );
    });

    test('SharedPreferences に何も書いていない', () async {
      final client = build(_FixedAdapter(
        status: 403, body: _body(kAccountSuspendedErrorCode),
      ));
      await call(client);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((k) => k.toLowerCase().contains('suspend')),
        isEmpty,
      );
    });
  });

  // ── F: overlay の出入り ───────────────────────────────────────────
  group('F: overlay がフラグに追従する', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          locale: Locale('ja'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AccountSuspendedOverlay(
            child: Scaffold(body: Text('通常 UI')),
          ),
        ),
      ));
      await tester.pump();
      return c;
    }

    testWidgets('フラグが false なら通常 UI だけ', (tester) async {
      await pump(tester);
      expect(find.text('通常 UI'), findsOneWidget);
      expect(find.text('アカウントが停止されています'), findsNothing);
    });

    testWidgets('フラグが true になると overlay が出る', (tester) async {
      final c = await pump(tester);
      c.read(accountSuspendedProvider.notifier).markSuspended();
      await tester.pump();
      expect(find.text('アカウントが停止されています'), findsOneWidget);
      // ⚠️ 停止理由は出さない
      expect(find.textContaining('理由'), findsNothing);
    });

    testWidgets('🔴 【BUG-164】再試行は確認できるまでフラグを下ろさない',
        (tester) async {
      // ⚠️ **旧実装はここで即 `clear()` していた。**
      //    下ろした瞬間に通常 UI が描画され、403 を受けるまで
      //    **プロフィールも習慣も無いホーム画面**が見えていた
      //    (dev 実機確認 2026-09-12)。
      //
      // 🔵 解除されたときに戻れることは
      //    `test/core/account_suspended_retry_test.dart` が
      //    **サーバ応答を差し替えて**縛っている。
      //    ここは「**下ろさない**」側だけを見る
      //    (この group は provider を差し替えていないので
      //     実際の通信はできない = 確認に失敗する経路になる)。
      final c = await pump(tester);
      c.read(accountSuspendedProvider.notifier).markSuspended();
      await tester.pump();

      await tester.tap(find.byKey(const Key('account_suspended_retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        c.read(accountSuspendedProvider), isTrue,
        reason: '確認せずにフラグを下ろしている。'
            '壊れたホーム画面を見せてから停止画面に戻ることになる (BUG-164)',
      );
      expect(find.text('アカウントが停止されています'), findsOneWidget);
    });

    testWidgets('主動作 (再試行) がログアウトより上に並ぶ', (tester) async {
      final c = await pump(tester);
      c.read(accountSuspendedProvider.notifier).markSuspended();
      await tester.pump();
      final retryY = tester.getTopLeft(
        find.byKey(const Key('account_suspended_retry')),
      ).dy;
      final logoutY = tester.getTopLeft(
        find.byKey(const Key('account_suspended_logout')),
      ).dy;
      expect(
        retryY, lessThan(logoutY),
        reason: '主動作 (復帰を試す) が先、退出は最後',
      );
    });
  });
}
