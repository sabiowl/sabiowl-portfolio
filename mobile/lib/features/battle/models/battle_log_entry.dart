/// 【FEAT-305】Backend `GET /api/battle/logs/` の 1 件分エントリ。
///
/// リリア（ギルド受付）が「直近 5 分以内の勝敗」を判定するために使用する。
/// FEAT-305 Phase 1 で Backend は `result` + `finished_at` を返すよう拡張済。
class BattleLogEntry {
  const BattleLogEntry({
    required this.battleId,
    required this.enemyName,
    required this.result,
    required this.summaryText,
    required this.rounds,
    required this.rewardsCoins,
    required this.rewardsExp,
    required this.totalDamageDealt,
    required this.totalDamageTaken,
    required this.createdAt,
    this.finishedAt,
  });

  /// `Battle.id`。
  final int battleId;

  /// 表示用敵名。
  final String enemyName;

  /// `'win'` / `'lose'` / `'abandon'` / null（未確定）。
  final String? result;

  /// バトルログ要約文（複数行）。
  final String summaryText;

  final int rounds;
  final int rewardsCoins;
  final int rewardsExp;
  final int totalDamageDealt;
  final int totalDamageTaken;

  /// BattleLog 作成時刻 = ほぼ Battle 終了時刻と同等。
  final DateTime createdAt;

  /// 【FEAT-305】Battle.finished_at（BattleFinishView 書き込み）。
  /// リリアの `victory_just_now` / `defeat_just_now` 判定で「5 分以内」を測る。
  /// null = まだ進行中（通常 logs に出ない想定だが防御）。
  final DateTime? finishedAt;

  bool get isWin => result == 'win';
  bool get isLose => result == 'lose';

  factory BattleLogEntry.fromJson(Map<String, dynamic> json) {
    DateTime parseIso(String? raw, DateTime fallback) {
      if (raw == null || raw.isEmpty) return fallback;
      return DateTime.tryParse(raw) ?? fallback;
    }

    final created = parseIso(
      json['created_at'] as String?,
      DateTime.fromMillisecondsSinceEpoch(0),
    );
    DateTime? finished;
    final finishedRaw = json['finished_at'] as String?;
    if (finishedRaw != null && finishedRaw.isNotEmpty) {
      finished = DateTime.tryParse(finishedRaw);
    }

    return BattleLogEntry(
      battleId:         json['battle_id'] as int? ?? 0,
      enemyName:        json['enemy_name'] as String? ?? '',
      result:           json['result'] as String?,
      summaryText:      json['summary_text'] as String? ?? '',
      rounds:           json['rounds'] as int? ?? 0,
      rewardsCoins:     json['rewards_coins'] as int? ?? 0,
      rewardsExp:       json['rewards_exp'] as int? ?? 0,
      totalDamageDealt: json['total_damage_dealt'] as int? ?? 0,
      totalDamageTaken: json['total_damage_taken'] as int? ?? 0,
      createdAt:        created,
      finishedAt:       finished,
    );
  }
}
