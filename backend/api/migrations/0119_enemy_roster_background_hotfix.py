"""【FEAT-401 hotfix (2026-05-31)】新規 12 体の background_image_path 未設定を解消。

ユーザー指摘「新キャラ 12 体に対し、背景が表示されていない」採択。

【真因】
migration 0118_enemy_roster_expansion で seed した新規 12 体 (bat / rat /
skeleton / wolf / ogre / lizard_warrior / dark_knight / fire_demon /
vampire_lord / chimera / lich_king / leviathan) の defaults に
`background_image_path` が含まれず、Django モデル default `''` (空文字) で保存。
Flutter `Enemy.fromJson` line 116 で空文字フォールバック → 戦闘画面で
errorBuilder の AppTheme.background 単色背景 (黒) 表示。

migration 0108 (FEAT-381) は既存 Enemy 全件走査で tier 別 default を適用したが、
migration 0118 以降の新規 Enemy には適用されない one-shot 処理だったため漏れた。

【修正】
本 migration で新規 12 体に tier 別 default 背景を一括適用 (冪等)。
既設定 (非空) はスキップして上書きしない (将来の Enemy 個別 override に配慮)。

【設計】
migration 0108 の _TIER_TO_BG_PATH と完全同じ mapping を使用、tier 別 4 枚汎用
背景 (bg_zako / bg_mid_boss / bg_boss / bg_hidden_boss) を割当。
"""
from django.db import migrations


_TIER_TO_BG_PATH = {
    'zako':        'assets/images/backgrounds/battle/bg_zako.png',
    'mid_boss':    'assets/images/backgrounds/battle/bg_mid_boss.png',
    'boss':        'assets/images/backgrounds/battle/bg_boss.png',
    'hidden_boss': 'assets/images/backgrounds/battle/bg_hidden_boss.png',
}


# migration 0118 で seed した新規 12 体
_NEW_KEYS = [
    'bat', 'rat', 'skeleton', 'wolf',          # zako 4 体
    'ogre', 'lizard_warrior', 'dark_knight',   # mid_boss 3 体
    'fire_demon', 'vampire_lord',              # boss 2 体
    'chimera', 'lich_king', 'leviathan',       # hidden_boss 3 体
]


def _apply_bg_to_new_enemies(apps, schema_editor):
    """新規 12 体に tier 別 background_image_path を割当 (冪等)。"""
    Enemy = apps.get_model('api', 'Enemy')
    updated = 0
    for enemy in Enemy.objects.filter(key__in=_NEW_KEYS):
        if enemy.background_image_path:
            continue  # 既設定 (非空) はスキップ
        bg_path = _TIER_TO_BG_PATH.get(enemy.tier, '')
        if bg_path:
            enemy.background_image_path = bg_path
            enemy.save(update_fields=['background_image_path'])
            updated += 1
            print(f'[migration 0119] {enemy.key} (tier={enemy.tier}) '
                  f'→ {bg_path}')
    print(f'[migration 0119] FEAT-401 hotfix: '
          f'{updated} new enemies got tier-default background.')


def _clear_bg_from_new_enemies(apps, schema_editor):
    """rollback: 新規 12 体の background_image_path を空文字に戻す。"""
    Enemy = apps.get_model('api', 'Enemy')
    Enemy.objects.filter(key__in=_NEW_KEYS).update(background_image_path='')


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0118_enemy_roster_expansion'),
    ]
    operations = [
        migrations.RunPython(_apply_bg_to_new_enemies, _clear_bg_from_new_enemies),
    ]
