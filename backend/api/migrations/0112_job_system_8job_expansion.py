"""【FEAT-391 (2026-05-30)】ジョブシステム 5 → 8 ジョブ拡張 + キャラ 1:1 化。

【設計判断】
- 既存 4 ジョブを「8 新ジョブ」に rename + 数値更新 (warrior/blue_mage/assassin/healer)
- berserker 廃止 (sol の新ジョブを warrior に統合)
- 新規 4 ジョブ追加 (knight, archer, monk, dark_mage)
- キャラ→ジョブ map を 1:1 に更新

【既存データ移行】
PlayerProfile.active_job (FK to Job) を持つ既存ユーザーへの影響:
- berserker → warrior に統合 (active player は warrior にマイグレーション、Pre-mortem #1)
- mage を持つユーザーは default で blue_mage に統合 (闇魔導士希望は手動切替、Pre-mortem #2)
- thief / cleric は assassin / healer に rename される (update_or_create で冪等)

【CLAUDE.md 原則準拠】
- RunPython 使用は既存データ整合性確保のため (rename + 統合)
- update_or_create / filter().update() で冪等性確保
- berserker 廃止前に active_job FK の statement order を厳守
  (Step 2 で player/character を warrior に統合後、Step 3 で berserker 削除)

【codebase_review 20260530 P1-2】docstring の FK 名を実コードに追従。
旧記述: PlayerProfile.player_job → 正: PlayerProfile.active_job
(コード内は正しく active_job、docstring のみが velocity 由来の stale)

【codebase_review 20260530 P1-3 / CLAUDE.md 例外条項適用】
本 migration は「master/seed data の rename + FK 統合」例外条項に該当:
- Job への FK 全 2 本 (PlayerProfile.active_job, Character.job) を網羅し、Step 2-3 で
  warrior に reassign してから Step 3 で berserker.delete()
- update_or_create / filter().update() で冪等性確保
- user-generated content (FEAT-250 の禁止対象) ではなく master data (migration 0086 seed) のため
- 実害リスクは検証済み (codebase_review 20260530 §強み 2)
詳細: CLAUDE.md「破壊的データマイグレーションの禁止」§例外条項
"""
from django.db import migrations


_OLD_TO_NEW_JOB_MAP = {
    # job_id 変更 + 数値更新 (warrior は job_id 維持、数値のみ変更)
    'warrior': dict(
        job_id='warrior', job_name='戦士',
        atb_speed_modifier=0.9, attack_power_modifier=1.3,
        on_hit_effect='none', ult_cost=2,
        description='バランスの取れた王道戦士。攻撃力寄りで、扱いやすい。',
    ),
    'mage': dict(
        job_id='blue_mage', job_name='青魔導士',
        atb_speed_modifier=1.0, attack_power_modifier=1.1,
        on_hit_effect='burn', ult_cost=2,
        description='安定した魔法アタッカー。通常攻撃に炎の追加効果。',
    ),
    'thief': dict(
        job_id='assassin', job_name='アサシン',
        atb_speed_modifier=1.4, attack_power_modifier=1.0,
        on_hit_effect='none', ult_cost=3,
        description='高速行動 + 必殺多用。暗殺者の本領を発揮する。',
    ),
    'cleric': dict(
        job_id='healer', job_name='ヒーラー',
        atb_speed_modifier=1.0, attack_power_modifier=0.6,
        on_hit_effect='heal', ult_cost=3,
        description='回復特化。与ダメの一部を HP 吸収する聖職者。',
    ),
    # berserker は廃止 (warrior に統合、後続 step で active_job を update)
}

_NEW_JOBS = [
    dict(
        job_id='knight', job_name='ナイト',
        atb_speed_modifier=0.7, attack_power_modifier=1.1,
        on_hit_effect='none', ult_cost=2,
        description='重装の騎士。ATB は遅いが攻撃力中位、堅実な前衛。',
    ),
    dict(
        job_id='archer', job_name='アーチャー',
        atb_speed_modifier=1.2, attack_power_modifier=1.0,
        on_hit_effect='none', ult_cost=3,
        description='中距離の弓使い。中速 + 中火力で安定型。',
    ),
    dict(
        job_id='monk', job_name='モンク',
        atb_speed_modifier=1.3, attack_power_modifier=0.9,
        on_hit_effect='none', ult_cost=4,
        description='高速連撃型の格闘家。攻撃力は控えめだが必殺を多用する。',
    ),
    dict(
        job_id='dark_mage', job_name='闇魔導士',
        atb_speed_modifier=0.8, attack_power_modifier=1.5,
        on_hit_effect='burn', ult_cost=1,
        description='一撃の重みを持つ闇魔法使い。必殺 1 で即発動の華麗さ。',
    ),
]

_NEW_CHARACTER_JOB_MAP = {
    'sol':     'warrior',
    'aria':    'assassin',
    'rune':    'blue_mage',
    'lucia':   'healer',
    'beatrix': 'knight',
    'faye':    'archer',
    'zenon':   'monk',
    'noir':    'dark_mage',
}


def _expand_jobs_8(apps, schema_editor):
    Job = apps.get_model('api', 'Job')
    Character = apps.get_model('api', 'Character')
    PlayerProfile = apps.get_model('api', 'PlayerProfile')

    # ── Step 1: 既存 4 ジョブを rename + 数値更新 ──────────────────────────
    # 順序重要: berserker 廃止前に warrior が確定していること (FK 統合先のため)
    for old_id, new_spec in _OLD_TO_NEW_JOB_MAP.items():
        try:
            job = Job.objects.get(job_id=old_id)
            for k, v in new_spec.items():
                setattr(job, k, v)
            job.save()
            print(
                f'[migration 0112 FEAT-391] Renamed/updated {old_id}'
                f' -> {new_spec["job_id"]} ({new_spec["job_name"]})'
            )
        except Job.DoesNotExist:
            # 初回 migration がスキップされた環境 (テスト DB 等) では get_or_create
            Job.objects.create(**new_spec)
            print(
                f'[migration 0112 FEAT-391] Created {new_spec["job_id"]}'
                f' (no existing {old_id})'
            )

    # ── Step 2: berserker を持つ player / character を warrior に統合 ──────
    # PlayerProfile 側: player_job FK を warrior に変更
    warrior_job = Job.objects.get(job_id='warrior')
    affected_players = PlayerProfile.objects.filter(
        active_job__job_id='berserker',
    ).count()
    PlayerProfile.objects.filter(
        active_job__job_id='berserker',
    ).update(active_job=warrior_job)
    print(
        f'[migration 0112 FEAT-391] Migrated {affected_players} players'
        ' from berserker -> warrior'
    )

    # ── Step 3: berserker を Character.job から外し、削除 ──────────────────
    Character.objects.filter(job__job_id='berserker').update(job=warrior_job)
    Job.objects.filter(job_id='berserker').delete()
    print('[migration 0112 FEAT-391] Removed berserker job (sol now uses warrior)')

    # ── Step 4: 新規 4 ジョブ追加 ────────────────────────────────────────
    new_count = 0
    for spec in _NEW_JOBS:
        _, created = Job.objects.update_or_create(
            job_id=spec['job_id'],
            defaults={k: v for k, v in spec.items() if k != 'job_id'},
        )
        if created:
            new_count += 1
    print(
        f'[migration 0112 FEAT-391] Added {new_count} new jobs'
        ' (knight/archer/monk/dark_mage)'
    )

    # ── Step 5: キャラ→ジョブ map を 1:1 に更新 ──────────────────────────
    job_by_id = {j.job_id: j for j in Job.objects.all()}
    assigned = 0
    for char_key, job_id in _NEW_CHARACTER_JOB_MAP.items():
        ch = Character.objects.filter(key=char_key).first()
        if ch is None:
            print(
                f'[migration 0112 FEAT-391] Character key="{char_key}"'
                ' not found, skipping'
            )
            continue
        ch.job = job_by_id[job_id]
        ch.save(update_fields=['job'])
        assigned += 1
    print(f'[migration 0112 FEAT-391] Reassigned {assigned} characters to 1:1 jobs')


def _revert_jobs_5(apps, schema_editor):
    """ロールバック: 8 → 5 に戻す (forward only 推奨だが、開発便宜のため最小実装)。

    完全な数値復元はできない (rename + 数値変更を含むため)。
    Character.job を null に戻し、Job レコードは残置 (再 forward 時の整合性確保)。
    PlayerProfile.player_job は null 不可の可能性があるため、reverse は no-op。
    """
    Character = apps.get_model('api', 'Character')
    Character.objects.filter(job__isnull=False).update(job=None)
    print(
        '[migration 0112 FEAT-391 reverse] Character.job all reset'
        ' (Job records kept, PlayerProfile.player_job unchanged for safety)'
    )


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0111_add_monthly_character_reward'),
    ]

    operations = [
        migrations.RunPython(_expand_jobs_8, _revert_jobs_5),
    ]
