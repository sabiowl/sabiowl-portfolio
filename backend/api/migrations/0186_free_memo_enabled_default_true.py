"""【FEAT-493 (2026-07-25 hotfix)】free_memo_enabled の default を False → True に変更。

## 経緯
- 0185 では opt-in β 提供のため default=False にしていた
- PM 判断で「β 機能セクション最下部にあると気付かれない可能性が高い」ため
  default=True (全ユーザー即時有効) に方針変更
- トグル自体は Settings に残置、user は明示的に無効化可能

## 本 migration の 2 操作

### 1. AlterField(default=True)
新規作成される PlayerProfile の default 値を True に変更。

### 2. RunPython(backfill_existing)
既存の PlayerProfile (0185 適用時に free_memo_enabled=False で作成された行) を
一括で True に更新する。dev 環境では PM + 検証用 1-2 名、prod デプロイ時
（v1.0.4 以降で FEAT-493 が prod に merge される時）は全既存ユーザーが対象。

## 例外条項適用
CLAUDE.md「破壊的データマイグレーション禁止 (FEAT-250)」の観点:
- 対象データは **本 hotfix commit 時点でリリース未達の新規 field** (0185 で追加)
- 実質的に「default 値の初期化ミス修正」であり、user が触った選択を破壊しない
  (未リリース状態のため触りようがない)
- update 対象は Boolean field 1 個のみ、冪等 (2 度目の実行は no-op)
- master/seed data 例外条項に近い性質 (「新規 field の初期状態調整」)

## Reversible
reverse migration では既存 row を False に戻す (対称)。ただし通常運用では
reverse を叩かない想定 (方針変更を巻き戻す = spec 逆戻り = 通常発生しない)。
"""
from django.db import migrations, models


def backfill_free_memo_enabled_true(apps, schema_editor):
    """既存 PlayerProfile を free_memo_enabled=True に更新。

    0185 適用時に False で作成された全 row を True に flip する。
    """
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    updated = PlayerProfile.objects.filter(free_memo_enabled=False).update(
        free_memo_enabled=True,
    )
    print(f'[FEAT-493 migration 0186] backfill: {updated} row(s) updated to '
          f'free_memo_enabled=True')


def reverse_backfill(apps, schema_editor):
    """reverse: 全 row を False に戻す (対称、通常運用では実行しない)。"""
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    updated = PlayerProfile.objects.filter(free_memo_enabled=True).update(
        free_memo_enabled=False,
    )
    print(f'[FEAT-493 migration 0186 reverse] {updated} row(s) reverted to '
          f'free_memo_enabled=False')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0185_playerprofile_free_memo_enabled'),
    ]

    operations = [
        # 1) default を True に変更 (schema alter)
        migrations.AlterField(
            model_name='playerprofile',
            name='free_memo_enabled',
            field=models.BooleanField(
                default=True,
                help_text='FEAT-493 フリーメモ機能の有効/無効 flag、default ON',
                verbose_name='フリーメモ有効',
            ),
        ),
        # 2) 既存 row を True に一括更新 (0185 で False で作成された行の backfill)
        migrations.RunPython(
            backfill_free_memo_enabled_true,
            reverse_code=reverse_backfill,
        ),
    ]
