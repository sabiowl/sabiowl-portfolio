"""【FEAT-461 (2026-06-22)】WeaponMaster.tier カラム追加 + 既存武器の backfill。

arch_review 20260622 §2 P2-B 解消: battle.py の _NORMAL_WEAPON_KEYS /
_RARE_WEAPON_KEYS ハードコード tuple を撤廃し、master data (WeaponMaster.tier)
に真実値を移行する。新規武器追加時に migration + battle.py の二重更新が必要だった
drift リスクを構造的に解消する。

--- CLAUDE.md「master/seed data 例外条項」適用 ---
本 migration は RunPython で既存 WeaponMaster レコードを更新する (通常は
「破壊的データマイグレーションの禁止」原則に反するため management command が
原則)。以下 3 条件をすべて満たすため、例外条項を適用して migration 内
RunPython で実施する:

  1. 対象が master/seed data のみ:
     WeaponMaster は migration 0082/0093/0107/0148/0149 で seed された
     カタログテーブルであり、user-generated content は含まない。
  2. 全 FK を Read で網羅:
     WeaponMaster への FK は `PlayerWeapon.weapon` (models/battle.py) の
     1 本のみ。本 migration は WeaponMaster.tier の値を更新するのみで
     WeaponMaster 行自体の削除/PK変更は行わないため、PlayerWeapon 側への
     CASCADE/PROTECT 影響は発生しない。
  3. 冪等性確保:
     `WeaponMaster.objects.filter(key__in=[...]).update(tier=...)` は
     filter+update のため再 apply しても安全 (重複実行で別状態にならない)。

既存 24 武器 (migration 0148 の wood 系 11 + migration 0149 の iron 系 13、
合計 24) を 'normal'/'rare' に、starter_sword (migration 0082) を 'starter' に
backfill する。bronze_sword 等の Shop 専売武器 (migration 0093) は
AddField の default='shop' のまま変更しない。
"""
from django.db import migrations, models


# battle.py の旧 _NORMAL_WEAPON_KEYS (migration 0148 wood 11 種 + migration 0149
# iron_pistol の合計 12 種)。
_NORMAL_KEYS = [
    'wood_sword', 'wood_axe', 'wood_spear', 'wood_knife', 'wood_staff',
    'practice_foil', 'wood_bow', 'hemp_bandage', 'wood_lute', 'glass_flask',
    'wood_scythe', 'iron_pistol',
]

# battle.py の旧 _RARE_WEAPON_KEYS (migration 0149 iron 系 12 種)。
_RARE_KEYS = [
    'iron_small_sword', 'iron_hand_axe', 'iron_thrust_spear', 'iron_dagger',
    'apprentice_grimoire', 'iron_fine_needle', 'iron_short_bow', 'iron_knuckle',
    'hunting_rifle', 'iron_string_harp', 'iron_frame_flask', 'iron_scythe',
]


def _backfill_tier(apps, schema_editor):
    WeaponMaster = apps.get_model('api', 'WeaponMaster')

    n = WeaponMaster.objects.filter(key__in=_NORMAL_KEYS).update(tier='normal')
    print(f'[FEAT-461 migration 0153] Normal tier backfill: {n} 武器')

    r = WeaponMaster.objects.filter(key__in=_RARE_KEYS).update(tier='rare')
    print(f'[FEAT-461 migration 0153] Rare tier backfill: {r} 武器')

    s = WeaponMaster.objects.filter(key='starter_sword').update(tier='starter')
    print(f'[FEAT-461 migration 0153] Starter tier backfill: {s} 武器')


def _reverse_backfill(apps, schema_editor):
    WeaponMaster = apps.get_model('api', 'WeaponMaster')
    WeaponMaster.objects.all().update(tier='shop')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0152_announcement_models'),
    ]

    operations = [
        migrations.AddField(
            model_name='weaponmaster',
            name='tier',
            field=models.CharField(
                choices=[
                    ('starter', 'スターター (オンボーディング配布)'),
                    ('normal', 'Normal (バトル 15% ドロップ)'),
                    ('rare', 'Rare (バトル 10% ドロップ)'),
                    ('shop', 'Shop 購入のみ (ドロップ対象外)'),
                ],
                default='shop',
                help_text='FEAT-461: 武器ドロップ tier 分類 (battle.py が動的取得)',
                max_length=16,
            ),
        ),
        migrations.RunPython(_backfill_tier, _reverse_backfill),
    ]
