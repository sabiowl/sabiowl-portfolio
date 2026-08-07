"""【FEAT-381 (2026-05-29)】Enemy.background_image_path 追加 + tier 別汎用背景 seed。

PM (要件) セッション 2026-05-29、ユーザー要望「受注したクエストに合わせて背景を変えた
状態で戦闘を開始し、終わったら元に戻したい」を採択、案 B Tier 別汎用 (4 枚) で実装。

設計:
- tier (zako/mid_boss/boss/hidden_boss) で 4 枚汎用背景を共有
- Enemy 個別 override も可能 (将来拡張余地)
- 画像欠落時は Flutter 側 errorBuilder で AppTheme.background 単色フォールバック
- 「終わったら元に戻す」処理は Navigator.pop で自動 (戦闘画面は独立 Scaffold)

tier 別 default path:
- zako (goblin, giant_slime, young_orc 等): assets/images/backgrounds/battle/bg_zako.png
- mid_boss (Lv 15 解禁): assets/images/backgrounds/battle/bg_mid_boss.png
- boss (goblin_king, shadow_mage, Lv 25 解禁): assets/images/backgrounds/battle/bg_boss.png
- hidden_boss (dragon 等、Lv 35 解禁): assets/images/backgrounds/battle/bg_hidden_boss.png

画像ファイル自体はユーザーが PixelLab Free で別途調達して配置。
画像未配置でも本 migration は安全 (Flutter errorBuilder でフォールバック)。
"""
from django.db import migrations, models


_TIER_TO_BG_PATH = {
    'zako':        'assets/images/backgrounds/battle/bg_zako.png',
    'mid_boss':    'assets/images/backgrounds/battle/bg_mid_boss.png',
    'boss':        'assets/images/backgrounds/battle/bg_boss.png',
    'hidden_boss': 'assets/images/backgrounds/battle/bg_hidden_boss.png',
}


def _seed_tier_backgrounds(apps, schema_editor):
    """既存 Enemy に tier 別の background_image_path をデフォルト割当。

    冪等: 既に background_image_path が設定済 (非空) の Enemy はスキップ。
    """
    Enemy = apps.get_model('api', 'Enemy')
    for enemy in Enemy.objects.all():
        if enemy.background_image_path:
            continue  # 既設定はスキップ (冪等)
        bg_path = _TIER_TO_BG_PATH.get(enemy.tier, '')
        if bg_path:
            enemy.background_image_path = bg_path
            enemy.save(update_fields=['background_image_path'])


def _clear_tier_backgrounds(apps, schema_editor):
    """reverse migration: 全 Enemy の background_image_path を空文字に戻す。"""
    Enemy = apps.get_model('api', 'Enemy')
    Enemy.objects.all().update(background_image_path='')


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0107_weapon_sockets'),
    ]

    operations = [
        migrations.AddField(
            model_name='enemy',
            name='background_image_path',
            field=models.CharField(
                blank=True, default='', max_length=128,
                help_text='FEAT-381: 戦闘画面背景画像 asset path (空=背景なし)',
            ),
        ),
        migrations.RunPython(_seed_tier_backgrounds, _clear_tier_backgrounds),
    ]
