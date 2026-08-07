"""【FEAT-383 (2026-05-29)】Enemy griffin 追加 seed (hidden_boss tier、Lv 35 解禁)。

PM (要件) セッション 2026-05-29、ユーザー判断「グリフォン画像 (PixelLab Pro 高品質)
が前回 bg_hidden_boss 1 回目生成時のプロンプト違反で偶然得られたため、新規 Enemy
として活用」採択。`mobile/assets/images/battle/enemy_griffin.png` 配置済。

設計:
- tier: hidden_boss (Lv 35 解禁、dragon と並ぶ最高峰)
- コンセプト: 素早い飛行系、物理寄り、魔法弱点
  → JRPG 王道「飛行系 = 素早いが魔法弱点」で戦略性のある選択肢追加
- 既存 dragon (HP 重視、火炎) / ice_witch (魔法重視) / void_dragon (両耐性) と差別化

パラメータ (PM 推奨、FEAT-371 stat 連動境界バランス整合):
- base_hp: 750  (dragon 800 より少なめ、素早さ重視)
- base_atk: 38  (高め)
- base_spd: 13  (既存 10-11 と差別化、ATB 充填速い)
- level_scaling: 2.0 (dragon と同等)
- reward_coins: 80, reward_exp: 150 (hidden_boss 級)
- physical_resistance: 0.85 (物理 -15%、装甲翼)
- magical_resistance: 1.25 (魔法 +25% 弱点、羽毛)
- weak_ult_cost: 4 (thief Critical +30% で「飛行を撃ち落とす」表現)
- unlock_level: 35
- background_image_path: bg_hidden_boss.png (火山、FEAT-381)

冪等: update_or_create で再実行時は更新のみ。
reverse: 削除 (key='griffin' のみ)。
"""
from django.db import migrations


_GRIFFIN_DEFAULTS = {
    'name': 'グリフォン',
    'sprite_key': 'enemy_griffin',
    'base_hp': 750,
    'base_atk': 38,
    'base_spd': 13,
    'level_scaling': 2.0,
    'reward_coins': 80,
    'reward_exp': 150,
    'tier': 'hidden_boss',
    'physical_resistance': 0.85,
    'magical_resistance': 1.25,
    'weak_ult_cost': 4,
    'unlock_level': 35,
    'background_image_path': 'assets/images/backgrounds/battle/bg_hidden_boss.png',
}


def _seed_griffin(apps, schema_editor):
    """griffin Enemy を seed (冪等)。"""
    Enemy = apps.get_model('api', 'Enemy')
    Enemy.objects.update_or_create(
        key='griffin',
        defaults=_GRIFFIN_DEFAULTS,
    )


def _remove_griffin(apps, schema_editor):
    """reverse migration: griffin 削除 (他 Enemy には影響なし)。"""
    Enemy = apps.get_model('api', 'Enemy')
    Enemy.objects.filter(key='griffin').delete()


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0108_enemy_background_image'),
    ]

    operations = [
        migrations.RunPython(_seed_griffin, _remove_griffin),
    ]
