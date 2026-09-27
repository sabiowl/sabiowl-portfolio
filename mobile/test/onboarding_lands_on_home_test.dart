// 【BUG-161 (2026-09-12)】オンボーディング完了後にログイン画面へ弾かれる。
//
// ## 🔴 本物のルーターを使うこと
//
// `onboarding_page_flow_test.dart` は**自前の `GoRouter` を組んでおり
// `redirect` を持っていない**。だから「`context.go(home)` が呼ばれたこと」しか
// 確かめておらず、**「ユーザーがホームに着くこと」は確かめていなかった**。
// 結果、**緑のまま本番だけ壊れた**。
//
// 🔵 本プロジェクトで繰り返している形の別の顔である ——
// BUG-152 以降は「手で数えたリスト」で漏れ、ここでは「手で組んだルーター」で
// 漏れた。⚠️ **どちらも「本物を使っていない」ことが原因である。**
//
// ## 何が起きていたか
//
// オンボーディングは `guestInit()` → `saveGuestToken()` を直接呼び、
// **`authProvider` には何も伝えていなかった**。status は `unauthenticated` の
// まま `context.go(home)` するので、BUG-156 で入った
// 「未認証ならログイン画面へ」という**正しい規則**に弾かれる。
//
// 🔴 BUG-156 の redirect を戻してはならない。戻すと「401 を受けても
// 読み込みエラーだらけのホームに留まり続ける」状態が再発する。
// **直すべきは迂回のほうである。**

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/constants/preferences_keys.dart';
import 'package:sabiowl/core/cache/cache_service.dart';
import 'package:sabiowl/core/router/app_router.dart';
import 'package:sabiowl/features/auth/providers/auth_provider.dart';
import 'package:sabiowl/features/timeline/providers/timeline_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

// ── オフライン Dio ───────────────────────────────────────────────────────────

class _FakeHttpAdapter implements HttpClientAdapter {
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.path}');
    final headers = {
      'content-type': ['application/json'],
    };

    if (options.path == '/auth/guest-init/' && options.method == 'POST') {
      return ResponseBody.fromString(
        jsonEncode({
          'token': 'fake_guest_xyz',
          'player_profile': {'id': 1, 'name': 'guest'},
        }),
        200,
        headers: headers,
      );
    }
    // 🔴 【BUG-166】認証画面を経由するようになったので、`startAsGuest` が
    //    player-scoped provider を一斉 invalidate する ——
    //    **ホームの fetch がテストの早い段階で走る**。
    //    `{}` を返すと `fetchHabits` の cast で落ちて、
    //    **本当に見たいこと (行き先) とは無関係な赤になる**。
    if (options.path == '/habits/' && options.method == 'GET') {
      return ResponseBody.fromString('[]', 200, headers: headers);
    }
    if (options.path == '/player/' && options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode({'id': 1, 'name': 'テスト勇者', 'level': 1, 'exp': 0}),
        200,
        headers: headers,
      );
    }
    if (options.path == '/characters/' && options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode([
          {'id': 100, 'key': 'aria', 'name': 'アリア'},
          {'id': 101, 'key': 'beatrix', 'name': 'ベアトリス'},
        ]),
        200,
        headers: headers,
      );
    }
    return ResponseBody.fromString('{}', 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, String> _installSecureStorageMock({
  Map<String, String>? seed,
  /// このキーへの write を黙って捨てる。
  ///
  /// ⚠️ 「保存したつもりで実際には残っていない」を作るためのもの。
  /// これがないと §4 のテスト 3 は**代入実装でも緑になる** ——
  /// guest-init を失敗させる形だと例外で再判定行に到達せず、
  /// テストが違う理由で通ってしまう (実際に一度そうなった)。
  Set<String> dropWritesFor = const {},
}) {
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
          final key = args['key'] as String;
          if (dropWritesFor.contains(key)) return null;
          store[key] = args['value'] as String;
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

// ── 🔴 本物の appRouterProvider を使うアプリ ─────────────────────────────────
//
// ⛔ `GoRouter(...)` を自分で組んで routes だけ並べる形にしないこと。
//    **それが本 BUG を見逃した原因そのものである。**

class _Harness {
  _Harness(this.adapter);
  final _FakeHttpAdapter adapter;
  late final ProviderContainer container;

  String get location =>
      container.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path;

  AuthStatus get authStatus => container.read(authProvider).status;

  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
  }
}

/// 🔴 【BUG-166】認証画面を経由するようになったので `startAsGuest` を通る。
///
/// あれは `cacheServiceProvider` と `localGoogleEventStoreProvider` を読むので、
/// **注入しないと本題と無関係な赤になる**
/// (`cacheServiceProvider` は既定で `UnimplementedError` を投げ、
///  SQLite は `databaseFactory` 未初期化で落ちる)。
Future<_Harness> _buildApp({_FakeHttpAdapter? adapter}) async {
  final harness = _Harness(adapter ?? _FakeHttpAdapter());
  final prefs = await SharedPreferences.getInstance();
  harness.container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWith((ref) {
        final client = ApiClient(ref);
        client.dio.httpClientAdapter = harness.adapter;
        client.probeDio.httpClientAdapter = harness.adapter;
        return client;
      }),
      cacheServiceProvider.overrideWithValue(CacheService(prefs)),
      timelineAutoCreateProvider.overrideWith((ref, date) async {}),
    ],
  );
  return harness;
}

Widget _appOf(_Harness harness) => UncontrolledProviderScope(
      container: harness.container,
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          routerConfig: ref.watch(appRouterProvider),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('ja'),
        ),
      ),
    );

/// スプラッシュ (1.5 秒待ち) を抜けて、着地した画面まで進める。
///
/// 🔴 【BUG-166 (2026-09-12)】**着地先は認証画面になった。**
/// 旧実装はトークンが無く tutorial 未表示なら `/onboarding` へ直行して
/// いたが、**認証済みユーザーの再インストールもそこを通り、
/// 「新しいゲスト」にされていた**。
Future<void> _reachLanding(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// 認証画面から「ゲストとして始める」を押してオンボーディングへ進む。
Future<void> _startAsGuestFromAuth(WidgetTester tester) async {
  await tester.tap(find.text('ゲストとして始める'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

/// スプラッシュ → 認証画面 → ゲストで始める → オンボーディング。
Future<void> _reachOnboarding(WidgetTester tester) async {
  await _reachLanding(tester);
  await _startAsGuestFromAuth(tester);
}

/// ホームは Timer を回しているので、tree を落としてから終わる。
///
/// ⚠️ 本物のルーターを使う代償。自前の `GoRouter` なら軸の軽い
/// ダミー画面で済むが、**それが本 BUG を見逃した形**である。
Future<void> _disposeTree(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // ⚠️ Timer を作っているのは widget ではなく provider なので、
  //    tree を落とすだけでは止まらない。container もここで破棄する
  //    (`addTearDown` だと Timer 検査の**あと**に走る)。
  harness.dispose();
  await tester.pump(const Duration(seconds: 1));
}

/// オンボーディングを最後まで入力して「始めましょう」を押す。
Future<void> _completeOnboarding(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('男性'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('次へ'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'テスト勇者');
  await tester.pumpAndSettle();
  await tester.tap(find.text('次へ'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('アリア'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('始めましょう 🪶'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _installSecureStorageMock();
  });

  void useMobileViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('BUG-161 オンボーディング完了後の行き先', () {
    testWidgets('🔴 1: 完了後に /login へ弾かれない', (tester) async {
      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      // 🔴 【BUG-166】まず認証画面に着く。
      await _reachLanding(tester);
      expect(harness.location, AppRoutes.register,
          reason: 'トークンが無いのに認証画面へ送っていない = 前提が崩れている');
      await _startAsGuestFromAuth(tester);
      // 空振り検出: そのあとオンボーディングに着いていること。
      expect(harness.location, AppRoutes.onboarding,
          reason: 'ゲストで始めてもオンボーディングへ送っていない');

      await _completeOnboarding(tester);

      expect(harness.location, isNot(AppRoutes.login),
          reason: 'オンボーディングを終えた直後にログイン画面へ弾かれている。'
              '一度済ませた認証の選択をもう一度求めることになる');
      expect(harness.location, AppRoutes.home);
      await _disposeTree(tester, harness);
    });

    testWidgets('🔴 2: 完了後の status が authenticated', (tester) async {
      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      // 🔴 【BUG-166】前提の確認は**ゲストで始める前**に置く。
      //    あとに置くと `startAsGuest` が既に authenticated にしているので、
      //    **前提が崩れていても気づけない**。
      await _reachLanding(tester);
      expect(harness.authStatus, AuthStatus.unauthenticated,
          reason: '開始時点では未認証のはず = 前提が崩れている');

      await _startAsGuestFromAuth(tester);
      await _completeOnboarding(tester);

      expect(harness.authStatus, AuthStatus.authenticated,
          reason: 'トークンを作ったのに authProvider が古いままである');
      await _disposeTree(tester, harness);
    });

    testWidgets('⚠️ 3: トークンが残っていないなら「設定済み」を書かない',
        (tester) async {
      // 🔴 【FEAT-542】指示書 §4.1 の受け入れ条件
      //    「**id が取れない瞬間の扱いを決めて書く**」に対応する。
      //
      // ⛔ 「取れないので設定済みとみなす」は選ばない。持ち主のいない
      //    「設定済み」を残すと、**次に作られる身元がそれを引き継ぐ** ——
      //    名前もキャラも無いままホームに着く（2026-07-02 の症状）。
      //
      // ⚠️ **guest-init を失敗させる形にしないこと。** 例外で
      //    `_complete()` の catch に飛び、記録行にそもそも到達しないので
      //    **どんな実装でも緑になる**。「保存は走ったが残っていない」を作る。
      _installSecureStorageMock(dropWritesFor: {'hg_guest_token'});
      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      await _reachOnboarding(tester);
      await _completeOnboarding(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(kPrefsProfileSetupCompletedFor), isNull,
        reason: '持ち主がいないのに「設定済み」を書いている。'
            '次に作られるゲストがそれを引き継ぎ、'
            '名前「ゲスト」+ キャラ未選択のままホームへ着く',
      );
      await _disposeTree(tester, harness);
    });

    testWidgets('🔵 4: ゲストトークンが既にあっても /home に着く', (tester) async {
      // iOS 再インストール経路。`if (!hasUserToken && !hasGuestToken)` の
      // **中**に再判定を置くと、このケースで効かない。
      _installSecureStorageMock(seed: {'hg_guest_token': 'already_there'});
      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      // 🔵 【BUG-166】ここは**認証画面を経由しない**。
      //    ゲストトークンがあるので `_performAuthCheck` の case B に入り、
      //    「トークンはあるが設定が途中」の再開としてオンボーディング直行になる。
      //    ⚠️ **case B の `tutorialShown` は BUG-166 でも残している。**
      await _reachLanding(tester);
      expect(harness.location, AppRoutes.onboarding,
          reason: 'ゲストトークンがあるので case B で再開するはず');

      await _completeOnboarding(tester);

      expect(harness.location, AppRoutes.home);
      expect(harness.adapter.requests, isNot(contains('POST /auth/guest-init/')),
          reason: '既存トークンがあるのに guest-init を呼び直している');
      await _disposeTree(tester, harness);
    });
  });

  group('BUG-166 トークンが無ければ必ず認証画面へ', () {
    testWidgets('🔴 1: 認証済み → 再インストール → **ログイン画面**',
        (tester) async {
      // 🔴 **v1.1.2 の主題そのものである。**
      //
      // 再インストールすると `secure_storage_initialized` のマーカーが
      // 消えているので BUG-156 の掃除が走り、`hg_token` も
      // `has_seen_tutorial` も消える。
      //
      // ⚠️ 旧実装はここで `tutorialShown == false` を見て
      // **オンボーディングへ送っていた**。しかも
      // `OnboardingPage._complete()` は「トークンが無ければ guest-init」を
      // 呼ぶので、**Google 連携済みのユーザーが再インストールしただけで
      // 「新しいゲスト」にされていた**（dev 実機確認 2026-09-12）。
      //
      // 🔵 What's New の「既存ユーザーが一度だけログアウトされる」は
      // **ログイン画面が出る前提の文言**である。
      _installSecureStorageMock(seed: {
        // iOS の Keychain は uninstall で消えないので、掃除前はこれが残る。
        'hg_token': 'stale_user_token',
        'is_registered': 'true',
        'has_seen_tutorial': 'true',
      });
      // 🔴 マーカーを**立てない** = 再インストール直後の状態。
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      await _reachLanding(tester);

      expect(
        harness.location, isNot(AppRoutes.onboarding),
        reason: '再インストールした認証済みユーザーをオンボーディングへ送っている。'
            'そのまま完了すると guest-init が走り「新しいゲスト」にされる',
      );
      expect(
        harness.location,
        anyOf(AppRoutes.login, AppRoutes.register),
        reason: 'ログイン画面に着いていない',
      );
      await _disposeTree(tester, harness);
    });

    testWidgets('🔴 2: 真の初回起動でも認証画面（ゲストを黙って作らない）',
        (tester) async {
      // 🔵 **選ばせることが目的である。** オンボーディングは
      //    `guest-init` を黙って呼ぶので、ユーザーに
      //    「サインインするか、新しく始めるか」を選ぶ機会が無い。
      _installSecureStorageMock();
      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      await _reachLanding(tester);

      expect(harness.location, AppRoutes.register);
      // 🔴 **この時点で guest-init を呼んでいないこと。**
      //    呼んでいたら「黙ってゲストにした」ことになる。
      expect(
        harness.adapter.requests,
        isNot(contains('POST /auth/guest-init/')),
        reason: '認証画面に着く前にゲストを作っている',
      );
      expect(find.text('ゲストとして始める'), findsOneWidget,
          reason: 'ゲストで始める選択肢が出ていない');
      await _disposeTree(tester, harness);
    });

    test('⚠️ 3: 走査 —— case C が tutorial フラグで分岐していない', () {
      // 🔴 `has_seen_tutorial` は secure storage にあり、
      //    **iOS では再インストールで残るが Android では消える**。
      //    フラグの生存を当てにした分岐は**プラットフォームで挙動が分かれる**。
      //
      // ⚠️ case B / B'（ゲストトークンあり = 設定が途中）の `tutorialShown` は
      //    **残してよい**。役目が別である。ここでは
      //    **「トークンが無い側」の分岐に使われていないこと**だけを縛る。
      final source = _readSource('lib/core/router/app_router.dart');
      final marker = source.indexOf('// C. ');
      expect(marker, greaterThan(-1),
          reason: '走査が case C を見つけていない');
      // 🔴 **コメントを落としてから見る。** 本節の doc コメントは
      //    「旧実装はこうだった」を引用しているので、
      //    素のまま走査すると**自分の説明文に当たって落ちる**（実際に踏んだ）。
      //    縛りたいのは**コードの中身**である。
      final tail = _stripLineComments(source.substring(marker));
      // 🔵 【FEAT-542】旧 `hasTutorialBeenShown` は
      //    `isProfileSetupCompleted` に替わった。**縛る中身は同じ** ——
      //    「トークンが無い側」の分岐がフラグを見ていないこと。
      expect(
        tail, isNot(contains('isProfileSetupCompleted')),
        reason: 'case C がまだ設定完了フラグを見ている。'
            '再インストールした認証済みユーザーがオンボーディングへ送られる',
      );
      // 空振り検出: case C 自体は残っていること。
      expect(tail, contains('isRegistered'),
          reason: '走査対象がそもそも case C ではない');
    });
  });

  group('BUG-167 更新した既存ゲストをオンボーディングへ戻さない', () {
    testWidgets('🔴 1: 既存ゲストが更新 → **ホーム**（名前とキャラを聞き直さない）',
        (tester) async {
      // 🔴 **再インストールではなく更新である。**
      //
      // 更新では SharedPreferences が残るが、`secure_storage_initialized` は
      // v1.1.2 で新設されたので一度も書かれていない。つまり BUG-156 の掃除が走る。
      // 旧実装はそこで `has_seen_tutorial` を消し、トークンだけを残していた。
      //
      // ⚠️ 再インストールでは起きない。トークンとフラグが一緒に残るか
      //    一緒に消えるので、**この組み合わせを作れない** ——
      //    **dev 実機確認をすり抜けた理由である。**
      _installSecureStorageMock(seed: {
        'hg_guest_token': 'existing_guest',
        'has_seen_tutorial': 'true',
        'guest_mode': 'true',
      });
      // 🔴 マーカーを**立てない** = v1.1.1 から更新した直後。
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      // ⚠️ `_reachLanding` は使わない。着地先がホームなら、ホームが回す Timer で
      //    `pumpAndSettle` が終わらない（実際に踏んだ）。スプラッシュの
      //    1.5 秒を越える分だけ固定で進める。
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        harness.location, isNot(AppRoutes.onboarding),
        reason: '更新した既存ゲストをオンボーディングへ戻している。'
            '完了すると PATCH /player/ が名前と性別を、'
            'キャラ選択の POST が選んだキャラを上書きする',
      );
      expect(harness.location, AppRoutes.home);
      // 🔴 ゲストとして扱われ続けていること（連携・ログアウトガードの前提）。
      expect(
        await harness.container.read(apiClientProvider).isGuestMode(), isTrue,
        reason: 'guest_mode が消え、連携済みとして扱われている',
      );
      // 🔵 新しいゲストを作っていないこと（同じプロフィールのまま）。
      expect(
        harness.adapter.requests,
        isNot(contains('POST /auth/guest-init/')),
      );
      await _disposeTree(tester, harness);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 【FEAT-542 (2026-09-23)】認証を先に済ませ、プロフィール設定をその後に
  // ───────────────────────────────────────────────────────────────────────
  //
  // 🔴 **指示書 §5 の経路表を、本物のルーターで縛る。**
  //
  // 旧 `onboarding_page_flow_test.dart` は自前の `GoRouter` を組んでおり
  // `redirect` を持たない。だから BUG-161 を**緑のまま見逃した**。

  group('FEAT-542 §5 経路', () {
    testWidgets('🔴 1: ゲストで始める → 設定中に kill → 再起動で**設定へ戻る**',
        (tester) async {
      // ⚠️ **新順序ではこれが通常の中間状態である。**
      //    ゲストは認証画面でトークンを得てから設定へ進むので、
      //    「トークンあり + 設定未完了」を旧順序より頻繁に通る。
      final harness = await _buildApp();
      useMobileViewport(tester);

      await tester.pumpWidget(_appOf(harness));
      await _reachOnboarding(tester);
      expect(harness.location, AppRoutes.onboarding,
          reason: '前提が崩れている。設定画面に着いていない');
      // 🔴 ここで kill する（完了させない）。
      await _disposeTree(tester, harness);

      // 再起動。storage と SharedPreferences はそのまま残っている。
      final restarted = await _buildApp();
      addTearDown(restarted.dispose);
      await tester.pumpWidget(_appOf(restarted));
      await _reachLanding(tester);

      expect(
        restarted.location, AppRoutes.onboarding,
        reason: '設定の途中で落ちたのにホームへ着いている。'
            '名前「ゲスト」+ キャラ未選択のまま使い始めることになる',
      );
      await _disposeTree(tester, restarted);
    });

    testWidgets('🔴 2: 古い「設定済み」を**新しいゲストが引き継がない**',
        (tester) async {
      // 🔴 **指示書 §4.1 が案 B を選んだ理由そのものである。**
      //
      //   連携済みユーザーのトークンが消える（更新 / ログアウト / 401）
      //     -> 認証画面で「ゲストとして始める」-> 新しいゲスト
      //     -> 設定の途中で kill -> 再起動
      //     -> 端末に付いた真偽値だと「トークンあり + 設定済み」でホームへ
      //     -> 名前「ゲスト」+ キャラ未選択（2026-07-02 の症状）
      //
      // 🔵 値に持ち主が入っていれば、**読み手 1 箇所**で弾ける。
      _installSecureStorageMock();
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApiClient.kSecureStorageInitializedKey: true,
        kPrefsDeviceFlagsMigrated: true,
        kPrefsIsRegistered: true,
        // 前の持ち主が残した「設定済み」。
        kPrefsProfileSetupCompletedFor:
            profileSetupIdentityOf('token_of_the_previous_owner'),
      });

      final harness = await _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(_appOf(harness));
      await _reachLanding(tester);
      expect(harness.location, AppRoutes.login,
          reason: '前提が崩れている。トークンが無いのに認証画面へ送っていない');

      await _startAsGuestFromAuth(tester);
      expect(harness.location, AppRoutes.onboarding);
      // 設定の途中で kill。
      await _disposeTree(tester, harness);

      final restarted = await _buildApp();
      addTearDown(restarted.dispose);
      await tester.pumpWidget(_appOf(restarted));
      await _reachLanding(tester);

      expect(
        restarted.location, AppRoutes.onboarding,
        reason: '別の持ち主の「設定済み」を引き継いでホームへ着いている。'
            'フラグが端末に付いたままで、身元に付いていない',
      );
      await _disposeTree(tester, restarted);
    });

    testWidgets('🔵 3: 設定を終えたゲストは、再起動でホームへ', (tester) async {
      // 空振り検出。上の 2 件が「常にオンボーディング」で緑になる形を防ぐ。
      final harness = await _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(_appOf(harness));
      await _reachOnboarding(tester);
      await _completeOnboarding(tester);
      expect(harness.location, AppRoutes.home);
      await _disposeTree(tester, harness);

      final restarted = await _buildApp();
      addTearDown(restarted.dispose);
      await tester.pumpWidget(_appOf(restarted));
      // ⚠️ 着地先がホームなら `pumpAndSettle` は終わらない（Timer）。
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 600));

      expect(restarted.location, AppRoutes.home,
          reason: '設定を終えたのに、毎回聞き直している');
      await _disposeTree(tester, restarted);
    });

    testWidgets('🔵 4: 連携済みユーザー（case A）は設定を飛ばしてホームへ',
        (tester) async {
      // 🔴 **ここで設定完了を見てはいけない。** 見ると、端末を替えた /
      //    入れ直した既存ユーザーはフラグを持たないので、
      //    **設定済みの人をオンボーディングへ送り、名前とキャラを上書きする**
      //    —— BUG-167 と同じ事故になる。
      _installSecureStorageMock(seed: {'hg_token': 'live_user_token'});
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApiClient.kSecureStorageInitializedKey: true,
        kPrefsDeviceFlagsMigrated: true,
        kPrefsIsRegistered: true,
        // 設定済みフラグは**無い**（端末を入れ替えた直後）。
      });

      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);
      await tester.pumpWidget(_appOf(harness));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        harness.location, AppRoutes.home,
        reason: '設定済みの既存ユーザーをオンボーディングへ送っている。'
            '完了すると名前とキャラが上書きされる',
      );
      await _disposeTree(tester, harness);
    });

    testWidgets(
        '🔵 5: ゲスト → 再インストール（iOS）は**設定をもう一度通る**',
        (tester) async {
      // 🔵 **指示書 §5 が「期待値を決めること」とした行の答えである。**
      //
      // BUG-156 §3-1-a はゲストトークンを保全する（失うと復旧経路がゼロ）。
      // 一方 `profile_setup_completed_for` は `SharedPreferences` にあり、
      // **再インストールでは消える** —— だから設定をもう一度通る。
      //
      // ⚠️ **それでよいと判断した。** 更新（BUG-167）は全ユーザーに
      // **黙って**起きるが、再インストールは**ユーザーの明示操作**で、
      // しかも入力画面が出るので**黙って失われない**。
      // 🔴 逆に secure storage へ置き直すと、BUG-167 の「掃除に巻き込まれる」
      // 系統が戻ってくる —— **そちらのほうが再発の確率が高い。**
      _installSecureStorageMock(seed: {'hg_guest_token': 'kept_by_keychain'});
      // 🔴 マーカーを立てない = 再インストール直後（prefs は空）。
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final harness = await _buildApp();
      addTearDown(harness.dispose);
      useMobileViewport(tester);
      await tester.pumpWidget(_appOf(harness));
      await _reachLanding(tester);

      expect(harness.location, AppRoutes.onboarding);
      // 🔴 **ゲストトークンは保全されていること。** ここが消えていたら
      //    データごと失われており、行き先どころの話ではない。
      expect(
        await harness.container.read(apiClientProvider).getGuestToken(),
        'kept_by_keychain',
        reason: 'ゲストトークンを消している。ゲストのデータは'
            'このトークンでしか辿れず、復旧経路がゼロになる',
      );
      await _disposeTree(tester, harness);
    });
  });

  group('FEAT-542 走査 —— 迂回が生き残っていないこと', () {
    test('🔴 1: トークンを作るのは authProvider と設定画面だけ', () {
      // 🔴 増えたら、そこが「`authProvider` を通さずに身元が生まれる」経路になる。
      //    BUG-161 / BUG-166 / 計測欠落は、**すべて同じ 1 箇所**が原因だった。
      // ⚠️ **パス区切りを `/` に正規化してから比べること。**
      //    `Directory.listSync` は Windows で `\`、Linux で `/` を返す。
      //    忘れると**手元では緑、CI だけが赤**になる（実際に一度そうなった）。
      const known = {
        // 設定画面からのアカウント連携（ゲスト昇格 / 既存ユーザーへの合流）。
        'lib/features/settings/services/settings_service.dart',
      };
      final hits = _scan(
        (line) =>
            line.contains('.guestInit()') ||
            line.contains('.saveGuestToken(') ||
            line.contains('.saveToken('),
        // authProvider 自身は当然呼ぶので対象外。
        skipFile: (path) => path.endsWith('auth_provider.dart'),
      );
      expect(hits, isNotEmpty,
          reason: '走査が 1 件も見つけていない = パスか綴りが間違っている');
      expect(
        _filesOf(hits), known,
        reason: 'authProvider の外でトークンを作る箇所が変わった: $hits',
      );
      // 🔴 オンボーディングが戻ってきていないこと（本 FEAT の主題）。
      expect(
        _filesOf(hits),
        isNot(contains('lib/features/auth/pages/onboarding_page.dart')),
        reason: 'オンボーディングがまた黙ってゲストを作っている',
      );
    });

    test('🔴 2: guest-init を叩くのは 2 箇所だけ', () {
      // ⚠️ 上の走査は `.guestInit()` という**呼び方**を見ているので、
      //    dio を直接叩く経路は素通りする。エンドポイントの文字列でも縛る。
      const known = {
        'lib/features/auth/services/auth_service.dart',  // AuthService.guestInit
        'lib/core/api/api_client.dart',  // 【BUG-147】401 からの自動再作成
      };
      final hits = _scan((line) => line.contains("'/auth/guest-init/'"));
      expect(hits, isNotEmpty, reason: '走査が空振りしている');
      expect(_filesOf(hits), known,
          reason: 'guest-init を叩く箇所が増えた: $hits');
    });

    test('🔴 3: 真偽値の profile_setup_completed が 1 件も無い', () {
      // 🔴 指示書 §4.1 の受け入れ条件。途中で「簡単だから」と真偽値を
      //    足されると、**持ち主を見ない側が分岐に使われて案 A に戻る**。
      final hits = _scan(
        (line) => line.contains("'profile_setup_completed'"),
      );
      expect(
        hits, isEmpty,
        reason: '持ち主を持たない真偽値のキーが生えている: $hits\n'
            '読み手が身元と突き合わせられなくなり、'
            '古い「設定済み」を新しいゲストが引き継ぐ',
      );
      // 空振り検出: 持ち主付きのキーは実在すること。
      final owned = _scan(
        (line) => line.contains("'profile_setup_completed_for'"),
      );
      expect(owned, isNotEmpty, reason: '走査の綴りが間違っている');
    });

    test('🔴 4: has_seen_tutorial を読み書きするのは移設だけ', () {
      // 🔴 旧キーは**意味を 2 つ兼任**していた。分岐に使う人が戻ってくると、
      //    同じ二重意味が復活する。
      final hits = _scan((line) => line.contains("'has_seen_tutorial'"));
      expect(
        _filesOf(hits), {'lib/core/api/api_client.dart'},
        reason: '移設以外が旧キーを触っている: $hits',
      );
    });
  });
}

/// `lib/` を走査して、`path:行番号` で当たった行を返す。
///
/// ⚠️ 行コメントは落とす。**説明文に当たって落ちる**のを防ぐため
/// （本プロジェクトで実際に踏んだ形）。
List<String> _scan(
  bool Function(String line) match, {
  bool Function(String path)? skipFile,
}) {
  final hits = <String>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.endsWith('.g.dart')) continue;
    if (skipFile?.call(_slash(entity.path)) ?? false) continue;
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      if (match(line)) hits.add('${_slash(entity.path)}:${i + 1}');
    }
  }
  return hits;
}

/// `path:行番号` から行番号を落とす。
///
/// ⚠️ `split(':').first` は使わない —— ドライブレタを含むパス (`C:/...`) で
/// 先頭で切れてしまう。
Set<String> _filesOf(List<String> hits) =>
    hits.map((h) => h.substring(0, h.lastIndexOf(':'))).toSet();

/// パス区切りを `/` に揃える。
///
/// ⚠️ `Directory.listSync` は Windows で `\`、Linux で `/` を返す。
/// 揃えないと**手元では緑、CI だけが赤**になる。
String _slash(String path) => path.replaceAll(r'\', '/');

/// 行コメント (`//`) を落とす。走査で**説明文に当たらない**ようにするため。
String _stripLineComments(String source) => source
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 走査対象を読む。テストの作業ディレクトリは `mobile/`。
String _readSource(String relativePath) {
  final f = File(relativePath);
  if (!f.existsSync()) {
    throw StateError('走査対象が見つからない: $relativePath');
  }
  return f.readAsStringSync();
}
