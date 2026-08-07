// 【FEAT-465→FEAT-466 (2026-06-24)】月次カテゴリチャレンジ models。
// 既存 social_models.dart と同じ plain class + fromJson パターン (Freezed 不使用、
// build_runner 不要)。
//
// 【FEAT-466】3 段階 Bronze/Silver/Gold 累積開放方式に拡張。Ver1.0 の単一
// target_count/reward_exp/achieved は廃止し、`tiers` map + `isTiered` に置換。

/// 1 段階分の目標 / 報酬 / 達成状況。
class TierInfo {
  final int target;
  final int rewardExp;
  final bool achieved;
  final int remainingCount;

  const TierInfo({
    required this.target,
    required this.rewardExp,
    required this.achieved,
    required this.remainingCount,
  });

  factory TierInfo.fromJson(Map<String, dynamic> j) => TierInfo(
        target: j['target'] as int? ?? 0,
        rewardExp: j['reward_exp'] as int? ?? 0,
        achieved: j['achieved'] as bool? ?? false,
        remainingCount: j['remaining_count'] as int? ?? 0,
      );
}

class ChallengeEntry {
  final int id;
  final String title;
  final String description;
  final String category;
  final bool isTiered;
  final int currentCount;
  final int progressRate; // 0-100、ゴールド目標基準 (Backend で既にクランプ済、Pre-mortem S7)
  final int myContributionCount;
  final int remainingDays;
  final String startDate;
  final String endDate;

  /// `is_tiered=true` なら bronze/silver/gold の 3 キー、false なら gold のみ
  /// (Pre-mortem S6、キーの有無で表示分岐する)。
  final Map<String, TierInfo> tiers;

  const ChallengeEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.isTiered,
    required this.currentCount,
    required this.progressRate,
    required this.myContributionCount,
    required this.remainingDays,
    required this.startDate,
    required this.endDate,
    required this.tiers,
  });

  TierInfo? get bronze => tiers['bronze'];
  TierInfo? get silver => tiers['silver'];
  TierInfo? get gold => tiers['gold'];

  factory ChallengeEntry.fromJson(Map<String, dynamic> j) {
    final tiersJson = j['tiers'] as Map<String, dynamic>? ?? {};
    return ChallengeEntry(
      id: j['id'] as int? ?? 0,
      title: j['title'] as String? ?? '',
      description: j['description'] as String? ?? '',
      category: j['category'] as String? ?? '',
      isTiered: j['is_tiered'] as bool? ?? true,
      currentCount: j['current_count'] as int? ?? 0,
      progressRate: j['progress_rate'] as int? ?? 0,
      myContributionCount: j['my_contribution_count'] as int? ?? 0,
      remainingDays: j['remaining_days'] as int? ?? 0,
      startDate: j['start_date'] as String? ?? '',
      endDate: j['end_date'] as String? ?? '',
      tiers: tiersJson.map(
        (key, value) => MapEntry(key, TierInfo.fromJson(value as Map<String, dynamic>)),
      ),
    );
  }
}

/// lazy 報酬配布の結果 1 件。`achievedAny=false` は Mobile 側で SnackBar
/// 発火しない (Sabi「焦らずとも構いません」精神、§5-4 未達は無音)。
class PendingChallengeReward {
  final int challengeId;
  final String challengeTitle;

  /// 常に Bronze→Silver→Gold 順 (Backend が保証、§9 Pre-mortem S4)。
  final List<String> grantedTiers;
  final int totalRewardExp;
  final bool achievedAny;
  final int contributionCount;

  const PendingChallengeReward({
    required this.challengeId,
    required this.challengeTitle,
    required this.grantedTiers,
    required this.totalRewardExp,
    required this.achievedAny,
    required this.contributionCount,
  });

  /// granted_tiers の最高 tier ('gold' > 'silver' > 'bronze')。
  /// 1 件も配布されていない場合は null。
  /// 【Pre-mortem S4】Mobile 側でこの helper を介さず `.contains('gold')` 等で
  /// 直接判定すると誤分岐するため、必ず本 getter を経由する。
  String? get highestTier => grantedTiers.isEmpty ? null : grantedTiers.last;

  factory PendingChallengeReward.fromJson(Map<String, dynamic> j) =>
      PendingChallengeReward(
        challengeId: j['challenge_id'] as int? ?? 0,
        challengeTitle: j['challenge_title'] as String? ?? '',
        grantedTiers: (j['granted_tiers'] as List<dynamic>? ?? [])
            .map((e) => e as String)
            .toList(),
        totalRewardExp: j['total_reward_exp'] as int? ?? 0,
        achievedAny: j['achieved_any'] as bool? ?? false,
        contributionCount: j['contribution_count'] as int? ?? 0,
      );
}

class ChallengeListData {
  final String infoText;
  final List<ChallengeEntry> active;
  final List<PendingChallengeReward> pendingRewards;

  const ChallengeListData({
    required this.infoText,
    required this.active,
    required this.pendingRewards,
  });

  factory ChallengeListData.fromJson(Map<String, dynamic> j) =>
      ChallengeListData(
        infoText: j['info_text'] as String? ?? '',
        active: (j['active'] as List<dynamic>? ?? [])
            .map((e) => ChallengeEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        pendingRewards: (j['pending_rewards'] as List<dynamic>? ?? [])
            .map((e) =>
                PendingChallengeReward.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
