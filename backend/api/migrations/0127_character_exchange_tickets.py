"""【FEAT-427 (2026-06-11)】マンスリー天井をキャラ交換券 (ユーザー選択) に変更。

変更内容:
  1. PlayerProfile.character_exchange_tickets — PositiveIntegerField(default=0) を新規追加。
     マンスリー天井 (10 回目) で +1 され、ユーザーが好きな SSR キャラと交換できる。
     既存データへの変更なし (AddField only = 破壊的操作なし)。
  2. GachaReward.ticket_type — max_length=10 → 16 に拡張 ('monthly_pity' は 12 文字のため)。
     choices に ('monthly_pity', 'マンスリー天井') を追加。
  3. GachaReward.reward_type — choices に ('character_ticket', 'キャラ交換券') を追加
     (max_length=20 のまま、'character_ticket' は 17 文字で収まる)。
  4. master/seed data 例外条項 (CLAUDE.md) 適用: GachaReward に
     ticket_type='monthly_pity', reward_type='character_ticket', weight=0 の
     擬似報酬 (天井専用、通常の weight 抽選プールには混入しない) を
     update_or_create で追加する。

CLAUDE.md「破壊的データマイグレーション禁止」原則:
  AddField / AlterField + update_or_create による seed のみ。DELETE なし。
  対象は GachaReward master/seed data のみ (user-generated content 含まない)。
  FK 走査: GachaHistory.reward / PendingDuplicateReward.reward → GachaReward
  本 migration は新規 row 追加のみ → CASCADE/PROTECT 影響なし。
  冪等性: update_or_create で再 apply 安全。
"""

from django.db import migrations, models


def _seed_pity_reward(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.update_or_create(
        ticket_type='monthly_pity',
        reward_type='character_ticket',
        defaults={
            'rarity':       'SSR',
            'container':    'stone',
            'name':         'キャラ交換券 (SSR)',
            'detail':       'お好きな SSR キャラを 1 体お選びいただけますよ',
            'icon':         '🎟️',
            'weight':       0,  # 天井専用 = weight 抽選プールに入れない
            'value':        0,
        },
    )


def _remove_pity_reward(apps, schema_editor):
    GachaReward = apps.get_model('api', 'GachaReward')
    GachaReward.objects.filter(
        ticket_type='monthly_pity',
        reward_type='character_ticket',
    ).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0126_google_event_completion'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='character_exchange_tickets',
            field=models.PositiveIntegerField(
                default=0,
                verbose_name='キャラ交換券',
            ),
        ),
        migrations.AlterField(
            model_name='gachareward',
            name='ticket_type',
            field=models.CharField(
                max_length=16,
                choices=[
                    ('daily', 'デイリー'),
                    ('weekly', 'ウィークリー'),
                    ('monthly', 'マンスリー'),
                    ('monthly_pity', 'マンスリー天井'),
                ],
                default='daily',
                verbose_name='対応チケット種別',
            ),
        ),
        migrations.AlterField(
            model_name='gachareward',
            name='reward_type',
            field=models.CharField(
                max_length=20,
                choices=[
                    ('exp', '経験値'),
                    ('diamond', 'ダイヤ'),
                    ('xp_boost', 'XPブースト'),
                    ('title', '称号'),
                    ('character', 'キャラクター'),
                    ('weapon', '武器'),
                    ('character_ticket', 'キャラ交換券'),
                ],
                verbose_name='報酬種別',
            ),
        ),
        migrations.RunPython(_seed_pity_reward, _remove_pity_reward),
    ]
