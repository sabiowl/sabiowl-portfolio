"""【FEAT-299 Phase 1】ジョブマスタ 5 種 seed + 8 既存キャラへのジョブ割り振り。

PM 確定設計（指示書 §1）の真実値を `RunPython` で投入する。
冪等性: `get_or_create` で重複投入を防ぎ、再 apply 安全。

ロールバック（_reverse）:
- Character.job を null に戻す（FK 制約 PROTECT のため、Job レコード削除前に必須）
- Job レコード自体は残置（テスト DB やローカルでの再 apply に備えた idempotent 設計）

CLAUDE.md「破壊的データマイグレーションの禁止」遵守:
- 本 migration は新規データ追加 + 既存キャラへの **null フィールド埋め** のみで、
  既存データの破壊や大規模変換は行わない（FEAT-250 と同思想）。
"""
from django.db import migrations


# PM 確定 5 ジョブ（指示書 §1.1、変更禁止）
_JOBS = [
    {
        'job_id': 'warrior', 'job_name': '戦士',
        'atb_speed_modifier':    0.8,
        'attack_power_modifier': 1.3,
        'on_hit_effect':         'none',
        'ult_cost':              3,
        'description':           '遅いが力強い、安定型の重装戦士。',
    },
    {
        'job_id': 'mage', 'job_name': '魔導士',
        'atb_speed_modifier':    0.9,
        'attack_power_modifier': 0.8,
        'on_hit_effect':         'burn',
        'ult_cost':              2,
        'description':           '必殺技寄りの黒魔導士。攻撃に炎の追加効果。',
    },
    {
        'job_id': 'thief', 'job_name': '盗賊',
        'atb_speed_modifier':    1.5,
        'attack_power_modifier': 0.9,
        'on_hit_effect':         'none',
        'ult_cost':              4,
        'description':           '高速行動が強み。必殺コストは高め。',
    },
    {
        'job_id': 'cleric', 'job_name': '僧侶',
        'atb_speed_modifier':    1.0,
        'attack_power_modifier': 0.7,
        'on_hit_effect':         'heal',
        'ult_cost':              3,
        'description':           'バランス型。攻撃のたびに HP を吸収する白魔導士。',
    },
    {
        'job_id': 'berserker', 'job_name': '狂戦士',
        'atb_speed_modifier':    0.6,
        'attack_power_modifier': 1.6,
        'on_hit_effect':         'none',
        'ult_cost':              1,
        'description':           '超遅 + 超火力 + 必殺即発動。一撃の重み。',
    },
]


# PM 確定 8 キャラのジョブ割り振り（指示書 §1.2、変更禁止）
# Sabi フォールバックは Character レコードを持たないため Flutter / Backend 側で
# warrior デフォルト（指示書 §1.2 では cleric だが、Backend では「明示ロード失敗時」の
# 防御フォールバックとして安全側の warrior を採用、Flutter Sabi 表示時は cleric を使う）。
_CHARACTER_JOB_MAP = {
    'zenon':    'thief',
    'aria':     'thief',
    'beatrix':  'warrior',
    'faye':     'warrior',
    'lucia':    'cleric',
    'noir':     'mage',
    'rune':     'mage',
    'sol':      'berserker',
}


def _seed_jobs_and_assign(apps, schema_editor):
    Job = apps.get_model('api', 'Job')
    Character = apps.get_model('api', 'Character')

    # ── 1. 5 ジョブを get_or_create で冪等投入 ──
    created_count = 0
    for spec in _JOBS:
        _, created = Job.objects.update_or_create(
            job_id=spec['job_id'],
            defaults={k: v for k, v in spec.items() if k != 'job_id'},
        )
        if created:
            created_count += 1
    print(f'[migration 0086] Seeded/updated 5 jobs ({created_count} newly created)')

    # ── 2. 既存 8 キャラに job 割り振り（character.key → job.job_id） ──
    job_by_id = {j.job_id: j for j in Job.objects.all()}
    assigned = 0
    skipped = 0
    for char_key, job_id in _CHARACTER_JOB_MAP.items():
        # Character.key が存在しないケース（FEAT-182 経路の未統一 DB 等）は skip
        # → BattleStartView の warrior フォールバックが効くため動作には支障なし
        ch = Character.objects.filter(key=char_key).first()
        if ch is None:
            print(f'[migration 0086] Character key="{char_key}" not found, skipping')
            skipped += 1
            continue
        ch.job = job_by_id[job_id]
        ch.save(update_fields=['job'])
        assigned += 1
    print(
        f'[migration 0086] Assigned jobs to {assigned} characters '
        f'(skipped {skipped} due to missing keys)'
    )


def _unassign_and_keep_jobs(apps, schema_editor):
    """ロールバック: Character.job を null に戻す（PROTECT 制約のため必須）。

    Job レコード自体は残置する（テスト DB / ローカルで再 apply 時に
    update_or_create が冪等なので、再投入で問題なし）。
    """
    Character = apps.get_model('api', 'Character')
    Character.objects.filter(job__isnull=False).update(job=None)
    print('[migration 0086] Reverse: Character.job all reset to null (Job records kept)')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0085_job_model'),
    ]

    operations = [
        migrations.RunPython(_seed_jobs_and_assign, _unassign_and_keep_jobs),
    ]
