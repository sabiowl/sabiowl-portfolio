/// 【FEAT-402 (2026-06-01)】Dio 例外の真のネットワーク系判定ヘルパー。
///
/// 旧 FEAT-280 SWR の `catch (e) { conn.markOffline(e.toString()); }` は
/// **何の例外でも markOffline** していたため、サーバーから HTTP 4xx/5xx が
/// 返っただけでも「現在オフラインで表示しています」橙色帯が出ていた。
///
/// 本ヘルパーで Dio 例外型を判定し、真のネットワーク系のみを offline と
/// 扱うことで誤判定を激減させる:
///
/// - `connectionTimeout` / `sendTimeout` / `receiveTimeout` → offline (本物)
/// - `connectionError` → offline (DNS / 切断)
/// - `unknown` + response==null → offline (low-level socket error 等)
/// - `badResponse` (HTTP 4xx/5xx) → **online** (サーバー応答あり)
/// - `cancel` → online (ユーザー操作 / page dispose)
/// - その他例外 (FormatException 等) → online (クライアント側 bug)
///
/// CLAUDE.md「Render コールドスタート」は Starter プラン加入 (2026-06-01) で
/// 該当しない想定だが、念のため receiveTimeout は offline 扱い維持。
library;

import 'package:dio/dio.dart';

import '../l10n/service_l10n.dart';  // 【FEAT-489 Phase 2D】BuildContext なし層の l10n
import 'api_error_messages.dart';    // 【FEAT-515 Phase 2】code → locale 別文言

/// Dio 例外が **真のネットワーク系** か判定する。
///
/// true なら markOffline 妥当 (橙色帯表示)、
/// false ならサーバー応答ありか client side bug → markOnline 維持。
bool isNetworkError(Object error) {
  if (error is! DioException) return false;
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return true;
    case DioExceptionType.unknown:
      // unknown かつ response が無い = low-level socket / DNS 系
      return error.response == null;
    case DioExceptionType.badResponse:
    case DioExceptionType.badCertificate:
    case DioExceptionType.cancel:
      return false;
  }
}

/// 【FEAT-489 Phase 2D (2026-08-02)】locale 依存になったため `const` → getter 化。
/// `ApiError.fromResponse` は BuildContext を取らない factory のため
/// [ServiceL10n] 経由で現在 locale を解決する。
String get _kDefaultSabiError =>
    ServiceL10n.current.coreApiDefaultErrorSabi_message;

/// API エラーレスポンスの統一 parse モデル (FEAT-475)。
///
/// 対応形式は **新形式 1 つだけ**:
///
/// ```json
/// {"error": {"code": "...", "message": "...", "fields": {...}}}
/// ```
///
/// ## 【FEAT-475 Phase 4 (2026-08-04)】旧形式 A / B の parser を削除した
///
/// 削除前は 3 形式に後方互換対応していた:
///
///   旧形式A `{'error': 'code_or_message_string'}`
///   旧形式B `{'errors': {'field': 'msg'}}`
///
/// 削除の前提は **「Backend に旧形式の生成側が 1 つも無いこと」**。
/// 実測で確認した (2026-08-04):
///
///   - 旧形式B: **生成側 0 件**。Phase 3c で全て新形式に移行済みで、
///     残っていたのは `health.py` の「移行した」というコメントだけだった
///   - 旧形式A: `rest_day.py` の 410 スタブ 4 件のみ。本 Phase で移行し **0 件**に
///
/// この不変条件は `backend/api/tests/test_error_response_format.py` が
/// ソース走査で縛っている (allowlist は空)。**先に parser を消すと壊れる**ので、
/// FEAT-515 Phase 1 (旧形式 78 件の移行) の完了が前提だった。
///
/// ## 形式に合わない body は汎用文言に落ちる
///
/// DRF 既定の `{'detail': '...'}` (401 / 403 / throttle) や serializer の
/// `{'field': ['msg']}` は元々どの parser にも当たらず `code='unknown'` +
/// 汎用文言だった。本削除で**その挙動は変わっていない**。
class ApiError {
  final String code;
  final String message;
  final Map<String, String> fields;

  const ApiError({
    required this.code,
    required this.message,
    required this.fields,
  });

  /// 【FEAT-515 Phase 2 (2026-08-04)】表示に使うべき文言。
  ///
  /// [message] は **Backend が組み立てた日本語**なので、そのまま出すと
  /// 英語 UI のユーザーが「失敗したときだけ日本語を見る」ことになる。
  /// [code] から ARB を引けるならそちらを優先し、引けなければ [message] に
  /// フォールバックする (訳していない code はこれまで通り = 段階導入)。
  ///
  /// **表示するときは `message` ではなく本 getter を使うこと。**
  /// 直接 `message` を読んでいる箇所が無いかは
  /// `test/core/api_error_l10n_test.dart` が縛っている。
  String get localizedMessage =>
      localizedApiError(ServiceL10n.current, code, fields) ?? message;

  factory ApiError.fromResponse(dynamic data) {
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      return ApiError(
        code: err['code']?.toString() ?? '',
        message: err['message']?.toString() ?? _kDefaultSabiError,
        fields: Map<String, String>.from(err['fields'] as Map? ?? {}),
      );
    }
    // 【FEAT-475 Phase 4 (2026-08-04)】旧形式 A / B の分岐はここにあった。
    // Backend の生成側が 0 件になったので削除 (詳細は class の doc コメント)。
    return ApiError(
      code: 'unknown',
      message: _kDefaultSabiError,
      fields: const {},
    );
  }
}
