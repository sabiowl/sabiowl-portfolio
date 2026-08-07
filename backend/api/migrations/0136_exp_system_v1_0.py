"""【FEAT-434 (2026-06-14)】EXP システム v1.0 移行。

変更内容:
  1. 既存 `Habit.difficulty='legendary'` を `'normal'` に backfill。
     (Habit (count/checklist) の Legendary 難易度は v1.0 で UI から消えるため、
     既存データが「ハード」より上の表示として残ると一覧表示が崩れる。
     field 自体は維持 (案 i 採択、ToDo 経路は引き続き 'legendary' を使う)。
  2. `PlayerProfile.legendary_slots_purchase_count > 0` のユーザーに、
     累進価格 (200 + 400 + ... + N*200 = `200 * N * (N+1) // 2`) 分のダイヤを返金、
     `legendary_slots_bonus` / `legendary_slots_purchase_count` を 0 にリセット。

【CLAUDE.md 1 回限り例外条項 (FEAT-370 系) 準用】
  - 対象は user-generated content (Habit.difficulty / PlayerProfile.diamonds 等) だが、
    「Habit 難易度廃止 = Legendary 枠制限も廃止」という構造変更に伴う 1 回限りの
    補償的変換であり、再現性のあるテスト DB では対象 0 件 = no-op になる設計。
  - Render Free プランから Starter プランへの移行 (FEAT-402) 後も Shell アクセス可否は
    未確認のため、安全側で migration 内 RunPython として実装する。
  - 並行維持 management command として `cleanup_legendary_refund.py` を作成済み
    (別環境で migration 外から再実行したい場合に利用可能)。
  - 冪等性 (Pre-mortem S2): `legendary_slots_purchase_count` を 0 にリセットするため、
    2 回目以降の apply は `filter(legendary_slots_purchase_count__gt=0)` が 0 件になり
    no-op (二重返金は発生しない)。
"""

from django.db import migrations


def _migrate_habit_legendary_to_normal(apps, schema_editor):
    Habit = apps.get_model('api', 'Habit')
    Habit.objects.filter(difficulty='legendary').update(difficulty='normal')


def _refund_legendary_purchases(apps, schema_editor):
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    for player in PlayerProfile.objects.filter(legendary_slots_purchase_count__gt=0):
        n = player.legendary_slots_purchase_count
        # 累進価格: 200 + 400 + ... + n*200 = 200 * n*(n+1)/2
        refund = 200 * n * (n + 1) // 2
        player.diamonds += refund
        player.legendary_slots_bonus = 0
        player.legendary_slots_purchase_count = 0
        player.save(update_fields=[
            'diamonds', 'legendary_slots_bonus', 'legendary_slots_purchase_count',
        ])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0135_weekly_diamond_icon_unify'),
    ]

    operations = [
        migrations.RunPython(_migrate_habit_legendary_to_normal, migrations.RunPython.noop),
        migrations.RunPython(_refund_legendary_purchases, migrations.RunPython.noop),
    ]
