class Achievement {
  final int id;
  final String key;
  final String name;
  final String description;
  final String icon;
  final String conditionType;
  final int conditionValue;
  final int rewardDiamonds;
  final bool unlocked;
  final bool isClaimed;
  final String? unlockedAt;

  const Achievement({
    required this.id,
    required this.key,
    required this.name,
    required this.description,
    required this.icon,
    required this.conditionType,
    required this.conditionValue,
    required this.rewardDiamonds,
    required this.unlocked,
    required this.isClaimed,
    this.unlockedAt,
  });

  factory Achievement.fromJson(Map<String, dynamic> json) => Achievement(
        id:             json['id'] as int,
        key:            json['key'] as String,
        name:           json['name'] as String,
        description:    json['description'] as String,
        icon:           json['icon'] as String,
        conditionType:  json['condition_type'] as String,
        conditionValue: json['condition_value'] as int,
        rewardDiamonds: json['reward_diamonds'] as int,
        unlocked:       json['unlocked'] as bool,
        isClaimed:      json['is_claimed'] as bool,
        unlockedAt:     json['unlocked_at'] as String?,
      );
}

class AchievementsData {
  final List<Achievement> achievements;
  final int unclaimedCount;
  /// 【FEAT-314】 今回の `/achievements/` 取得で新規 unlock した称号があり、
  /// その祝福 +20 ダイヤが付与された場合の合計（複数同時 unlock 時は 20 × N）。
  /// 0 の場合は付与なし、ToastCenter は発火しない。
  final int titleDiamond;

  const AchievementsData({
    required this.achievements,
    required this.unclaimedCount,
    this.titleDiamond = 0,
  });

  factory AchievementsData.fromJson(Map<String, dynamic> json) =>
      AchievementsData(
        achievements: (json['achievements'] as List)
            .map((e) => Achievement.fromJson(e as Map<String, dynamic>))
            .toList(),
        unclaimedCount: json['unclaimed_count'] as int,
        titleDiamond:   json['title_diamond'] as int? ?? 0,
      );
}
