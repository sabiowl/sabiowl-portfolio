// 【FEAT-242】OnboardingPage flow integration test
//
// FEAT-232 (name sheet 廃止 + OnboardingPage 統一) + FEAT-233 (性別 3 値 / キャラ 2 列 /
// タイムライン自動登録 / ステータス順固定) で完成形に整備したオンボーディング体験を
// 自動検証する 6 シナリオ。
//
// テストカバレッジ:
//   1. ゲスト経路で全 6 ステップを完走 → /home へ遷移
//   2. 性別未選択で「次へ」→ SnackBar 警告
//   3. 名前空欄で「次へ」→ SnackBar 警告
//   4. キャラ未選択時の「始めましょう 🪶」非活性
//   5. 「前へ」ボタンで前ステップに戻れる
//   6. 性別 3 値が「男性 → 女性 → 回答しない」順で表示（FEAT-233）

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/router/app_router.dart';
import 'package:sabiowl/features/auth/pages/onboarding_page.dart';
import 'package:sabiowl/features/timeline/providers/timeline_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Fake HttpClientAdapter — Dio を完全オフラインで動かす
// ─────────────────────────────────────────────────────────────────────────────

class _FakeHttpAdapter implements HttpClientAdapter {
  /// 受信したリクエストの監査ログ（テストでアサーションに使う）
  final List<({String method, String path, dynamic data})> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    requests.add((
      method: options.method,
      path: options.path,
      data: options.data,
    ));

    final headers = {
      'content-type': ['application/json'],
    };

    // ── /auth/guest-init/ ────────────────────────────────────────
    if (options.path == '/auth/guest-init/' && options.method == 'POST') {
      return ResponseBody.fromString(
        jsonEncode({
          'token': 'fake_guest_token_xyz',
          'player_profile': {'id': 1, 'name': 'guest'},
        }),
        200,
        headers: headers,
      );
    }

    // ── /player/ PATCH ───────────────────────────────────────────
    if (options.path == '/player/' && options.method == 'PATCH') {
      return ResponseBody.fromString('{}', 200, headers: headers);
    }

    // ── /characters/ GET ─────────────────────────────────────────
    if (options.path == '/characters/' && options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode([
          {'id': 100, 'key': 'aria',    'name': 'アリア'},
          {'id': 101, 'key': 'beatrix', 'name': 'ベアトリス'},
        ]),
        200,
        headers: headers,
      );
    }

    // ── /characters/<id>/select/ POST ────────────────────────────
    if (options.path.startsWith('/characters/') &&
        options.path.endsWith('/select/') &&
        options.method == 'POST') {
      return ResponseBody.fromString('{}', 200, headers: headers);
    }

    // ── 未知エンドポイント ──────────────────────────────────────
    // 200 空応答（タイムライン API などへの fallback、テスト崩壊防止）
    return ResponseBody.fromString('{}', 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// FlutterSecureStorage モック（MethodChannel レベル）
// ─────────────────────────────────────────────────────────────────────────────

void _installSecureStorageMock() {
  final Map<String, String> store = {};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async {
      switch (call.method) {
        case 'read':
          final key = (call.arguments as Map)['key'] as String;
          return store[key];
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

// ─────────────────────────────────────────────────────────────────────────────
// ApiClient を差し替えるための fake adapter 同梱版 ProviderScope ビルダー
// ─────────────────────────────────────────────────────────────────────────────

({Widget widget, _FakeHttpAdapter adapter}) _buildApp() {
  final adapter = _FakeHttpAdapter();

  final router = GoRouter(
    initialLocation: AppRoutes.onboarding,
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (_, __) => const OnboardingPage(),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, __) => const Scaffold(body: Center(child: Text('Home Page'))),
      ),
    ],
  );

  return (
    widget: ProviderScope(
      overrides: [
        // ApiClient はそのまま使うが、内部 Dio の adapter を fake に差し替える
        apiClientProvider.overrideWith((ref) {
          final client = ApiClient(ref);
          client.dio.httpClientAdapter = adapter;
          return client;
        }),
        // timelineAutoCreateProvider は no-op に（Dio fake で吸収済みだが、
        // SharedPreferences I/O を完全に避けてテスト独立性を上げる）
        timelineAutoCreateProvider.overrideWith((ref, date) async {}),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
      ),
    ),
    adapter: adapter,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト本体
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // 各テストで SecureStorage + SharedPreferences をモックする
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _installSecureStorageMock();
  });

  /// 【2026-07-25 修正】テスト viewport を実機相当のスマホ縦画面にする。
  ///
  /// flutter_test の default は 800x600 (横長のデスクトップ相当)。OnboardingPage は
  /// スマホ縦画面専用 (ios/Runner/Info.plist で縦向き固定) の設計であり、特に
  /// 2026-07-09 hotfix の「2 キャラ縦長ヒーローカード」(childAspectRatio: 0.85、
  /// 画像 120px) は縦に大きい。800x600 ではカード下部のキャラ名がボトムナビ
  /// 領域に潜り込み、`tester.tap(find.text('アリア'))` が hit test に失敗していた
  /// (実機では発生しない、テスト viewport 固有の症状)。
  ///
  /// 390x844 = iPhone 14 相当の論理サイズ。
  void useMobileViewport(WidgetTester tester) {
    tester.view.physicalSize      = const Size(390, 844);
    tester.view.devicePixelRatio  = 1.0;
    addTearDown(tester.view.reset);
  }

  group('OnboardingPage flow test（FEAT-232/233 系譜の CI 保護）', () {
    // ── シナリオ 1: 標準フローを 6 ステップで完走 ────────────────────
    testWidgets('1. ゲスト経路で全 6 ステップを完走できる（最終的に /home へ遷移）', (tester) async {
      final built = _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // Step 0-2: 世界観スライド ×3 → 「次へ」を 3 回タップ
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('次へ'));
        await tester.pumpAndSettle();
      }

      // Step 3: 性別選択ステップ
      expect(
        find.text('お差し支えなければ、性別をお聞かせいただけますか'),
        findsOneWidget,
        reason: '性別ステップに遷移している',
      );
      await tester.tap(find.text('男性'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('次へ'));
      await tester.pumpAndSettle();

      // Step 4: 名前入力ステップ
      expect(
        find.text('あなたの名前を、教えていただけますか。'),
        findsOneWidget,
        reason: '名前ステップに遷移している',
      );
      await tester.enterText(find.byType(TextField), 'テスト勇者');
      await tester.pumpAndSettle();
      await tester.tap(find.text('次へ'));
      await tester.pumpAndSettle();

      // Step 5: キャラ選択ステップ
      expect(
        find.text('旅の仲間を、お選びいただけますか。'),
        findsOneWidget,
        reason: 'キャラステップに遷移している',
      );
      // 最初のキャラ（アリア）をタップ
      await tester.tap(find.text('アリア'));
      await tester.pumpAndSettle();

      // 「始めましょう 🪶」が表示され、活性化している
      expect(find.text('始めましょう 🪶'), findsOneWidget);
      await tester.tap(find.text('始めましょう 🪶'));
      // _complete() 内の dio 呼び出し + timeline + tutorial フラグ → context.go(home)
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      // /home に遷移している
      expect(find.text('Home Page'), findsOneWidget, reason: '/home へ遷移済み');

      // dio リクエストの監査: 期待するエンドポイントすべてがヒット
      final paths = built.adapter.requests.map((r) => '${r.method} ${r.path}').toList();
      expect(paths, contains('POST /auth/guest-init/'),
          reason: 'ゲストトークンが無いので guest-init が呼ばれた');
      expect(paths, contains('PATCH /player/'),
          reason: '名前 + 性別の PATCH が呼ばれた');
      expect(paths, contains('GET /characters/'),
          reason: 'キャラリスト取得が呼ばれた');
      expect(paths, contains('POST /characters/100/select/'),
          reason: '選択したキャラ (id=100=aria) の select が呼ばれた');

      // PATCH /player/ の body に name + gender が含まれている
      final patchReq = built.adapter.requests.firstWhere(
        (r) => r.method == 'PATCH' && r.path == '/player/',
      );
      expect(patchReq.data, isA<Map>());
      final patchBody = patchReq.data as Map;
      expect(patchBody['name'], 'テスト勇者');
      expect(patchBody['gender'], 'm', reason: '男性 = "m"');
    });

    // ── シナリオ 2: 性別未選択ガード ─────────────────────────────────
    testWidgets('2. 性別を選ばずに「次へ」タップで SnackBar 警告 + ステップ移動なし', (tester) async {
      final built = _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // 世界観 3 ステップを通過
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('次へ'));
        await tester.pumpAndSettle();
      }
      expect(find.text('お差し支えなければ、性別をお聞かせいただけますか'), findsOneWidget);

      // 性別を選ばずに「次へ」
      await tester.tap(find.text('次へ'));
      await tester.pump();   // SnackBar アニメ開始
      await tester.pump(const Duration(milliseconds: 300));

      // SnackBar が表示されている
      expect(
        find.text('🪶 性別を選んでいただけますか'),
        findsOneWidget,
        reason: 'FEAT-221 の性別未選択ガード SnackBar',
      );
      // ステップは進んでいない（性別画面のまま）
      expect(find.text('お差し支えなければ、性別をお聞かせいただけますか'), findsOneWidget);
      expect(find.text('あなたの名前を、教えていただけますか。'), findsNothing,
          reason: '名前ステップには進んでいない');
    });

    // ── シナリオ 3: 名前空欄ガード ───────────────────────────────────
    testWidgets('3. 名前空欄で「次へ」タップで SnackBar 警告 + ステップ移動なし', (tester) async {
      final built = _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // 世界観 3 + 性別 → 名前ステップへ
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('次へ'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('女性'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('次へ'));
      await tester.pumpAndSettle();
      expect(find.text('あなたの名前を、教えていただけますか。'), findsOneWidget);

      // 名前を入れずに「次へ」
      await tester.tap(find.text('次へ'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // SnackBar 表示
      expect(
        find.text('🪶 お名前を教えていただけますか'),
        findsOneWidget,
        reason: 'FEAT-194 の名前空欄ガード SnackBar',
      );
      // ステップは進んでいない
      expect(find.text('あなたの名前を、教えていただけますか。'), findsOneWidget);
      expect(find.text('旅の仲間を、お選びいただけますか。'), findsNothing,
          reason: 'キャラステップには進んでいない');
    });

    // ── シナリオ 4: キャラ未選択時の「始めましょう」非活性 ───────────
    testWidgets('4. キャラ未選択時は「始めましょう 🪶」ボタンが非活性（onPressed: null）',
        (tester) async {
      final built = _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // 世界観 3 + 性別 + 名前 → キャラステップへ
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('次へ'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('男性'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('次へ'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '勇者X');
      await tester.tap(find.text('次へ'));
      await tester.pumpAndSettle();

      expect(find.text('旅の仲間を、お選びいただけますか。'), findsOneWidget);
      expect(find.text('始めましょう 🪶'), findsOneWidget);

      // ボタンの ElevatedButton ウィジェットを取得して onPressed が null か確認
      // 【FEAT-194】`_isCharacterStep && _selectedCharKey == null` で disabled
      final button = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('始めましょう 🪶'),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(button.onPressed, isNull,
          reason: 'キャラ未選択時は onPressed: null で非活性');

      // キャラを選択すると活性化
      await tester.tap(find.text('アリア'));
      await tester.pumpAndSettle();
      final buttonAfter = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('始めましょう 🪶'),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(buttonAfter.onPressed, isNotNull,
          reason: 'キャラ選択後は activated');
    });

    // ── シナリオ 5: 前へボタンで戻れる ───────────────────────────────
    testWidgets('5. 「前へ」ボタンで名前ステップ → 性別ステップに戻れる', (tester) async {
      final built = _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // 世界観 3 + 性別 → 名前ステップ
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('次へ'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('男性'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('次へ'));
      await tester.pumpAndSettle();
      expect(find.text('あなたの名前を、教えていただけますか。'), findsOneWidget);

      // 「前へ」をタップ → 性別ステップに戻る
      expect(find.text('前へ'), findsOneWidget);
      await tester.tap(find.text('前へ'));
      await tester.pumpAndSettle();

      expect(find.text('お差し支えなければ、性別をお聞かせいただけますか'), findsOneWidget,
          reason: '性別ステップに戻っている');
      expect(find.text('あなたの名前を、教えていただけますか。'), findsNothing);

      // 選択した性別（男性）は保持されている → 「次へ」で再前進可能
      await tester.tap(find.text('次へ'));
      await tester.pumpAndSettle();
      expect(find.text('あなたの名前を、教えていただけますか。'), findsOneWidget,
          reason: '性別保持により再前進できる（再選択不要）');
    });

    // ── シナリオ 6: 性別 3 値の表示順 ────────────────────────────────
    testWidgets('6. 性別選択肢が「男性 → 女性 → 回答しない」順で表示（FEAT-233）',
        (tester) async {
      final built = _buildApp();
      useMobileViewport(tester);
      await tester.pumpWidget(built.widget);
      await tester.pumpAndSettle();

      // 世界観 3 ステップを通過 → 性別ステップへ
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('次へ'));
        await tester.pumpAndSettle();
      }
      expect(find.text('お差し支えなければ、性別をお聞かせいただけますか'), findsOneWidget);

      // 3 つの選択肢が表示されている
      expect(find.text('男性'),     findsOneWidget);
      expect(find.text('女性'),     findsOneWidget);
      expect(find.text('回答しない'), findsOneWidget);

      // 縦方向の Y 座標で順序を確認（男性 < 女性 < 回答しない）
      final maleY    = tester.getCenter(find.text('男性')).dy;
      final femaleY  = tester.getCenter(find.text('女性')).dy;
      final noAnsY   = tester.getCenter(find.text('回答しない')).dy;

      expect(maleY,   lessThan(femaleY),
          reason: '男性が女性より上に表示されている');
      expect(femaleY, lessThan(noAnsY),
          reason: '女性が回答しないより上に表示されている');
    });
  });
}
