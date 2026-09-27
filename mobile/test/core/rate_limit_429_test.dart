import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/providers/connection_error_provider.dart';
import 'package:sabiowl/core/providers/maintenance_provider.dart';
import 'package:sabiowl/core/providers/rate_limit_provider.dart';
import 'package:sabiowl/core/services/maintenance_service.dart';
import 'package:sabiowl/core/widgets/boot_gate.dart';
import 'package:sabiowl/core/widgets/rate_limit_overlay.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

/// 【BUG-158 (2026-09-12)】429 を「通信できませんでした」にしない。
///
/// ## 本 BUG の中心
///
/// 🔴 `boot_gate.dart` は 200 以外をまとめて degraded 扱いにしていたため、
/// **429 も ConnectionErrorOverlay に落ちていた**。表示は
/// 「通信できませんでした」だが、Sentry breadcrumb は
/// `network_type: wifi` / `signal_strength: -51` —— **通信は良好だった**。
///
/// ⚠️ さらにあの画面の「再試行」は `/health/` を叩く。
/// **枠を使い切って出た画面が、押すたびに枠をもう 1 本消費していた。**
///
/// ## 🔴 6 と 9 は対で書く
///
/// 「429 で overlay が出ない」だけを書くと、**429 を全部無視する実装**でも
/// 緑になる。その実装は 5xx でも overlay を出さなくなる退行を含む。
/// 5xx / network error の既存挙動を同じファイルで縛る。

// ── Fake adapters ────────────────────────────────────────────────────────────

/// 429 + `Retry-After` を返す。
class _ThrottledAdapter implements HttpClientAdapter {
  _ThrottledAdapter({this.retryAfter = '42'});

  /// null なら `Retry-After` ヘッダ自体を付けない。
  final String? retryAfter;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      '{"detail":"Request was throttled."}',
      429,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        if (retryAfter != null) 'retry-after': [retryAfter!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 503 を返す (既存の Case C)。
class _DegradedAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      '{"status":"degraded"}',
      503,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// ネットワークエラー (既存の Case D)。
class _NetworkErrorAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MaintenanceOff extends MaintenanceService {
  _MaintenanceOff() : super(Dio());
  @override
  Future<MaintenanceStatus> fetchStatus() async => MaintenanceStatus.off;
}

/// 【BUG-147 Phase C の教訓】`probeDio` も override しないと、fake が一度も
/// 呼ばれないまま「ネットワーク失敗 → degraded」で偶然緑になる。
class _FakeApiClient extends ApiClient {
  _FakeApiClient(super.ref, this._testDio);
  final Dio _testDio;

  @override
  Dio get dio => _testDio;

  @override
  Dio get probeDio => _testDio;
}

Widget _bootGateWith(HttpClientAdapter adapter) {
  final fakeDio = Dio(
    BaseOptions(baseUrl: 'https://test.example', validateStatus: (_) => true),
  )..httpClientAdapter = adapter;

  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWith((ref) => _FakeApiClient(ref, fakeDio)),
      maintenanceServiceProvider.overrideWith((_) => _MaintenanceOff()),
    ],
    child: const MaterialApp(home: BootGate(child: Text('child_widget'))),
  );
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.text('child_widget')));

void main() {
  group('BUG-158 §5-6/7/9 BootGate の 429 分岐', () {
    testWidgets('🔴 429 では ConnectionErrorOverlay を発火しない', (tester) async {
      final adapter = _ThrottledAdapter();
      await tester.pumpWidget(_bootGateWith(adapter));
      await tester.pumpAndSettle();

      // 空振り検出。fake に届いていなければ以降の assert は無意味。
      expect(adapter.calls, greaterThan(0),
          reason: 'health probe が fake adapter に届いていない');

      final container = _containerOf(tester);
      expect(
        container.read(connectionErrorProvider).hasError,
        isFalse,
        reason: '429 で「通信できませんでした」が出ている。'
            'サーバは応答しているので事実と逆である',
      );
      expect(container.read(rateLimitProvider).isLimited, isTrue,
          reason: '429 なのにレート制限として扱われていない');
    });

    testWidgets('🔴 429 の待ち時間は Retry-After から読む', (tester) async {
      await tester.pumpWidget(_bootGateWith(_ThrottledAdapter(retryAfter: '42')));
      await tester.pumpAndSettle();

      final status = _containerOf(tester).read(rateLimitProvider);
      final remaining = status.remaining(DateTime.now());
      // 42 秒を読めていれば 40〜42 秒台に入る。既定値 (60) と明確に区別できる。
      expect(remaining.inSeconds, inInclusiveRange(38, 42),
          reason: 'Retry-After: 42 を読んでいない '
              '(既定値に落ちていると 60 前後になる)');
    });

    testWidgets('Retry-After が無い 429 でも有限の待ち時間になる', (tester) async {
      await tester.pumpWidget(_bootGateWith(_ThrottledAdapter(retryAfter: null)));
      await tester.pumpAndSettle();

      final status = _containerOf(tester).read(rateLimitProvider);
      expect(status.isLimited, isTrue);
      expect(status.remaining(DateTime.now()) > Duration.zero, isTrue,
          reason: 'ヘッダが無いときに待ち時間が 0 だと、'
              '押しても何も起きないボタンが即座に有効になる');
    });

    testWidgets('🔴 回帰: 503 は従来どおり ConnectionErrorOverlay', (tester) async {
      final adapter = _DegradedAdapter();
      await tester.pumpWidget(_bootGateWith(adapter));
      await tester.pumpAndSettle();

      expect(adapter.calls, greaterThan(0));
      final container = _containerOf(tester);
      expect(container.read(connectionErrorProvider).hasError, isTrue,
          reason: '429 を特別扱いした副作用で 5xx の検知まで落ちている');
      expect(container.read(rateLimitProvider).isLimited, isFalse,
          reason: '5xx をレート制限として扱ってはいけない');
    });

    testWidgets('🔴 回帰: ネットワークエラーは従来どおり ConnectionErrorOverlay',
        (tester) async {
      await tester.pumpWidget(_bootGateWith(_NetworkErrorAdapter()));
      await tester.pumpAndSettle();

      final container = _containerOf(tester);
      expect(container.read(connectionErrorProvider).hasError, isTrue);
      expect(container.read(rateLimitProvider).isLimited, isFalse,
          reason: '到達していない通信をレート制限として扱ってはいけない');
    });
  });

  group('BUG-158 §4-3 Retry-After の解釈', () {
    test('秒数をそのまま読む', () {
      expect(parseRetryAfter('42'), const Duration(seconds: 42));
    });

    test('欠落 / 空 / 読めない値は既定の待ち時間に落ちる', () {
      expect(parseRetryAfter(null), kDefaultRetryAfter);
      expect(parseRetryAfter(''), kDefaultRetryAfter);
      // ⚠️ RFC 的には HTTP-date も許されるが DRF は常に秒数を送る。
      //    読まずに既定へ落として「必ず有限」を優先する。
      expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), kDefaultRetryAfter);
      expect(parseRetryAfter('0'), kDefaultRetryAfter);
      expect(parseRetryAfter('-5'), kDefaultRetryAfter);
    });

    test('⚠️ 長すぎる待ち時間は頭打ちにする', () {
      // anon / user は 1 時間窓なので Retry-After は 3600 になりうる。
      // 1 時間のカウントダウンを見せても意味がない。
      expect(parseRetryAfter('3600'), kMaxRetryAfter);
    });
  });

  group('BUG-158 §4-4 待っているあいだ再試行を押させない', () {
    Widget overlayWith(ProviderContainer container) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            // 文言を assert するので locale を固定する。
            // 既定だとテスト環境の en に解決される。
            locale: const Locale('ja'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const RateLimitOverlay(child: Text('child_widget')),
          ),
        );

    testWidgets('🔴 待ち時間が残っているあいだ再試行ボタンは無効', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(rateLimitProvider.notifier)
          .mark(const Duration(seconds: 30));

      await tester.pumpWidget(overlayWith(container));
      await tester.pump();

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull,
          reason: '押せてしまうと、枠を 1 本消費して同じ 429 が返るだけになる。'
              'BUG-147 Phase C が 401 で解いたのと同じ形の再発である');

      // カウントダウンの Timer を消化してからテストを終える。
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('待ち時間が明けたら再試行ボタンが有効になる', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 既に過ぎている期限を入れる = 待ち時間ゼロ
      container
          .read(rateLimitProvider.notifier)
          .mark(const Duration(seconds: -1));

      await tester.pumpWidget(overlayWith(container));
      await tester.pump();

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull,
          reason: '待ちが明けたのに押せないと、ユーザーに打つ手が無くなる');

      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('🔴 429 の画面に「通信できませんでした」は出ない', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(rateLimitProvider.notifier)
          .mark(const Duration(seconds: 30));

      await tester.pumpWidget(overlayWith(container));
      await tester.pump();

      final l10n = await AppLocalizations.delegate.load(const Locale('ja'));
      expect(find.text(l10n.coreErrorOverlayTitle), findsNothing,
          reason: '通信は生きているので「通信できませんでした」は嘘になる');
      expect(find.text(l10n.coreRateLimitTitle), findsOneWidget);
      // ⚠️ 待ち時間こそが最も有用な情報である。
      //
      // ⚠️ 秒数を直値で比較しない —— `mark()` から描画までに実時間が進むので
      //    30 が 29 になる。**桁を取り出して範囲で見る。**
      final countdown = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .firstWhere((t) => t.contains('秒'), orElse: () => '');
      expect(countdown, isNotEmpty,
          reason: 'Retry-After 由来の待ち時間が画面に出ていない');
      final digits =
          countdown.split('').where((c) => '0123456789'.contains(c)).join();
      expect(int.parse(digits), inInclusiveRange(28, 30),
          reason: '表示している待ち時間が Retry-After と一致していない');

      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('制限されていないときは overlay を出さない', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(overlayWith(container));
      await tester.pump();

      expect(find.text('child_widget'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
    });

    testWidgets('メンテナンス中は RateLimitOverlay を出さない', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(rateLimitProvider.notifier)
          .mark(const Duration(seconds: 30));
      container.read(maintenanceStatusProvider.notifier).setStatusForBoot(
            MaintenanceStatus(
              isEnabled: true,
              title: 'メンテ中',
              body: '少々お待ちください 🪶',
              expiresAt: null,
            ),
          );

      await tester.pumpWidget(overlayWith(container));
      await tester.pump();

      expect(find.byType(ElevatedButton), findsNothing,
          reason: 'メンテ告知 (admin の明示的な意思) が上位。二重表示しない');
    });
  });

  group('BUG-158 レート制限の解除', () {
    test('業務 API の 2xx で解除される経路が残っていること', () {
      // ⚠️ 実 `ApiClient` は secure storage / Hive を要求するので pump できない。
      //    代わりに**解除の呼び出しが 2xx の経路に書かれていること**を走査で縛る。
      //    🔵 これが無いと、anon バケットだけ枯れていて業務 API は通っている
      //    ユーザーの画面が、動いているのに塞がれたままになる。
      final source = _readSource('lib/core/api/api_client.dart');
      final body = _functionBody(source, 'void _reset5xxCounter()');
      expect(body, isNotEmpty, reason: '_reset5xxCounter が見つからない = 走査が壊れている');
      expect(body, contains('rateLimitProvider'),
          reason: '2xx で rateLimitProvider を clear していない');
      expect(body, contains('connectionErrorProvider'),
          reason: '既存の connection error 解除まで落ちている');
    });

    test('ConnectionErrorOverlay の再試行が 429 を握り潰さないこと', () {
      final source = _readSource('lib/core/widgets/connection_error_overlay.dart');
      expect(source, contains('429'),
          reason: '再試行が 429 を素通りさせている。'
              '押すたびに枠を 1 本消費して同じ画面に戻る');
      expect(source, contains('rateLimitProvider'),
          reason: '429 をレート制限画面に引き渡していない');
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

/// `signature` で始まる関数の本体 (最初の `{` から対応する `}` まで) を返す。
String _functionBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  var depth = 0;
  var i = source.indexOf('{', start);
  if (i < 0) return '';
  final open = i;
  for (; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return '';
}
