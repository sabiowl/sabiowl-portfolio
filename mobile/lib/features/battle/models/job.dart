/// 【FEAT-299】ジョブマスタの Flutter モデル。
///
/// Backend `Job` (`backend/api/models/battle.py`) と整合。
/// `BattleStartResponse.playerJob` で受け取り、`Combatant` の修飾子に反映する。
///
/// **マスタデータ駆動設計**: ハードコードした定数は持たない。
/// Backend の seed (migration 0086) が真実値。
class Job {
  const Job({
    required this.jobId,
    required this.jobName,
    required this.atbSpeedModifier,
    required this.attackPowerModifier,
    required this.onHitEffect,
    required this.ultCost,
  });

  /// Backend `Job.job_id` (例: 'warrior', 'mage', 'thief', 'cleric', 'berserker')。
  final String jobId;

  /// 表示名（例: '戦士', '魔導士'）。
  final String jobName;

  /// ATB ゲージ充填速度倍率。0.6 (狂戦士) 〜 1.5 (盗賊)。
  final double atbSpeedModifier;

  /// 攻撃力倍率。0.7 (僧侶) 〜 1.6 (狂戦士)。
  final double attackPowerModifier;

  /// 攻撃時の追加効果。`'none'` / `'burn'` / `'heal'` のいずれか。
  /// - `burn`: 敵 HP に `max_hp × 0.02 × 3` を即時加算（DoT 風、Pre-mortem #3 で簡略化）
  /// - `heal`: 自分の HP を `damage_dealt × 0.10` 回復（吸収）
  final String onHitEffect;

  /// 大技解放に必要な「ゲージ満タン保留」回数。
  /// 1 (狂戦士、即発動) 〜 4 (盗賊、高コスト)。
  final int ultCost;

  /// Backend `_serialize_job` の JSON 形式から生成。
  /// 必須キー欠落は `FormatException` で fail-fast（API スキーマ変更検知）。
  factory Job.fromJson(Map<String, dynamic> json) {
    final id = json['job_id'] as String?;
    if (id == null || id.isEmpty) {
      throw const FormatException('Job.fromJson: missing job_id');
    }
    return Job(
      jobId:               id,
      jobName:             json['job_name'] as String? ?? id,
      atbSpeedModifier:    (json['atb_speed_modifier']    as num?)?.toDouble() ?? 1.0,
      attackPowerModifier: (json['attack_power_modifier'] as num?)?.toDouble() ?? 1.0,
      onHitEffect:         json['on_hit_effect'] as String? ?? 'none',
      ultCost:             json['ult_cost'] as int? ?? 3,
    );
  }

  /// 【FEAT-391 (2026-05-30)】8 ジョブ拡張後の warrior フォールバック。
  ///
  /// Sabi 等の Character なし combatant / Player ロード失敗時に使用する安全側の値。
  /// warrior (バランス型) を採用し、Backend migration 0112 の seed 値と整合させている。
  ///
  /// 注: Backend `_serialize_job(None)` は既存挙動互換で modifier=1.0 を返すが、
  /// Flutter 側の fallback は「actual warrior の数値」として更新済み。
  /// この値は party_edit_dialog の _StatusSection 表示と battle_provider の
  /// Combatant 構築に使用される (BattleDisplay ヘルパー経由、FEAT-390)。
  /// 【FEAT-489 Phase 2E — 意図的に ARB 化しない / PM 判断待ち】
  ///
  /// 通常経路の `jobName` は Backend `Job.job_name` (master data) が唯一の真実値で、
  /// **Backend 側に `job_name_en` が無い** (`backend/api/models/battle.py:45`、
  /// Phase 4 の `_en` field 追加から漏れている)。そのため英語 locale でも API は
  /// 常に日本語を返す。
  ///
  /// ここ (fallback const) だけを ARB 化すると、通常経路は「戦士」・fallback 経路は
  /// 「Warrior」という **画面内 2 言語混在** になり、Pre-mortem S5 と同じ失敗になる。
  /// 恒久対応は Backend への `job_name_en` 追加 (deploy 順序の管理が要る) のため、
  /// handoff §2.4 の指示どおり実装せず PM に報告する。
  static const Job fallback = Job(
    jobId:               'warrior',
    jobName:             '戦士',
    atbSpeedModifier:    0.9,    // 【FEAT-391】warrior 新値 (旧 0.8 → 0.9)
    attackPowerModifier: 1.3,    // 【FEAT-391】warrior 維持 (1.3)
    onHitEffect:         'none',
    ultCost:             2,      // 【FEAT-391】warrior 新値 (旧 3 → 2)
  );

  @override
  String toString() => '$jobName($jobId, atb×$atbSpeedModifier, '
      'atk×$attackPowerModifier, on_hit=$onHitEffect, ult=$ultCost)';
}
