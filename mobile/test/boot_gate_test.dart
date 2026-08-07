import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/api/api_client.dart';
import 'package:sabiowl/core/providers/connection_error_provider.dart';
import 'package:sabiowl/core/providers/maintenance_provider.dart';
import 'package:sabiowl/core/services/maintenance_service.dart';
import 'package:sabiowl/core/widgets/boot_gate.dart';

// ── Fake HttpClientAdapters ──────────────────────────────────────────────────

/// /health/ に 200 を返す fake adapter。
class _HealthOkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('{"status":"ok"}', 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

/// /health/ に 503 を返す fake adapter（Backend 障害シミュレーション）。
class _HealthDegradedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('{"error":"schema drift"}', 503,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

/// 全リクエストに対してネットワークエラーを返す fake adapter。
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

// ── Fake Services ─────────────────────────────────────────────────────────────

class _MaintenanceOn extends MaintenanceService {
  _MaintenanceOn() : super(Dio());
  @override
  Future<MaintenanceStatus> fetchStatus() async => MaintenanceStatus(
        isEnabled: true,
        title: 'メンテ中',
        body: '少々お待ちください 🪶',
        expiresAt: null,
      );
}

class _MaintenanceOff extends MaintenanceService {
  _MaintenanceOff() : super(Dio());
  @override
  Future<MaintenanceStatus> fetchStatus() async => MaintenanceStatus.off;
}

/// 永久に完了しない fake（非ブロッキングテスト用）。
/// Completer を使い実 Timer を作らない（fake_async の "Pending timers" 検知を回避）。
class _MaintenanceNeverResolve extends MaintenanceService {
  _MaintenanceNeverResolve() : super(Dio());
  final Completer<MaintenanceStatus> _completer = Completer();
  @override
  Future<MaintenanceStatus> fetchStatus() => _completer.future;
}

// ── Fake ApiClient ────────────────────────────────────────────────────────────

/// ApiClient を最小構成で差し替えるための test-only サブクラス。
/// parent constructor は _dio を初期化するが、_testDio で getter をオーバーライド
/// するため、parent の _dio は一切使われない。
class _FakeApiClient extends ApiClient {
  _FakeApiClient(super.ref, this._testDio);
  final Dio _testDio;

  @override
  Dio get dio => _testDio;
}

// ── Helper ────────────────────────────────────────────────────────────────────

/// テスト用 widget ツリーを組み立てる。
Widget _buildWidget({
  required HttpClientAdapter healthAdapter,
  required MaintenanceService maintenanceService,
}) {
  final fakeDio =
      Dio(BaseOptions(baseUrl: 'https://test.example', validateStatus: (_) => true))
        ..httpClientAdapter = healthAdapter;

  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWith((ref) => _FakeApiClient(ref, fakeDio)),
      maintenanceServiceProvider.overrideWith((_) => maintenanceService),
    ],
    child: const MaterialApp(
      home: BootGate(child: Text('child_widget')),
    ),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('FEAT-483 BootGate 非ブロッキング + Case 判定', () {
    testWidgets('非ブロッキング: 子 widget が probe 完了前に即描画される', (tester) async {
      // probe が永久に完了しない状態でも child が見える
      await tester.pumpWidget(
        _buildWidget(
          healthAdapter: _NetworkErrorAdapter(),
          maintenanceService: _MaintenanceNeverResolve(),
        ),
      );

      // 1 フレームだけ pump (addPostFrameCallback の発火を待つ)
      await tester.pump();

      // BootSplash が存在しない（非ブロッキングになったため）
      expect(find.text('起動中です 🪶'), findsNothing);
      // 子が即座に描画されている（probe 未完了時点、fake clock 進行前）
      expect(find.text('child_widget'), findsOneWidget);

      // fake clock を probeTimeout (10s) 超まで進め、内部 timeout timer を
      // 消化してからテストを終える（fake_async の "Pending timers" 検知回避）。
      // 【2026-07-09】probeTimeout を 3s → 10s に緩和したため待機時間を 4s → 12s に更新。
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('Case B: health=200 + maintenance.isEnabled=false → overlay 非表示', (tester) async {
      await tester.pumpWidget(
        _buildWidget(
          healthAdapter: _HealthOkAdapter(),
          maintenanceService: _MaintenanceOff(),
        ),
      );
      // probe 完了まで settle
      await tester.pumpAndSettle();

      // maintenanceStatusProvider は off のまま → 子だけ表示
      expect(find.text('child_widget'), findsOneWidget);

      // ProviderScope 内の provider 状態を確認
      final element = tester.element(find.text('child_widget'));
      final container = ProviderScope.containerOf(element);
      expect(container.read(maintenanceStatusProvider).isEnabled, isFalse);
    });

    testWidgets('Case A: health=200 + maintenance.isEnabled=true → overlay 発火', (tester) async {
      await tester.pumpWidget(
        _buildWidget(
          healthAdapter: _HealthOkAdapter(),
          maintenanceService: _MaintenanceOn(),
        ),
      );
      await tester.pumpAndSettle();

      final element = tester.element(find.text('child_widget'));
      final container = ProviderScope.containerOf(element);
      expect(container.read(maintenanceStatusProvider).isEnabled, isTrue);
      expect(container.read(maintenanceStatusProvider).title, 'メンテ中');
    });

    testWidgets(
        'Case C: health=5xx → connectionError が set される (2026-07-09 再設計)',
        (tester) async {
      // 【2026-07-09 v3】admin 意図の maintenance と mobile 側の推測 (通信/サーバエラー)
      // を別 provider に分離。Case C (health 5xx) は maintenance ではなく
      // connectionErrorProvider を発火する。
      await tester.pumpWidget(
        _buildWidget(
          healthAdapter: _HealthDegradedAdapter(),
          maintenanceService: _MaintenanceOff(),
        ),
      );
      await tester.pumpAndSettle();

      final element = tester.element(find.text('child_widget'));
      final container = ProviderScope.containerOf(element);
      // 503 → !health.isOk → connectionError.mark() → hasError=true
      expect(container.read(connectionErrorProvider).hasError, isTrue);
      // maintenance は独立、admin 意図が無いため OFF のまま
      expect(container.read(maintenanceStatusProvider).isEnabled, isFalse);
    });

    testWidgets(
        'Case D (network error): connectionError が set される (2026-07-09 v3)',
        (tester) async {
      // 【2026-07-09 v3】通信エラーも同じく connectionErrorProvider を発火する
      // (v2 では「何もしない」だったが user 要望で ConnectionErrorOverlay 発火に)。
      await tester.pumpWidget(
        _buildWidget(
          healthAdapter: _NetworkErrorAdapter(),
          maintenanceService: _MaintenanceOff(),
        ),
      );
      await tester.pumpAndSettle();

      final element = tester.element(find.text('child_widget'));
      final container = ProviderScope.containerOf(element);
      // network error → !health.isOk → connectionError.mark() → hasError=true
      expect(container.read(connectionErrorProvider).hasError, isTrue);
      // maintenance は独立して OFF
      expect(container.read(maintenanceStatusProvider).isEnabled, isFalse);
      // 子 widget は引き続き mount されている (ConnectionErrorOverlay が
      // 表示するかどうかは main.dart 側の layer 判定、本 test は provider 状態のみ)
      expect(find.text('child_widget'), findsOneWidget);
    });

    testWidgets(
        'Case A + Case C 共存: maintenance ON + health 5xx → maintenance が優先',
        (tester) async {
      // maintenance が admin 意図で ON かつ Backend も 5xx を返している場合、
      // Case A が先に評価され maintenance provider のみ更新、connectionError は
      // 発火しない。UI 層で MaintenanceOverlay が上位に表示されることを担保。
      await tester.pumpWidget(
        _buildWidget(
          healthAdapter: _HealthDegradedAdapter(),
          maintenanceService: _MaintenanceOn(),
        ),
      );
      await tester.pumpAndSettle();

      final element = tester.element(find.text('child_widget'));
      final container = ProviderScope.containerOf(element);
      // Case A 優先: maintenance ON
      expect(container.read(maintenanceStatusProvider).isEnabled, isTrue);
      // connectionError は発火せず (Case C の else 分岐に入らない)
      expect(container.read(connectionErrorProvider).hasError, isFalse);
    });

    testWidgets('probe 終了後も child は常に描画されている', (tester) async {
      await tester.pumpWidget(
        _buildWidget(
          healthAdapter: _HealthOkAdapter(),
          maintenanceService: _MaintenanceOff(),
        ),
      );

      // probe 前
      await tester.pump();
      expect(find.text('child_widget'), findsOneWidget);

      // probe 完了後
      await tester.pumpAndSettle();
      expect(find.text('child_widget'), findsOneWidget);
    });
  });
}
