// 【BUG-164 (2026-09-12)】停止画面の「再試行」が、確認せずにフラグを下ろしていた。
//
// ## 起点
//
// dev 実機確認 2026-09-12（BUG-163 を直した直後）。
//
// ```
// admin で is_active を外す → アプリ操作 → 停止画面
//   → 再試行 → ⚠️ ホーム画面（プロフィールが出ず、習慣も読めない）
//   → 手で再読み込み → 停止画面
// ```
//
// 🔴 旧実装は**フラグを下ろして次の API 呼び出しの結果に判定を委ねていた**。
// ⚠️ **「壊れたホーム画面」を見せてから停止画面に戻る**ので、
// ユーザーにはアプリが壊れたように見える。
//
// 🔵 停止中かどうかは**サーバに聞けば分かる**のだから、**聞いてから下ろす**。

import 'dart:convert';

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

class _Adapter implements HttpClientAdapter {
  final List<String> requests = [];

  /// true のあいだ、認証を通る endpoint は 403 + 停止 code を返す。
  bool suspended = true;

  /// true にすると通信エラーを投げる（「確認できなかった」経路）。
  bool offline = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.path}');
    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline (test)',
      );
    }
    final headers = {
      'content-type': ['application/json'],
    };
    if (suspended) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {
            'code': 'auth_account_suspended',
            'message': 'このアカウントは停止されています',
          }
        }),
        403,
        headers: headers,
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'id': 1, 'name': 'テスト勇者', 'level': 3}),
      200,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

void _installSecureStorageMock(Map<String, String> seed) {
  final store = <String, String>{...seed};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async {
      switch (call.method) {
        case 'read':
          return store[(call.arguments as Map)['key'] as String];
        case 'write':
          final args = call.arguments as Map;
          store[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          store.remove((call.arguments as Map)['key']);
          return null;
        case 'readAll':
          return Map<String, String>.from(store);
        case 'deleteAll':
          store.clear();
          return null;
        default:
          return null;
      }
    },
  );
}

({Widget widget, ProviderContainer container, _Adapter adapter}) _build() {
  final adapter = _Adapter();
  final container = ProviderContainer(overrides: [
    apiClientProvider.overrideWith((ref) {
      final client = ApiClient(ref);
      client.dio.httpClientAdapter = adapter;
      return client;
    }),
  ]);
  // 停止中の状態から始める。
  container.read(accountSuspendedProvider.notifier).markSuspended();

  return (
    container: container,
    adapter: adapter,
    widget: UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
        home: const AccountSuspendedOverlay(
          child: Scaffold(body: Center(child: Text('通常 UI'))),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ApiClient.kSecureStorageInitializedKey: true,
    });
    _installSecureStorageMock({'hg_token': 'user_token'});
  });

  void useMobileViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> tapRetry(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('account_suspended_retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('🔴 1: まだ停止中なら、再試行しても通常 UI を見せない',
      (tester) async {
    final h = _build();
    addTearDown(h.container.dispose);
    useMobileViewport(tester);

    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    // 空振り検出: 停止画面が出ていること。
    expect(find.text('アカウントが停止されています'), findsOneWidget,
        reason: '前提が崩れている。停止画面が出ていない');

    await tapRetry(tester);

    // 🔴 旧実装はここで通常 UI を見せていた
    //    （プロフィールが出ず習慣も読めない「壊れたホーム」）。
    expect(h.container.read(accountSuspendedProvider), isTrue,
        reason: '確認せずにフラグを下ろしている。'
            '壊れたホーム画面を見せてから停止画面に戻ることになる');
    expect(find.text('アカウントが停止されています'), findsOneWidget,
        reason: '停止画面が消えている');
    // ⚠️ `find.text('通常 UI')` では判定できない。overlay は `Stack` で
    //    子を**常に tree に置いたまま**上に重ねるので、覆われていても
    //    見つかる。**停止画面が出ているかどうか**で判定する。

    // 🔴 【BUG-165】告知が**この画面の中に見えている**こと。
    //
    // ⚠️ 旧実装は `ToastCenter.showSabi()` を使っていたが、
    //    この overlay の根は**不透明な `Material`** で、SnackBar は
    //    **route 側の `Scaffold` の中**に描かれる ——
    //    **この画面の下に隠れて見えなかった**（実機確認 2026-09-12）。
    //
    // 🔵 `findsOneWidget` で「見えている」ことを縛れば、
    //    SnackBar に戻した実装では落ちる。
    expect(find.byKey(const Key('account_suspended_notice')), findsOneWidget,
        reason: '確認結果が画面に出ていない。'
            'SnackBar は不透明な overlay の下に隠れて見えない');
    expect(find.text('確認しました。まだこのアカウントはご利用いただけません 🪶'),
        findsOneWidget);
  });

  testWidgets('🔴 2: 再試行は実際にサーバへ聞く', (tester) async {
    final h = _build();
    addTearDown(h.container.dispose);
    useMobileViewport(tester);

    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();
    expect(h.adapter.requests, isEmpty, reason: '前提が崩れている');

    await tapRetry(tester);

    // 🔴 これが無いと「下ろさないだけ」の実装で 1 が緑になり、
    //    **解除されても戻れなくなる**（誤 ban の救済経路が消える）。
    expect(h.adapter.requests, isNotEmpty,
        reason: '再試行がサーバに何も聞いていない。'
            '解除を検知できないので、誤 ban を解除しても戻ってこられない');
    expect(h.adapter.requests.first, contains('/player/'),
        reason: '認証を通る endpoint でなければ停止は判定できない');
  });

  testWidgets('🔴 3: 解除されていれば通常 UI に戻る', (tester) async {
    final h = _build();
    addTearDown(h.container.dispose);
    useMobileViewport(tester);

    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    // admin が解除した状態。
    h.adapter.suspended = false;

    await tapRetry(tester);

    expect(h.container.read(accountSuspendedProvider), isFalse,
        reason: '解除されているのに停止画面から出られない。'
            '誤 ban を解除しても、その人は戻ってこない');
    // ⚠️ 「通常 UI が見つかる」は覆われていても成立するので、
    //    **停止画面が消えたこと**で判定する。
    expect(find.text('アカウントが停止されています'), findsNothing,
        reason: '停止画面が残っている');
  });

  testWidgets('⚠️ 4: 通信できなかったときは下ろさない', (tester) async {
    // 🔴 「解除されたか分からない」のに通常 UI に戻すと、
    //    **同じ壊れたホーム画面**になる。
    final h = _build();
    addTearDown(h.container.dispose);
    useMobileViewport(tester);

    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    h.adapter.offline = true;

    await tapRetry(tester);

    expect(h.container.read(accountSuspendedProvider), isTrue,
        reason: '状態が分からないのにフラグを下ろしている');
    expect(find.text('アカウントが停止されています'), findsOneWidget);

    // 🔴 「まだ停止中」と**別の文言**であること。
    //    ⚠️ 同じにすると、ユーザーが次に取る行動を誤らせる
    //    （問い合わせる / 通信を確かめて再試行する）。
    expect(find.byKey(const Key('account_suspended_notice')), findsOneWidget);
    expect(
      find.textContaining('確認できませんでした'), findsOneWidget,
      reason: '「確認できなかった」を「まだ停止中」と同じ文言にしている',
    );
  });

  testWidgets('⚠️ 5: 確認中は再試行を二重に押せない', (tester) async {
    final h = _build();
    addTearDown(h.container.dispose);
    useMobileViewport(tester);

    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('account_suspended_retry')));
    await tester.pump();
    // 1 本目が終わる前にもう一度押す。
    await tester.tap(
      find.byKey(const Key('account_suspended_retry')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(h.adapter.requests.length, 1,
        reason: '二重タップで 2 本飛んでいる');
  });
}
