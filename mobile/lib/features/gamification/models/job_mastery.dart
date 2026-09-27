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

  /// **現在の Lv 内での進捗 EXP** (累計ではない)。
  ///
  /// Backend は Lv アップのたびに必要量を差し引く
  /// (`battle_finish_service.py`: `mastery.exp -= calc_job_mastery_exp_to_next(...)`)
  /// ため、常に `0 <= exp < expToNext` の範囲に収まる。
  final int exp;

  /// 🔴 **現在の Lv を突破するのに必要な EXP の「総量」**。**残量ではない。**
  ///
  /// Backend が返すのは `calc_job_mastery_exp_to_next(level)` = `Lv²×2 + Lv×4 + 4`
  /// そのもので、**すでに貯めた [exp] は引かれていない**
  /// (`views/job_mastery.py` / `services/battle_finish_service.py`)。
  ///
  /// 名前が「to next」なので**残量と読み間違えやすい**。実際 2026-08-09 まで
  /// [expProgress] が `exp / (exp + expToNext)` と書かれており、
  /// Lv 1 で 1 勝した状態 (exp=5, expToNext=10) のバーが **50% ではなく 33%**
  /// を指していた。表示文言も「あと 10 EXP」(正しくは 5) と出ていた。
  ///
  /// 残量が欲しい場合は **`expToNext - exp`** で求めること。
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

  /// バーの進捗率 (0.0 - 1.0)。
  ///
  /// 【2026-08-09 修正】旧: `exp / (exp + expToNext)`。
  /// [expToNext] を**残量**と誤解した式で、実際は総量なので分母が二重に
  /// 膨らんでいた (exp=5 / expToNext=10 で 33%、正しくは 50%)。
  double get expProgress {
    if (isMaxed || expToNext <= 0) return 1.0;
    return (exp / expToNext).clamp(0.0, 1.0);
  }

  /// 次の Lv までの残り EXP。表示に使うならこちら。
  int get expRemaining => isMaxed ? 0 : (expToNext - exp).clamp(0, expToNext);
}
