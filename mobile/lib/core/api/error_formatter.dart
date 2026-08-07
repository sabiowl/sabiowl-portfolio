/// 【FEAT-407 (2026-06-01)】API エラー → サビ口調メッセージ変換の中央化ヘルパー。
///
/// 各画面の `catch (e)` で `formatApiError(e)` を呼べば、Backend の `{'error': '...'}`
/// フィールドが取れる場合はその内容、取れない場合はサビ口調 fallback を返す。
///
/// ## 使用方法
/// ```dart
/// import 'package:sabiowl/core/api/error_formatter.dart';
///
/// } catch (e) {
///   if (mounted) {
///     ScaffoldMessenger.of(context).showSnackBar(
///       SnackBar(content: Text(formatApiError(e))),
///     );
///   }
/// }
/// ```
///
/// ## 実装方針
/// - `friend_profile_page.dart` の旧 `_extractErrorMessage` と完全同等のロジック (Pre-mortem S2)
/// - 生例外 `'$e'` の露出を構造的に防止する単一エントリポイント
/// - Backend `{'error': '...'}` のメッセージを抽出できれば優先表示
/// - 抽出失敗時は CLAUDE.md「システム文（エラー・SnackBar・空状態）の扱い」準拠の
///   穏やかな丁寧体 + 🪶 マーカーで fallback
///
/// 【FEAT-489 Phase 2D (2026-08-02)】fallback 文言を arb 化。本関数は BuildContext
/// を取らない純粋関数 (6 ファイル / 十数箇所から呼ばれる) のため、引数追加ではなく
/// [ServiceL10n] 経由で現在 locale を解決する。
library;

import '../l10n/service_l10n.dart';
import 'dio_error_helper.dart';

/// 【FEAT-515 (2026-08-04)】新形式 `{'error': {'code', 'message'}}` を読めるようにする。
///
/// ## 直す前に起きていたこと
///
/// 旧実装は `data['error'] as String` だった。新形式では `data['error']` が
/// **Map** なので cast が例外になり、`catch (_)` に飲まれて **必ず汎用文言に
/// フォールバック**していた。
///
/// FEAT-475 で 77 endpoint を新形式に移行済みだったため、
/// **その 77 経路すべてで個別のエラー文言がユーザーに届いていなかった**
/// ("チケットが不足しています" ではなく "うまくいきませんでした" が出る)。
/// 例外は握り潰され、型エラーとしても表面化しなかった。
///
/// ## 実装
///
/// 3 形式の parse は既に [ApiError.fromResponse] が持っている。
/// 二重実装せず、そこに委譲して文言を取り出すだけにする。
///
/// 【FEAT-515 Phase 2】取り出すのは `message` ではなく [ApiError.localizedMessage]。
/// `message` は Backend が組み立てた**日本語**なので、そのまま出すと
/// 英語 UI のユーザーが失敗時だけ日本語を見ることになる。
// ignore: avoid_dynamic_calls
String formatApiError(Object e) {
  try {
    // ignore: avoid_dynamic_calls
    final data = (e as dynamic).response?.data;
    if (data != null) {
      final err = ApiError.fromResponse(data);
      final text = err.localizedMessage;
      if (text.isNotEmpty) return text;
    }
  } catch (_) {}
  return ServiceL10n.current.coreApiDefaultErrorSabi_message;
}
