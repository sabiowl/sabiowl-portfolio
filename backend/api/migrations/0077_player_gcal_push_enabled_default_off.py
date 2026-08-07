"""FEAT-263: gcal_push_enabled の default を True → False に変更 + 既存全プレイヤーを
False にバックフィル。

経緯:
- FEAT-257 (migration 0076) は「既存ユーザー体験不変」を理由に default=True で
  追加したが、バッチ 1/2 検証 Step 4 で「Google 連携した瞬間に暗黙的に双方向
  同期が有効 = プライバシー驚きリスク」とユーザー指摘。
- PM 判定（2026-05-21）で **DB デフォルト OFF + FEAT-254 シート同意で自動 ON** に方針転換。

設計意図:
- DB レベルで OFF が安全側のデフォルト（未同意なら Google に書き込まない）
- ユーザーが FEAT-254 シート「承諾画面へ進む」をタップ = 双方向同期への明示同意
  → 同期実行直前に `PATCH /player/ {gcal_push_enabled: true}` で flip
- マイページのトグルでいつでも OFF 可能（FEAT-257 既存設計）

バックフィルの判断:
- リリース前段階のため既存ユーザーは開発者 / テスト用のみ
- 全員を「未同意」状態に揃えることで、後の「誰が明示同意したか」データ品質が担保される
- リリース後のオーガニックユーザーは全員 default False → シート同意 → ON のフローを通る
"""
from django.db import migrations, models


def _backfill_to_false(apps, schema_editor):
    """既存全プレイヤーを False にバックフィル（リリース前の開発リセット相当）。"""
    PlayerProfile = apps.get_model('api', 'PlayerProfile')
    updated = PlayerProfile.objects.all().update(gcal_push_enabled=False)
    print(f'[migration 0077] gcal_push_enabled backfilled to False for {updated} players.')


def _backfill_noop_reverse(apps, schema_editor):
    """ロールバック不可（既存 True 状態は復元不能、テスト目的でのみ実行）。"""
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0076_player_gcal_push_enabled'),
    ]

    operations = [
        migrations.AlterField(
            model_name='playerprofile',
            name='gcal_push_enabled',
            field=models.BooleanField(
                default=False,
                help_text='FEAT-257/263: Sabiowl の予定を Google カレンダーに'
                          '書き出すかどうか。デフォルト False（明示同意なしに'
                          '書き込まない安全側）、FEAT-254 シートで「承諾画面へ'
                          '進む」を選択した瞬間に True に flip される。',
            ),
        ),
        migrations.RunPython(_backfill_to_false, _backfill_noop_reverse),
    ]
