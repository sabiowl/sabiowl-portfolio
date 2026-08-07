"""【FEAT-429 (2026-06-12)】Shop 累進価格 (Legendary 枠拡張 / クエスト枠拡張)。

変更内容:
  1. PlayerProfile.legendary_slots_purchase_count — PositiveIntegerField(default=0) 新規追加。
     Legendary 枠拡張の累計購入回数 (累進価格算出用)。
  2. PlayerProfile.daily_battle_limit_bonus — PositiveIntegerField(default=0) 新規追加。
     1 日のクエスト受注枠 (DAILY_BATTLE_LIMIT=10) への bonus (ダイヤ購入分、上限 +5)。
  3. PlayerProfile.daily_battle_limit_purchase_count — PositiveIntegerField(default=0) 新規追加。
     クエスト枠拡張の累計購入回数 (累進価格算出用)。
  4. RunPython backfill — 既存プレイヤーで legendary_slots_bonus > 0 の場合、
     legendary_slots_purchase_count に同値をバックフィルする
     (旧 FEAT-375 の固定 200 ダイヤ購入 = 1 回購入相当として整合性を確保)。

CLAUDE.md「破壊的データマイグレーション禁止」原則:
  AddField のみ + 既存値を減らさない RunPython backfill (F() でコピー、DELETE なし)。
  対象は user-generated data だが「既存値の引き上げ」のみで損失なし。
  reverse は no-op (backfill した purchase_count を 0 に戻す必要はない)。
"""

from django.db import migrations, models


def _backfill_legendary_purchase_count(apps, schema_editor):
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    PlayerProfile.objects.filter(legendary_slots_bonus__gt=0).update(
        legendary_slots_purchase_count=models.F('legendary_slots_bonus')
    )


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0128_5job_5char_expansion'),
    ]

    operations = [
        migrations.AddField(
            model_name='playerprofile',
            name='legendary_slots_purchase_count',
            field=models.PositiveIntegerField(
                default=0,
                verbose_name='Legendary 枠拡張 累計購入回数 (累進価格用)',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='daily_battle_limit_bonus',
            field=models.PositiveIntegerField(
                default=0,
                verbose_name='1 日のクエスト受注枠 ボーナス (ダイヤ購入分)',
            ),
        ),
        migrations.AddField(
            model_name='playerprofile',
            name='daily_battle_limit_purchase_count',
            field=models.PositiveIntegerField(
                default=0,
                verbose_name='クエスト枠拡張 累計購入回数 (累進価格用)',
            ),
        ),
        migrations.RunPython(_backfill_legendary_purchase_count, migrations.RunPython.noop),
    ]
