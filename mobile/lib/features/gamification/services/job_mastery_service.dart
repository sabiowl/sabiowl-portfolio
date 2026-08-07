/// 【FEAT-511 Phase A (v1.1、2026-07-30)】ジョブ熟練度サービス + Provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../models/job_mastery.dart';

class JobMasteryService {
  const JobMasteryService(this._client);
  final ApiClient _client;

  Future<List<JobMastery>> fetchAll() async {
    final res = await _client.dio.get('/player/job_masteries/');
    final list = res.data['masteries'] as List<dynamic>? ?? [];
    return list
        .map((j) => JobMastery.fromJson(j as Map<String, dynamic>))
        .toList();
  }
}

final jobMasteryServiceProvider = Provider<JobMasteryService>((ref) {
  return JobMasteryService(ref.watch(apiClientProvider));
});

/// プレイヤーの全ジョブ熟練度を一括取得 (最大 13 件)。
///
/// autoDispose: キャラクターシート開閉のたびに再 fetch する。
/// Consumer 内で同一 future を参照するため N+1 は発生しない (Pre-mortem S8 対策)。
final jobMasteriesProvider = FutureProvider.autoDispose<List<JobMastery>>((ref) {
  return ref.watch(jobMasteryServiceProvider).fetchAll();
});
