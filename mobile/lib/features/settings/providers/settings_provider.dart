import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../services/settings_service.dart';

final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService(ref.watch(apiClientProvider));
});

/// 連携済みアカウント情報。設定画面を開くたびに再取得（autoDispose）。
/// 連携操作後は `ref.invalidate(linkedAccountsProvider)` で再フェッチする。
///
/// FEAT-183: ゲスト時は DRF トークンが無いため `/api/auth/social/accounts/`
/// が 401 を返す。これを「未連携の正常状態」として扱い、`LinkedAccounts.empty`
/// を返してタイルが「未連携・タップ可能」として正しく表示されるようにする。
/// 認証済みユーザーの 401（セッション失効）は従来通り例外として伝播し、
/// ApiClient の onError インターセプタがハンドリングする。
final linkedAccountsProvider =
    FutureProvider.autoDispose<LinkedAccounts>((ref) async {
  final service = ref.watch(settingsServiceProvider);
  try {
    return await service.fetchLinkedAccounts();
  } on DioException catch (e) {
    if (e.response?.statusCode == 401) {
      final isGuest = await ref.read(apiClientProvider).isGuestMode();
      if (isGuest) {
        return LinkedAccounts.empty;
      }
    }
    rethrow;
  }
});
