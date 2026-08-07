import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/providers/maintenance_provider.dart';
import 'package:sabiowl/core/services/maintenance_service.dart';

/// 200 OK + maintenance JSON ボディを返す fake adapter。
class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"is_enabled": true, "title": "テスト", "body": "本文 🪶", "expires_at": null}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 常に通信エラーを返す fake adapter。
class _ErrorAdapter implements HttpClientAdapter {
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

/// 常に disabled を返す fake service (Notifier の単体テスト用)。
class _FakeOffMaintenanceService extends MaintenanceService {
  _FakeOffMaintenanceService() : super(Dio());

  @override
  Future<MaintenanceStatus> fetchStatus() async => MaintenanceStatus.off;
}

void main() {
  group('FEAT-463 MaintenanceService', () {
    test('fetchStatus 200 OK → MaintenanceStatus parse 成功', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
        ..httpClientAdapter = _OkAdapter();
      final service = MaintenanceService(dio);

      final status = await service.fetchStatus();

      expect(status.isEnabled, isTrue);
      expect(status.title, 'テスト');
      expect(status.body, '本文 🪶');
      expect(status.expiresAt, isNull);
    });

    test('fetchStatus network error → off にフォールバック', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
        ..httpClientAdapter = _ErrorAdapter();
      final service = MaintenanceService(dio);

      final status = await service.fetchStatus();

      expect(status.isEnabled, isFalse);
      expect(status, same(MaintenanceStatus.off));
    });
  });

  group('FEAT-463 MaintenanceStatusNotifier', () {
    test('markEnabledFromHeader 後 isEnabled=true', () {
      final notifier = MaintenanceStatusNotifier(_FakeOffMaintenanceService());

      expect(notifier.state.isEnabled, isFalse);
      notifier.markEnabledFromHeader();
      expect(notifier.state.isEnabled, isTrue);
    });

    test('refresh で API が disabled 返却 → state.off', () async {
      final notifier = MaintenanceStatusNotifier(_FakeOffMaintenanceService());

      await notifier.refresh();

      expect(notifier.state, same(MaintenanceStatus.off));
    });
  });
}
