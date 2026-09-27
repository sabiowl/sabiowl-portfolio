// 【BUG-147 Phase B-2 / C (2026-08-20)】無効なゲストトークンからの回復の契約テスト。
//
// ## 何を守っているか
//
// 端末に**サーバがもう知らないゲストトークン**が残ると全 API が 401 になり、
// アプリ内に脱出経路が無かった。Phase B-1 で backend が
// `auth_guest_token_invalid` を返すようになったので、「恒久的に無効」と
// 「一時的な 401」を判別してセッションを作り直せる。
//
// 🔴 **判別を外した瞬間、FEAT-193 が防いだ事故に戻る** ——
// 一時的な 401 でゲストトークンを破棄し、端末初期化と同等のデータロスを
// 起こした事故。だから「素の 401 では触らない」側のテストが本体である。
//
// ## ガード 3 点 (指示書 §4)
//
//   1. リクエスト単位の再試行フラグ … 再送も 401 なら無限ループ (Pre-mortem 3-c)
//   2. `guest-init` の直列化        … 起動時は 10 本以上が同時に 401 になる
//   3. `guest-init` 失敗は握り潰す  … 失敗時に再帰させない
//
// ガード 2 が無いと **1 回の起動で throttle (5/hour、IP 単位) を使い切る**。
// 以後 1 時間、正規の新規ユーザーもゲスト開始できない (Pre-mortem 3-b)。
import 'dart:convert';
import 'dart:typed_data';  // ignore: unnecessary_import — ResponseBody の Uint8List

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/api/api_client.dart';

const _kGuestTokenKey = 'hg_guest_token';

/// 無効ゲストトークンの 401 body (Phase B-1 の backend が返す形)。
final _invalidGuestBody = jsonEncode({
  'error': {
    'code': 'auth_guest_token_invalid',
    'message': 'ゲストセッションの有効期限が切れました。再度お試しください 🪶',
  },
});

/// DRF 既定の 401 body。`ApiError.fromResponse` は code='unknown' に落とす。
final _plainUnauthorizedBody = jsonEncode({'detail': '認証情報が含まれていません。'});

/// 別 code の 401 (形式不正)。**再初期化してはいけない側**。
final _malformedBody = jsonEncode({
  'error': {
    'code': 'auth_guest_token_malformed',
    'message': 'ゲストセッションの情報が読み取れませんでした 🪶',
  },
});

// ── secure storage の in-memory mock ─────────────────────────────────────
//
// ApiClient は `FlutterSecureStorage` を直接持つので、MethodChannel を
// map で差し替える。**ここを mock しないと MissingPluginException が
// 非同期に飛び、全 suite 実行時だけ落ちる flaky になる**
// (world_frame_mini_battle_test の前例)。
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

// ── 台本付き HttpClientAdapter ───────────────────────────────────────────

/// 業務 API と `guest-init` を出し分ける fake adapter。
///
/// 観測できるもの:
///   * `guestInitCount`     … `guest-init` が実際に走った回数 (ガード 2 の判定)
///   * `businessCallCount`  … 業務 API が何回叩かれたか (再送の回数)
///   * `authHeaders`        … 各リクエストが送った Authorization ヘッダ
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter({
    required this.unauthorizedBody,
    this.failForever = false,
    this.guestInitFails = false,
  });

  /// パスに `slow` を含むリクエストだけ、**401 を返すのを遅らせる**。
  ///
  /// 「再作成が終わった後に 401 が返ってくる」= mutex に捕まらない経路
  /// (ガード 2b) を決定論的に再現するために使う。
  static const Duration slowUnauthorizedDelay = Duration(milliseconds: 120);

  /// 業務 API が最初に返す 401 の body。
  final String unauthorizedBody;

  /// true なら**再送も 401**にする (ガード 1 の検証)。
  final bool failForever;

  /// true なら `guest-init` が 500 を返す (ガード 3 の検証)。
  final bool guestInitFails;

  /// `guest-init` の応答遅延。**同時 401 が出揃う窓**を作るために少しだけ待つ。
  /// 0 にすると、10 本のうち先頭 1 本が mutex を掴む前に完了してしまい、
  /// ガード 2 のテストが「たまたま 1 回だった」に化ける可能性がある。
  static const Duration guestInitDelay = Duration(milliseconds: 20);

  int guestInitCount = 0;
  int businessCallCount = 0;
  final List<String?> authHeaders = [];
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    authHeaders.add(options.headers['Authorization'] as String?);

    if (options.path.contains('guest-init')) {
      guestInitCount++;
      await Future<void>.delayed(guestInitDelay);
      if (guestInitFails) {
        return ResponseBody.fromString('{"detail":"boom"}', 500,
            headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
      }
      return ResponseBody.fromString(
        '{"token":"fresh-guest-token","player_profile":{"id":42,"name":"ゲスト"}}',
        200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
      );
    }

    businessCallCount++;
    final isRetry = options.extra[ApiClient.kRetriedExtraKey] == true;
    if (isRetry && !failForever) {
      return ResponseBody.fromString('{"ok":true}', 200,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
    }
    if (options.path.contains('slow')) {
      // 401 が返るのを遅らせ、先行リクエストの再作成が終わった後に着地させる。
      await Future<void>.delayed(slowUnauthorizedDelay);
    }
    return ResponseBody.fromString(unauthorizedBody, 401,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage storage;
  late ProviderContainer container;
  late ApiClient client;

  ApiClient build(_ScriptedAdapter adapter) {
    container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(apiClientProvider);
    c.dio.httpClientAdapter = adapter;
    return c;
  }

  setUp(() {
    storage = _FakeSecureStorage();
    storage.install();
    // 「サーバがもう知らない」ゲストトークンが端末に残っている状態
    storage.values[_kGuestTokenKey] = 'stale-guest-token';
  });

  tearDown(() => storage.uninstall());

  // ── 回復する側 ─────────────────────────────────────────────────────

  test('A: auth_guest_token_invalid なら guest-init を 1 回だけ呼んで再送する',
      () async {
    final adapter = _ScriptedAdapter(unauthorizedBody: _invalidGuestBody);
    client = build(adapter);

    final res = await client.dio.get('/home/');

    expect(res.statusCode, 200, reason: '再送の結果が呼び出し元に返ること');
    expect(adapter.guestInitCount, 1, reason: 'guest-init は 1 回だけ');
    expect(adapter.businessCallCount, 2, reason: '最初の 401 と再送の 2 回');
    expect(storage.values[_kGuestTokenKey], 'fresh-guest-token',
        reason: '新しいトークンが保存されていること');
  });

  test('A2: 再送は新しいゲストトークンを載せる', () async {
    final adapter = _ScriptedAdapter(unauthorizedBody: _invalidGuestBody);
    client = build(adapter);

    await client.dio.get('/home/');

    final businessAuth = [
      for (var i = 0; i < adapter.paths.length; i++)
        if (!adapter.paths[i].contains('guest-init')) adapter.authHeaders[i],
    ];
    expect(businessAuth.first, 'GuestToken stale-guest-token');
    expect(businessAuth.last, 'GuestToken fresh-guest-token',
        reason: '再送で古いトークンを送り直したら永久に 401 のまま');
  });

  // ── ガード 2: throttle を枯渇させない (Pre-mortem 3-b) ───────────────

  test('B: 同時に 10 本 401 になっても guest-init は 1 回 (throttle 5/hour)',
      () async {
    final adapter = _ScriptedAdapter(unauthorizedBody: _invalidGuestBody);
    client = build(adapter);

    final results = await Future.wait([
      for (var i = 0; i < 10; i++) client.dio.get('/home/$i/'),
    ]);

    expect(results.every((r) => r.statusCode == 200), isTrue);
    expect(
      adapter.guestInitCount, 1,
      reason: '起動時の同時 401 で guest-init が複数走ると、1 回の起動で '
          'throttle (5/hour、IP 単位) を使い切り、正規の新規ユーザーも '
          'ゲスト開始できなくなる',
    );
  });

  test('B2: 再作成の完了後に 401 が着地しても guest-init は増えない', () async {
    // mutex (ガード 2) は「同時に 401 になった分」しか束ねられない。
    // `_reinitGuestSession` は finally で mutex を null に戻すので、**再作成が
    // 終わった後に 401 が返ってきたリクエスト**は素通りして 2 回目の
    // guest-init を起こす —— これがガード 2b で塞ぐ穴である。
    //
    // 起動直後は全リクエストが同時に飛ぶわけではない。実機ログ (2026-08-20) では
    // /api/challenges/ が他より 1 秒遅れて発火しており、この条件は実際に成立する。
    //
    // 害は throttle (5/hour、IP 単位) の余計な消費と、**孤児のゲストセッション**
    // (再作成のたびに空の PlayerProfile が 1 つ増える)。
    final adapter = _ScriptedAdapter(unauthorizedBody: _invalidGuestBody);
    client = build(adapter);

    // 両方 t=0 に発射。/home/ は即 401 → 再作成 (20ms) が先に完了する。
    // /slow/ は古いトークンを載せたまま飛び、120ms 後に 401 で着地する。
    final results = await Future.wait([
      client.dio.get('/home/'),
      client.dio.get('/slow/'),
    ]);

    expect(results.every((r) => r.statusCode == 200), isTrue,
        reason: '遅れて 401 になった側も、再送されて成功すること');
    expect(
      adapter.guestInitCount, 1,
      reason: '再作成後に着地した 401 で 2 回目の guest-init を起こしてはいけない。'
          '古いトークンで飛んだリクエストが戻ってきただけで、'
          'セッションは既に作り直されている',
    );
    expect(storage.values[_kGuestTokenKey], 'fresh-guest-token',
        reason: '2 回目の再作成が走ると別のトークンに上書きされてしまう');
  });

  // ── ガード 1: 無限ループ防止 (Pre-mortem 3-c) ───────────────────────

  test('C: 再送も 401 なら 2 回目の再試行をしない', () async {
    final adapter = _ScriptedAdapter(
      unauthorizedBody: _invalidGuestBody, failForever: true);
    client = build(adapter);

    await expectLater(
      client.dio.get('/home/'),
      throwsA(isA<DioException>()),
      reason: '回復できなかった 401 は呼び出し元へ伝播する',
    );
    expect(adapter.guestInitCount, 1, reason: '再初期化は 1 回で打ち切る');
    expect(adapter.businessCallCount, 2, reason: '最初 + 再送の 2 回で止まる');
  });

  // ── ガード 3: guest-init 失敗を握り潰す ─────────────────────────────

  test('D: guest-init が失敗したら元の 401 を伝播し、古いトークンは残す', () async {
    final adapter = _ScriptedAdapter(
      unauthorizedBody: _invalidGuestBody, guestInitFails: true);
    client = build(adapter);

    await expectLater(client.dio.get('/home/'), throwsA(isA<DioException>()));
    expect(adapter.guestInitCount, 1);
    expect(adapter.businessCallCount, 1, reason: '再送しない');
    expect(
      storage.values[_kGuestTokenKey], 'stale-guest-token',
      reason: '成功したときだけ上書きする。先に消すと「無効なトークン」が '
          '「トークン無し」に変わるだけで何も得しない',
    );
  });

  // ── FEAT-193 回帰: 素の 401 では触らない (Pre-mortem 3) ──────────────

  test('E: code の無い素の 401 ではゲストトークンを削除も再作成もしない',
      () async {
    final adapter =
        _ScriptedAdapter(unauthorizedBody: _plainUnauthorizedBody);
    client = build(adapter);

    await expectLater(client.dio.get('/home/'), throwsA(isA<DioException>()));

    expect(adapter.guestInitCount, 0,
        reason: '401 そのものをトリガにすると FEAT-193 の事故に戻る');
    expect(adapter.businessCallCount, 1, reason: '再送もしない');
    expect(storage.values[_kGuestTokenKey], 'stale-guest-token',
        reason: '一時的な 401 でゲストのデータを失わせない');
  });

  test('E2: 別 code (auth_guest_token_malformed) でも再作成しない', () async {
    // 形式不正はクライアント側の不具合の可能性がある。
    // 自動再初期化するとバグを隠したままセッションを量産することになる。
    final adapter = _ScriptedAdapter(unauthorizedBody: _malformedBody);
    client = build(adapter);

    await expectLater(client.dio.get('/home/'), throwsA(isA<DioException>()));

    expect(adapter.guestInitCount, 0);
    expect(storage.values[_kGuestTokenKey], 'stale-guest-token');
  });

  test('E3: 401 以外 (403) では何もしない', () async {
    final adapter = _ScriptedAdapter(unauthorizedBody: _invalidGuestBody);
    client = build(adapter);
    // 403 を返す adapter に差し替える
    client.dio.httpClientAdapter = _Status403Adapter(adapter);

    await expectLater(client.dio.get('/home/'), throwsA(isA<DioException>()));
    expect(adapter.guestInitCount, 0);
  });

  // ── Phase C: probe は認証インターセプタを通らない ────────────────────

  test('F: probeDio は ApiClient の interceptor を持たない', () {
    client = build(_ScriptedAdapter(unauthorizedBody: _invalidGuestBody));

    // Dio が既定で入れる `ImplyContentTypeInterceptor` は残る。
    // 問題なのは **ApiClient が足した** 認証 / cache / 5xx sentinel のほうなので、
    // それらの型が入っていないことを見る。
    expect(
      client.probeDio.interceptors.whereType<InterceptorsWrapper>(), isEmpty,
      reason: '認証ヘッダを付ける InterceptorsWrapper が probe に載っていたら、'
          '認証が壊れているときに /health/ まで 401 になる (BUG-147 の症状)',
    );
    expect(
      client.dio.interceptors.whereType<InterceptorsWrapper>(), isNotEmpty,
      reason: '業務用 Dio 側には認証 interceptor が居ること (対照)',
    );
    expect(identical(client.probeDio, client.dio), isFalse);
  });

  test('F2: probeDio は古いトークンがあっても Authorization を付けない',
      () async {
    client = build(_ScriptedAdapter(unauthorizedBody: _invalidGuestBody));
    final probeAdapter = _ScriptedAdapter(unauthorizedBody: _invalidGuestBody);
    client.probeDio.httpClientAdapter = probeAdapter;

    await client.probeDio.get(
      '/health/',
      options: Options(validateStatus: (_) => true),
    );

    expect(probeAdapter.authHeaders.single, isNull,
        reason: '認証が壊れているときにこそ使う endpoint に認証を混ぜない');
  });

  test('F3: probeDio は同じインスタンスを再利用する', () {
    client = build(_ScriptedAdapter(unauthorizedBody: _invalidGuestBody));
    expect(identical(client.probeDio, client.probeDio), isTrue);
  });
}

/// 403 を返すだけの adapter (E3 用)。呼び出し回数は委譲先で数える。
class _Status403Adapter implements HttpClientAdapter {
  _Status403Adapter(this.inner);
  final _ScriptedAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains('guest-init')) return inner.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString('{"detail":"forbidden"}', 403,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}
