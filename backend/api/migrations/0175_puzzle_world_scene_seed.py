"""【FEAT-479 (2026-07-06)】ジグソーパズル世界 3 シーン seed。

指示書: `doc/instructions/FEAT-479_puzzle_world_ver1.md` §3.5

## CLAUDE.md master/seed data 例外条項適用

「破壊的データマイグレーション禁止」原則の例外として、以下 3 条件を満たすため
migration 内 RunPython で seed する:

1. **対象が master/seed data のみ**: PuzzleWorldScene の 3 レコード新規挿入のみ
   (user-generated content 破壊なし)
2. **FK 全網羅**: 挿入時点で PuzzleWorldScene への FK は
   `PlayerPuzzleWorld.active_scene` / `.displayed_scene` /
   `PlayerPuzzleSceneProgress.scene` / `PlayerPuzzleWorldHistory.scene` の 4 本、
   いずれも `null=True` or 未使用 (0174 の直後、user データ 0 件) のため FK 影響なし
3. **冪等性**: `update_or_create(key=..., defaults={...})` で再 apply 安全

Sabi 口調台詞は指示書 §3.5 の 3 台詞をそのまま採用 (「〜ですね 🪶」統一)。
"""
from django.db import migrations


SEED_SCENES = [
    {
        'key':             'morning_grassland',
        'name':            '朝の草原',
        'display_order':   1,
        'piece_count':     30,
        'background_key':  'morning_grassland',
        'is_active':       True,
        'reward_exp':      1000,
        'reward_diamonds': 500,
        'tagline':         '静けさが染み渡る、朝の景色ですね 🪶',
    },
    {
        'key':             'noon_castle_town',
        'name':            '昼の城下町',
        'display_order':   2,
        'piece_count':     30,
        'background_key':  'noon_castle_town',
        'is_active':       True,
        'reward_exp':      1000,
        'reward_diamonds': 500,
        'tagline':         '賑わいが目を覚ましてゆく街ですね 🪶',
    },
    {
        'key':             'night_forest_camp',
        'name':            '夜の森キャンプ',
        'display_order':   3,
        'piece_count':     30,
        'background_key':  'night_forest_camp',
        'is_active':       True,
        'reward_exp':      1000,
        'reward_diamonds': 500,
        'tagline':         '焚き火のそばで、ひと息つく夜ですね 🪶',
    },
]


def seed_puzzle_scenes(apps, schema_editor):
    Scene = apps.get_model('api', 'PuzzleWorldScene')
    for s in SEED_SCENES:
        Scene.objects.update_or_create(
            key=s['key'],
            defaults={k: v for k, v in s.items() if k != 'key'},
        )


def unseed_puzzle_scenes(apps, schema_editor):
    Scene = apps.get_model('api', 'PuzzleWorldScene')
    Scene.objects.filter(key__in=[s['key'] for s in SEED_SCENES]).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0174_puzzle_world_models'),
    ]

    operations = [
        migrations.RunPython(seed_puzzle_scenes, unseed_puzzle_scenes),
    ]
