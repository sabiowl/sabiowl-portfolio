/// 【FEAT-511 Phase A (v1.1、2026-07-30)】ジョブ熟練度モデル。
///
/// `GET /api/player/job_masteries/` / `POST /api/battle/finish/` で返却される。
class JobMastery {
  const JobMastery({
    required this.jobId,
    required this.jobName,
    required this.level,
    required this.exp,
    required this.expToNext,
    required this.isMaxed,
    this.expGained = 0,
    this.leveledUpNow = false,
    this.maxedNow = false,
  });

  final String jobId;
  final String jobName;
  final int level;
  final int exp;
  final int expToNext;
  final bool isMaxed;

  /// battle/finish/ レスポンス専用 field (list API では 0/false)。
  final int expGained;
  final bool leveledUpNow;
  final bool maxedNow;

  factory JobMastery.fromJson(Map<String, dynamic> j) {
    return JobMastery(
      jobId:        j['job_id']       as String? ?? '',
      jobName:      j['job_name']     as String? ?? '',
      level:        j['level']        as int?    ?? 1,
      exp:          j['exp']          as int?    ?? 0,
      expToNext:    j['exp_to_next']  as int?    ?? 0,
      isMaxed:      j['is_maxed']     as bool?   ?? false,
      expGained:    j['exp_gained']   as int?    ?? 0,
      leveledUpNow: j['leveled_up_now'] as bool? ?? false,
      maxedNow:     j['maxed_now']    as bool?   ?? false,
    );
  }

  double get expProgress {
    if (isMaxed || expToNext <= 0) return 1.0;
    return (exp / (exp + expToNext)).clamp(0.0, 1.0);
  }
}
