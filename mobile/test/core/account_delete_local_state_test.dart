// 【BUG-162 (2026-09-12)】アカウント削除の後片付けが効いていなかった。
//
// ## 起点
//
// dev 実機確認 2026-09-12。
//   ゲストで開始 → アカウント削除 → ログイン画面 → 「ゲストとして始める」
//   → **ホーム画面（名前は「ゲスト」、名前入力もキャラ選択も出ない）**
//
// 🔵 これは 2026-07-02 に一度直した症状と同じ形である
// (`auth_page.dart` の `_onGuestStart` のコメント参照)。
//
// ## 確定した欠陥 2 件
//
// 1. 🔴 `has_seen_tutorial` と `guest_mode` を **`SharedPreferences` から**
//    消していた。**このキーは secure storage にある**ので何も消えていない。
// 2. 🔴 後片付け中に古いゲストトークンで飛んだリクエストが
//    `auth_guest_token_invalid` を受け、**BUG-147 の自動再作成が
//    新しいゲストセッションを作る**。
//
// ⚠️ 2 が「実機で見た症状の原因である」ことは**確認できていない**
// (タイミング依存で、ローカルでは再現しなかった)。
// **原因と確定していないものを「直した」と書かないこと。**

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/constants/preferences_keys.dart';

class _Adapter implements HttpClientAdapter {
  final List<String> requests = [];
  int guestInitCount = 0;

  /// このトークンを提示したリクエストには 401 + `auth_guest_token_invalid`
  /// を返す（サーバ側でセッションが消えた状態）。
  String? deadGuestToken;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    final auth = options.headers['Authorization'] as String?;
    requests.add('${options.method} ${options.path}');
    final headers = {
      'content-type': ['application/json'],
    };

    if (options.path == '/auth/guest-init/' && options.method == 'POST') {
      guestInitCount++;
      return ResponseBody.fromString(
        jsonEncode({
          'token': 'remade_guest',
          'player_profile': {'id': 9, 'name': 'ゲスト'},
        }),
        200,
        headers: headers,
      );
    }

    final dead = deadGuestToken;
    if (dead != null && auth == 'GuestToken $dead') {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {
            'code': 'auth_guest_token_invalid',
            'message': 'ゲストセッションが見つかりません',
          }
        }),
        401,
        headers: headers,
      );
    }
    return ResponseBody.fromString('{}', 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, String> _installSecureStorageMock({Map<String, String>? seed}) {
  final store = <String, String>{...?seed};
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
  return store;
}

({ApiClient client, _Adapter adapter, ProviderContainer container}) _build() {
  final adapter = _Adapter();
  late ApiClient client;
  final container = ProviderContainer(overrides: [
    apiClientProvider.overrideWith((ref) {
      client = ApiClient(ref);
      client.dio.httpClientAdapter = adapter;
      return client;
    }),
  ]);
  // provider を一度読んで client を確定させる。
  container.read(apiClientProvider);
  return (client: client, adapter: adapter, container: container);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 再インストール掃除 (BUG-156) は本件と無関係なので走らせない。
    SharedPreferences.setMockInitialValues(<String, Object>{
      ApiClient.kSecureStorageInitializedKey: true,
    });
    // ⚠️ 抑止フラグは `static` なのでテスト間で持ち越される。
    ApiClient.debugResetGuestReinitSuppression();
  });

  group('BUG-162 §1 アカウント削除が secure storage を消す', () {
    test('🔴 1: 設定済みフラグと guest_mode が残らない', () async {
      // 🔵 【FEAT-542 (2026-09-23)】4 キーは `SharedPreferences` へ移設した。
      //    **どちらに置いても「消し忘れると前の続きになる」ことは変わらない**
      //    ので、本テストは置き場所ではなく**消えたこと**を見る。
      _installSecureStorageMock(seed: {
        'hg_token': 'user_token',
        'hg_guest_token': 'guest_token',
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApiClient.kSecureStorageInitializedKey: true,
        kPrefsDeviceFlagsMigrated: true,
        kPrefsTokenValidatedAt: '2026-09-12T00:00:00.000',
        kPrefsIsRegistered: true,
        kPrefsProfileSetupCompletedFor: profileSetupIdentityOf('user_token'),
        kPrefsGuestMode: true,
      });
      final h = _build();
      addTearDown(h.container.dispose);

      // 空振り検出: 掃除の前に本当に効いていること。
      expect(await h.client.isProfileSetupCompleted(), isTrue,
          reason: '前提が崩れている。seed が効いていない');
      expect(await h.client.isGuestMode(), isTrue);

      await h.client.clearLocalStateForAccountDeletion();

      // 🔴 起動時の行き先を決める 2 つ。旧実装は消す先を間違えていたので、
      //    ここが残ったままだった。
      expect(await h.client.isProfileSetupCompleted(), isFalse,
          reason: '設定済みフラグが残っている。'
              'アカウントを消したのに「前の続き」として扱われる');
      expect(await h.client.isGuestMode(), isFalse,
          reason: 'guest_mode が残っている。'
              'トークンが無いのにゲストとして起動判定される');

      // トークンと登録済みフラグも消える。
      expect(await h.client.getToken(), isNull);
      expect(await h.client.getGuestToken(), isNull);
      expect(await h.client.isRegistered(), isFalse);
      expect(await h.client.getTokenValidatedAt(), isNull);
    });

    test('⚠️ ログアウトでは消さない（一時的に離れる経路なので残す）', () async {
      _installSecureStorageMock(seed: {'hg_token': 'user_token'});
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApiClient.kSecureStorageInitializedKey: true,
        kPrefsDeviceFlagsMigrated: true,
        kPrefsProfileSetupCompletedFor: profileSetupIdentityOf('user_token'),
        kPrefsGuestMode: true,
      });
      final h = _build();
      addTearDown(h.container.dispose);

      await h.client.deleteToken();

      // 🔵 `deleteToken()` は意図的に残す。再ログイン時にオンボーディングを
      //    再表示しないため。**アカウント削除と混同しないこと。**
      //
      // 🔵 【FEAT-542】残っていても**他人には効かない**。値に持ち主が
      //    入っているので、別の身元で戻ってくれば一致せず「未設定」と読まれる。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefsProfileSetupCompletedFor),
          profileSetupIdentityOf('user_token'),
          reason: 'ログアウトで消してしまうと、再ログイン時に'
              'オンボーディングが再表示される');
      expect(prefs.getBool(kPrefsGuestMode), isTrue);
      expect(await h.client.getToken(), isNull);
    });

    test('🔴 【FEAT-542】残った設定済みフラグは、別の身元には効かない', () async {
      // ⛔ 真偽値のままだと、**古い「設定済み」を新しいゲストが引き継ぐ**。
      //    連携済みユーザーのトークンが消える -> ゲストとして始める
      //    -> 設定の途中で kill -> 再起動でホームへ
      //    （名前「ゲスト」+ キャラ未選択 = 2026-07-02 の症状）。
      _installSecureStorageMock(seed: {'hg_guest_token': 'brand_new_guest'});
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApiClient.kSecureStorageInitializedKey: true,
        kPrefsDeviceFlagsMigrated: true,
        // 前の持ち主が残した「設定済み」。
        kPrefsProfileSetupCompletedFor: profileSetupIdentityOf('old_user_token'),
      });
      final h = _build();
      addTearDown(h.container.dispose);

      expect(
        await h.client.isProfileSetupCompleted(), isFalse,
        reason: '別の持ち主の「設定済み」を引き継いでいる。'
            '新しいゲストが名前「ゲスト」+ キャラ未選択のままホームへ着く',
      );
    });
  });

  group('BUG-162 §2 意図的に消したゲストセッションを復活させない', () {
    test('🔴 2: 抑止後は auth_guest_token_invalid でも guest-init を呼ばない',
        () async {
      _installSecureStorageMock(seed: {'hg_guest_token': 'dead_token'});
      final h = _build();
      addTearDown(h.container.dispose);
      h.adapter.deadGuestToken = 'dead_token';

      ApiClient.suppressGuestSessionRecreation();

      // 削除済みトークンのままリクエストが飛ぶ（後片付け中の状況）。
      try {
        await h.client.dio.get('/player/');
      } on DioException {
        // 401 がそのまま上がってくるのが正しい。
      }

      expect(h.adapter.guestInitCount, 0,
          reason: '削除したのに新しいゲストセッションを作っている。'
              '名前もキャラも選ばせずにホームへ着く原因になる');
      expect(await h.client.getGuestToken(), isNot('remade_guest'),
          reason: '復活したトークンが保存されている');
    });

    test('🔵 3: 抑止していなければ従来どおり再作成する（BUG-147 を壊さない）',
        () async {
      _installSecureStorageMock(seed: {'hg_guest_token': 'dead_token'});
      final h = _build();
      addTearDown(h.container.dispose);
      h.adapter.deadGuestToken = 'dead_token';

      try {
        await h.client.dio.get('/player/');
      } on DioException {
        // 再作成に成功すれば retry で 200 になる。
      }

      // 🔴 ここが 0 だと、抑止ではなく**再作成そのものを壊している**。
      expect(h.adapter.guestInitCount, 1,
          reason: 'BUG-147 の自動再作成が動いていない。'
              '無効なトークンで詰んだゲストの出口が消える');
      expect(await h.client.getGuestToken(), 'remade_guest');
    });

    test('🔴 4: ユーザーが意図してゲストを始めると抑止が解ける', () async {
      _installSecureStorageMock();
      final h = _build();
      addTearDown(h.container.dispose);

      ApiClient.suppressGuestSessionRecreation();
      // `startAsGuest` / onboarding / 連携解除がここを通る。
      await h.client.saveGuestToken('fresh_token');

      h.adapter.deadGuestToken = 'fresh_token';
      try {
        await h.client.dio.get('/player/');
      } on DioException {
        // ignore
      }

      // 🔵 抑止が解けていないと、**新しいセッションが無効になったときに
      //    BUG-147 の出口が使えないまま詰む**。
      expect(h.adapter.guestInitCount, 1,
          reason: '抑止が解けていない。'
              '意図してゲストを始めた後も再作成が止まったままになっている');
    });

    test('⚠️ 自動再作成は自分で自分の抑止を解かない', () async {
      _installSecureStorageMock(seed: {'hg_guest_token': 'dead_token'});
      final h = _build();
      addTearDown(h.container.dispose);
      h.adapter.deadGuestToken = 'dead_token';

      // まず抑止していない状態で 1 回再作成させる。
      try {
        await h.client.dio.get('/player/');
      } on DioException {/* ignore */}
      expect(h.adapter.guestInitCount, 1, reason: '前提が崩れている');

      // ここで抑止し、再作成されたトークンを無効にする。
      ApiClient.suppressGuestSessionRecreation();
      h.adapter.deadGuestToken = 'remade_guest';
      try {
        await h.client.dio.get('/player/');
      } on DioException {/* ignore */}

      // 🔴 再作成が `saveGuestToken()` を通ると、**自分で抑止を解いてしまう**。
      //    書き込みだけを行っていることを、ここで縛る。
      expect(h.adapter.guestInitCount, 1,
          reason: '自動再作成が自分の抑止を解除している。'
              '抑止が 1 回しか効かない');
    });

    test('🔴 6: ApiClient が作り直されても抑止が残る', () async {
      // 🔴 **2026-09-12 の実機確認で、ここが穴だった。**
      //
      // `apiClientProvider` は `AutoDisposeProvider` なので
      // (`api_client.g.dart`)、`_executeDelete()` が `await` を挟んで
      // `ref.read` するあいだに**インスタンスが作り直されうる**。
      //
      // ⚠️ 抑止をインスタンス変数にすると「フラグを立てたインスタンス」と
      // 「401 を処理するインスタンス」が**別物になりうる** ——
      // 実機では抑止が効かず、再作成のトーストが出た。
      _installSecureStorageMock(seed: {'hg_guest_token': 'dead_token'});

      ApiClient.suppressGuestSessionRecreation();

      // 抑止したあとに、まったく新しい ApiClient を作る。
      final h = _build();
      addTearDown(h.container.dispose);
      h.adapter.deadGuestToken = 'dead_token';

      try {
        await h.client.dio.get('/player/');
      } on DioException {/* ignore */}

      expect(h.adapter.guestInitCount, 0,
          reason: '抑止がインスタンスに閉じている。'
              'AutoDispose で作り直されると効かなくなる');
    });

    test('⚠️ 7: サーバ削除が失敗したら抑止を戻せる', () async {
      // 🔴 削除できていないのに抑止を残すと、そのセッションが後で無効に
      //    なっても BUG-147 の出口が使えないまま詰む。
      _installSecureStorageMock(seed: {'hg_guest_token': 'dead_token'});
      final h = _build();
      addTearDown(h.container.dispose);
      h.adapter.deadGuestToken = 'dead_token';

      ApiClient.suppressGuestSessionRecreation();
      ApiClient.allowGuestSessionRecreation();

      try {
        await h.client.dio.get('/player/');
      } on DioException {/* ignore */}

      expect(h.adapter.guestInitCount, 1,
          reason: '抑止が戻っていない。削除に失敗したユーザーが'
              '無効なトークンで詰んだままになる');
    });
  });
}
