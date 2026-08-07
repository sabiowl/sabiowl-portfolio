import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../services/feature_flag_service.dart';

/// 【FEAT-477 (2026-07-03)】FeatureFlagService プロバイダー。
final featureFlagServiceProvider = Provider<FeatureFlagService>((ref) {
  return FeatureFlagService(ref.watch(apiClientProvider).dio);
});

/// Backend から取得した Feature Flag マップ。
///
/// autoDispose にしない: アプリ全体で保持するグローバル状態。
/// ネットワーク障害時は {} を返し、全 flag=false で動作する (Pre-mortem S4)。
/// 使用側: FeatureFlagService.isEnabled(ref.watch(featureFlagsProvider).valueOrNull, 'flag_name')
final featureFlagsProvider = FutureProvider<Map<String, bool>>((ref) async {
  return ref.watch(featureFlagServiceProvider).fetchFlags();
});
