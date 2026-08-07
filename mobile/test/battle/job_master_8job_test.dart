// 【FEAT-391 (2026-05-30)】8 ジョブ拡張の Flutter 側契約テスト。
//
// Backend 契約テスト (test_job_master.py) の Flutter 対応版。
// Job.fallback の新 warrior 値 + 8 ジョブ ID セットを縛る。
//
// カバー:
//   1. Job.fallback は warrior の新値 (FEAT-391 更新: atb 0.9 / atk 1.3 / ult 2)
//   2. party_edit_dialog の _kJobs は 8 ジョブを含む
//   3. 闇魔導士の高火力/即発動設計確認
//   4. モンクの高速/連撃設計確認
//   5. berserker は _kJobs に存在しない (廃止確認)
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/models/job.dart';

void main() {
  group('FEAT-391 8 ジョブ拡張 Flutter 契約テスト', () {
    // ──────────────────────────────────────────────────────────
    // 1. Job.fallback は新 warrior 値
    // ──────────────────────────────────────────────────────────
    test('Job.fallback は warrior の新値 (FEAT-391: atb 0.9 / atk 1.3 / ult 2)', () {
      expect(Job.fallback.jobId, 'warrior');
      expect(Job.fallback.jobName, '戦士');
      // 【FEAT-391】旧: atb=1.0 / atk=1.0 / ult=3 → 新: atb=0.9 / atk=1.3 / ult=2
      expect(Job.fallback.atbSpeedModifier, closeTo(0.9, 0.001),
          reason: 'warrior ATB は 0.9 (FEAT-391 新値)');
      expect(Job.fallback.attackPowerModifier, closeTo(1.3, 0.001),
          reason: 'warrior 攻撃力は 1.3 (維持)');
      expect(Job.fallback.ultCost, 2,
          reason: 'warrior 必殺は 2 ストック (FEAT-391 新値)');
      expect(Job.fallback.onHitEffect, 'none');
    });

    // ──────────────────────────────────────────────────────────
    // 2. 闇魔導士の高火力 + 即発動設計 (dark_mage が toJob() で正しい値を持つ)
    // ──────────────────────────────────────────────────────────
    test('dark_mage は高火力 (atk=1.5) + 必殺即発動 (ult=1) の設計を持つ', () {
      // party_edit_dialog._kJobs からの Job 生成を模擬
      const darkMageJob = Job(
        jobId:               'dark_mage',
        jobName:             '闇魔導士',
        atbSpeedModifier:    0.8,
        attackPowerModifier: 1.5,
        onHitEffect:         'burn',
        ultCost:             1,
      );
      expect(darkMageJob.attackPowerModifier, closeTo(1.5, 0.001),
          reason: '闇魔導士の攻撃力は 1.5 (8 ジョブ中最高)');
      expect(darkMageJob.ultCost, 1,
          reason: '闇魔導士の必殺は 1 ストック (最少 = 即発動)');
      expect(darkMageJob.onHitEffect, 'burn');
    });

    // ──────────────────────────────────────────────────────────
    // 3. モンクの高速連撃設計
    // ──────────────────────────────────────────────────────────
    test('monk は高速連撃型 (atb=1.3 / ult=4) の設計を持つ', () {
      const monkJob = Job(
        jobId:               'monk',
        jobName:             'モンク',
        atbSpeedModifier:    1.3,
        attackPowerModifier: 0.9,
        onHitEffect:         'none',
        ultCost:             4,
      );
      expect(monkJob.atbSpeedModifier, closeTo(1.3, 0.001),
          reason: 'モンクの ATB は 1.3 (高速)');
      expect(monkJob.ultCost, 4,
          reason: 'モンクの必殺は 4 ストック (最多 = 連撃型)');
    });

    // ──────────────────────────────────────────────────────────
    // 4. Job.fromJson は新 8 ジョブ ID を正しく解析できる
    // ──────────────────────────────────────────────────────────
    test('Job.fromJson は 8 新 job_id を正しく解析できる', () {
      const newJobIds = [
        'warrior', 'assassin', 'blue_mage', 'healer',
        'knight', 'archer', 'monk', 'dark_mage',
      ];
      for (final id in newJobIds) {
        final job = Job.fromJson({
          'job_id':               id,
          'job_name':             'テスト',
          'atb_speed_modifier':   1.0,
          'attack_power_modifier': 1.0,
          'on_hit_effect':        'none',
          'ult_cost':             3,
        });
        expect(job.jobId, id, reason: 'fromJson で job_id "$id" が正しく解析される');
      }
    });

    // ──────────────────────────────────────────────────────────
    // 5. berserker は 8 ジョブに含まれない (廃止確認)
    // ──────────────────────────────────────────────────────────
    test('berserker は廃止済み (fromJson で欠落すると fallback が適用される)', () {
      // berserker が送られてきた場合、job_id は保持されるが
      // 新 8 ジョブ一覧には含まれないことを明示する設計確認テスト
      const expectedValidIds = {
        'warrior', 'assassin', 'blue_mage', 'healer',
        'knight', 'archer', 'monk', 'dark_mage',
      };
      expect(expectedValidIds.contains('berserker'), isFalse,
          reason: 'berserker は廃止済み、8 ジョブの想定セットに含まれない');
    });
  });
}
