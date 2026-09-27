import 'package:dio/dio.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 【BUG-160 (2026-09-12)】HTTP breadcrumb を Sentry に積む Dio interceptor。
///
/// ## なぜ自前で書くのか
///
/// Sentry の dio 連携は別パッケージ (`sentry_dio`) で、**依存を増やさずに
/// 同じことができる**。積むのは `Breadcrumb.http` 1 件だけで、
/// SDK 側の型をそのまま使う。
///
/// ## 🔴 記録するもの / しないもの
///
/// | | |
/// |---|---|
/// | ✅ method / URL / status code / 所要時間 | 「何を叩いて何が返ったか」 |
/// | ⛔ request / response body | 習慣名・メモ・予定タイトルが入る |
/// | ⛔ ヘッダー | `Authorization` が入る |
///
/// ⚠️ **breadcrumb は `beforeSend` の対象外である。** イベント本体の
/// スクラビングでは消えないので、**そもそも入れない**のが唯一の防御になる。
///
/// ## URL は誰が伏せるのか
///
/// ここではない。`SentryOptions.beforeBreadcrumb`
/// (`sentry_breadcrumb_scrubber.dart`) が **1 件ずつ**伏せる。
///
/// 🔵 そちらに寄せている理由は、**HTTP breadcrumb の出所がここだけとは
/// 限らない**から。フック側に置けば、将来ほかの経路が増えても同じ規則が
/// 自動的に効く。
class SentryBreadcrumbInterceptor extends Interceptor {
  SentryBreadcrumbInterceptor({void Function(Breadcrumb)? addBreadcrumb})
      : _add = addBreadcrumb ?? _defaultAdd;

  final void Function(Breadcrumb) _add;

  static void _defaultAdd(Breadcrumb crumb) {
    // ignore: discarded_futures — fire-and-forget。UI も通信も待たせない。
    Sentry.addBreadcrumb(crumb);
  }

  /// 経過時間を測るための開始時刻の置き場。
  ///
  /// ⚠️ `RequestOptions.extra` に入れる。interceptor 側に Map を持つと
  /// **並列リクエストで取り違える** (ホーム起動時は 10 本以上が同時に飛ぶ)。
  static const _startedAtKey = 'sentry_breadcrumb_started_at';

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    options.extra[_startedAtKey] = DateTime.now();
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _record(response.requestOptions, response.statusCode);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // 🔴 落ちたときの 1 本が残らないと、調査で一番見たいものが無い。
    _record(err.requestOptions, err.response?.statusCode);
    handler.next(err);
  }

  void _record(RequestOptions options, int? statusCode) {
    final startedAt = options.extra[_startedAtKey];
    final duration = startedAt is DateTime
        ? DateTime.now().difference(startedAt)
        : null;
    try {
      _add(Breadcrumb.http(
        url: options.uri,
        method: options.method,
        statusCode: statusCode,
        requestDuration: duration,
        // ⛔ requestBodySize / responseBodySize は渡さない。
        //    サイズ自体は無害だが、算出のために body を触る必要があり、
        //    「body には触らない」という一本の規則を崩したくない。
      ));
    } catch (_) {
      // breadcrumb を積めなくても通信は止めない。
    }
  }
}
