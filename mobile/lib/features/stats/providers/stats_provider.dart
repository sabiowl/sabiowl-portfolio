import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

/// 【FEAT-204】30 日累積データ + マイルストーン情報のレスポンス DTO。
class Stats30DayData {
  Stats30DayData({
    required this.days,
    required this.currentStreak,
    required this.nextMilestone,
    required this.daysToNextMilestone,
    required this.totalCompletions30d,
  });

  /// 30 日分のデータ（要素: `{date: ISO 文字列, count: int, cumulative: int}`）
  final List<Map<String, dynamic>> days;
  final int currentStreak;
  final int nextMilestone;
  final int daysToNextMilestone;
  final int totalCompletions30d;

  factory Stats30DayData.fromJson(Map<String, dynamic> json) {
    final daysRaw = (json['days'] as List<dynamic>?) ?? const [];
    final milestones =
        (json['milestones'] as Map<String, dynamic>?) ?? const {};
    return Stats30DayData(
      days: daysRaw
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false),
      currentStreak:       (milestones['current_streak']         as int?) ?? 0,
      nextMilestone:       (milestones['next_streak_milestone']  as int?) ?? 7,
      daysToNextMilestone: (milestones['days_to_next_milestone'] as int?) ?? 7,
      totalCompletions30d: (milestones['total_completions_30d']  as int?) ?? 0,
    );
  }
}

/// `GET /api/stats/30d/` を取得する Provider。
/// ホーム画面が watch する。pull-to-refresh で invalidate される想定。
final stats30dProvider = FutureProvider.autoDispose<Stats30DayData>((ref) async {
  final apiClient = ref.read(apiClientProvider);
  final response  = await apiClient.dio.get('/stats/30d/');
  return Stats30DayData.fromJson(response.data as Map<String, dynamic>);
});
