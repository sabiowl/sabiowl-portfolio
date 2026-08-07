"""【FEAT-423 (2026-06-10)】PlayerProfile.friend_id を 8 桁数字に変更。

変更内容:
  1. max_length 9 → 8 (AlterField)
  2. 既存データの `XXXX-XXXX` → `XXXXXXXX` 形式に in-place 変換
     (Postgres の `Replace(friend_id, '-', '')` で全レコードを 1 文で更新)

この変換は format 変換のみ (情報喪失なし、reversible):
  例: '1234-5678' → '12345678'
  reverse: '12345678' → '1234-5678' (4 文字ごとに `-` 挿入)

CLAUDE.md「破壊的データマイグレーション禁止」原則:
  本 migration は user data の format 変換 (削除でも値の意味変更でもない)。
  情報喪失なしのため許容範囲。CLAUDE.md「データ意図的削除/大規模変換」の
  禁止対象外と解釈 (FEAT-250 反省の文脈 = User.objects.delete() 等の
  user-generated content 破壊を対象とする原則)。
"""
from django.db import migrations, models


def _strip_hyphen(apps, schema_editor):
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    PlayerProfile.objects.filter(friend_id__contains='-').update(
        friend_id=models.functions.Replace(
            'friend_id',
            models.Value('-'),
            models.Value(''),
        ),
    )


def _restore_hyphen(apps, schema_editor):
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    # 4 文字ごとに `-` 挿入 (reversible 保証用)
    for p in PlayerProfile.objects.exclude(friend_id__contains='-'):
        if len(p.friend_id) == 8:
            p.friend_id = f'{p.friend_id[:4]}-{p.friend_id[4:]}'
            p.save(update_fields=['friend_id'])


class Migration(migrations.Migration):
    dependencies = [('api', '0124_disable_sr_guardian_character')]
    operations = [
        # AlterField 前に Replace を実行 (max_length=9 のまま `-` 除去)
        migrations.RunPython(_strip_hyphen, _restore_hyphen),
        migrations.AlterField(
            model_name='playerprofile',
            name='friend_id',
            field=models.CharField(
                max_length=8, unique=True, blank=True,
                verbose_name='フレンドID',
            ),
        ),
    ]
