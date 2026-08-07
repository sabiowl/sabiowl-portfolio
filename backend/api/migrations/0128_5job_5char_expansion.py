"""【FEAT-428 (2026-06-12)】5 ジョブ + 5 キャラ追加 (13 ジョブ体制)。

【設計判断】
- 新規 5 ジョブ追加: magic_swordsman(魔法剣士) / bard(吟遊詩人) /
  necromancer(ネクロマンサー) / gunner(ガンナー) / alchemist(錬金術師)
- 新規 5 キャラ追加 (1:1 ジョブ紐付け、FEAT-391 と同じ設計):
  kyle(カイル) / fia(フィア) / irene(イレーネ) / luna(ルナ) / aurum(アウルム)
- 全 5 キャラは price=3000 (SSR 帯、`_CHARACTER_RARITY_PRICE_RANGES['SSR']` =
  (3000, 99999) に合致、migration 0110 の noir 同様の SSR price proxy)
  → マンスリーガチャ SSR 枠 + FEAT-427 キャラ交換チケットの対象に自動で含まれる

【ジョブパラメータ (Pre-mortem S1)】
既存 8 ジョブの値域 (atb_speed_modifier 0.7-1.4 / attack_power_modifier 0.6-1.5) 内に
収め、既存ジョブと完全一致しない組み合わせで差別化:
  - magic_swordsman: atb 1.00 / atk 1.25 / burn / ult 3 (バランス型 + 炎付与)
  - bard:            atb 1.20 / atk 0.70 / heal / ult 3 (高速 + 回復支援)
  - necromancer:     atb 0.80 / atk 1.40 / burn / ult 4 (重撃 + 炎、必殺は重め)
  - gunner:          atb 1.30 / atk 1.10 / none / ult 2 (高速 + 必殺軽量)
  - alchemist:       atb 0.90 / atk 0.80 / heal / ult 4 (回復特化、必殺は重め)

【Character フィールド (Phase 1 着手時に Read で確認済み)】
- `image_path` は識別子のみ (例: 'kyle')。Flutter は
  assets/images/characters/character_kyle.png に解決する。
- `job` は Job への FK (related_name='characters')。本 migration で新規 5 キャラを
  対応する新規 5 ジョブに 1:1 紐付け。
- `order` は既存 0-7 (sol..zenon) の続き 8-12 を採用。

【CLAUDE.md master/seed data 例外条項適用】
- 対象は Job / Character という master/seed data のみ (user-generated content を含まない)
- Character.job への FK は本 migration で新規追加分のみ (既存 8 キャラの job 紐付けは
  migration 0112 で完了済み、本 migration では変更しない)
- update_or_create で冪等性確保 (key / job_id を一意キーとして再 apply 安全)
- forward は新規 5 ジョブ + 5 キャラの追加のみ、既存データへの副作用なし
"""
from django.db import migrations


_NEW_JOBS = [
    dict(
        job_id='magic_swordsman', job_name='魔法剣士',
        atb_speed_modifier=1.00, attack_power_modifier=1.25,
        on_hit_effect='burn', ult_cost=3,
        description='物理と魔法を兼ね備えた剣士。安定した火力に炎の追加効果を添える。',
    ),
    dict(
        job_id='bard', job_name='吟遊詩人',
        atb_speed_modifier=1.20, attack_power_modifier=0.70,
        on_hit_effect='heal', ult_cost=3,
        description='歌声で仲間を支える詩人。素早い行動と回復で粘り強く戦う。',
    ),
    dict(
        job_id='necromancer', job_name='ネクロマンサー',
        atb_speed_modifier=0.80, attack_power_modifier=1.40,
        on_hit_effect='burn', ult_cost=4,
        description='闇の力で敵を蝕む魔導士。一撃は重いが必殺発動はやや遅め。',
    ),
    dict(
        job_id='gunner', job_name='ガンナー',
        atb_speed_modifier=1.30, attack_power_modifier=1.10,
        on_hit_effect='none', ult_cost=2,
        description='遠距離から速射する射手。高速行動で必殺を多用する。',
    ),
    dict(
        job_id='alchemist', job_name='錬金術師',
        atb_speed_modifier=0.90, attack_power_modifier=0.80,
        on_hit_effect='heal', ult_cost=4,
        description='薬と科学で戦況を覆す賢者。回復特化で必殺発動はやや遅め。',
    ),
]

_NEW_CHARACTERS = [
    dict(
        key='kyle', name='カイル', job_id='magic_swordsman',
        role='魔法剣士', description='物理と魔法を両立する剣士。',
        image_path='kyle', price=3000, unlock_level=20, is_starter=False, order=8,
    ),
    dict(
        key='fia', name='フィア', job_id='bard',
        role='吟遊詩人', description='歌声で仲間を支える詩人。',
        image_path='fia', price=3000, unlock_level=20, is_starter=False, order=9,
    ),
    dict(
        key='irene', name='イレーネ', job_id='necromancer',
        role='ネクロマンサー', description='闇の力で敵を蝕む魔導士。',
        image_path='irene', price=3000, unlock_level=20, is_starter=False, order=10,
    ),
    dict(
        key='luna', name='ルナ', job_id='gunner',
        role='ガンナー', description='遠距離から速射する射手。',
        image_path='luna', price=3000, unlock_level=20, is_starter=False, order=11,
    ),
    dict(
        key='aurum', name='アウルム', job_id='alchemist',
        role='錬金術師', description='薬と科学で戦況を覆す賢者。',
        image_path='aurum', price=3000, unlock_level=20, is_starter=False, order=12,
    ),
]

_NEW_JOB_IDS = [spec['job_id'] for spec in _NEW_JOBS]
_NEW_CHARACTER_KEYS = [spec['key'] for spec in _NEW_CHARACTERS]


def _seed_5job_5char(apps, schema_editor):
    Job = apps.get_model('api', 'Job')
    Character = apps.get_model('api', 'Character')

    # ── Step 1: 新規 5 ジョブを追加 ──────────────────────────────────────
    job_created = 0
    for spec in _NEW_JOBS:
        _, created = Job.objects.update_or_create(
            job_id=spec['job_id'],
            defaults={k: v for k, v in spec.items() if k != 'job_id'},
        )
        if created:
            job_created += 1
    print(f'[migration 0128 FEAT-428] Added {job_created} new jobs (5 想定)')

    # ── Step 2: 新規 5 キャラを追加 + 1:1 ジョブ紐付け ──────────────────────
    job_by_id = {j.job_id: j for j in Job.objects.filter(job_id__in=_NEW_JOB_IDS)}
    char_created = 0
    for spec in _NEW_CHARACTERS:
        job_id = spec['job_id']
        defaults = {k: v for k, v in spec.items() if k not in ('key', 'job_id')}
        defaults['job'] = job_by_id[job_id]
        _, created = Character.objects.update_or_create(
            key=spec['key'],
            defaults=defaults,
        )
        if created:
            char_created += 1
    print(f'[migration 0128 FEAT-428] Added {char_created} new characters (5 想定)')


def _reverse_5job_5char(apps, schema_editor):
    Job = apps.get_model('api', 'Job')
    Character = apps.get_model('api', 'Character')

    Character.objects.filter(key__in=_NEW_CHARACTER_KEYS).delete()
    Job.objects.filter(job_id__in=_NEW_JOB_IDS).delete()
    print('[migration 0128 FEAT-428 reverse] Removed 5 new characters and 5 new jobs')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0127_character_exchange_tickets'),
    ]

    operations = [
        migrations.RunPython(_seed_5job_5char, _reverse_5job_5char),
    ]
