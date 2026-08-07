import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../models/challenge.dart';
import '../services/challenge_service.dart';

/// 【FEAT-465 (2026-06-24)】既存 social / settings 等の手動プロバイダー feature と
/// 整合 (CLAUDE.md「既存の手動プロバイダー feature は移行しない」、新規でも本
/// FEAT は指示書 §2-4 の skeleton をそのまま踏襲して手動パターンを採用)。

final challengeServiceProvider = Provider<ChallengeService>((ref) {
  return ChallengeService(ref.watch(apiClientProvider));
});

final challengeListProvider =
    FutureProvider.autoDispose<ChallengeListData>((ref) {
  return ref.watch(challengeServiceProvider).fetchChallenges();
});
