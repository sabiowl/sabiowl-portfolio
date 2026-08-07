"""【FEAT-222】「ガチャ中毒」を「ガチャの探求」に改名。

CLAUDE.md「サビの口調ルール」(穏やかな丁寧体、煽り・依存語の禁止)に従い、
依存的なトーンの「中毒」を、Sabiowl 哲学「積み上げの思想」と整合する
「探求」に書き換える。Sabi が「アプリの声」として発するメッセージの一部
として、Achievement.name も同じトーンで揃える方針。

key='gacha_10' のレコードは migration 0028_achievement で seed 済み。
本マイグレーションでは name フィールドのみ上書きし、reward_diamonds /
condition_value / icon 等は不変。`PlayerAchievement`(解除済みレコード)
への影響もなし(FK 経由で参照されるため、API レスポンスで自動的に新名称が反映される)。

依存先: SEC-10 の 0067_drop_quest_models(Quest テーブル drop)。
SEC-10 が未適用の環境ではこの番号は前後する可能性あり。
"""

from django.db import migrations


def rename_gacha_addiction(apps, schema_editor):
    Achievement = apps.get_model('api', 'Achievement')
    Achievement.objects.filter(key='gacha_10').update(name='ガチャの探求')


def reverse_rename(apps, schema_editor):
    Achievement = apps.get_model('api', 'Achievement')
    Achievement.objects.filter(key='gacha_10').update(name='ガチャ中毒')


class Migration(migrations.Migration):
    dependencies = [
        ('api', '0067_drop_quest_models'),
    ]
    operations = [
        migrations.RunPython(rename_gacha_addiction, reverse_rename),
    ]
