"""【2026-07-02】PlayerProfile.friend_id を 8 → 12 桁に拡張。

変更内容:
- max_length: 8 → 12
- unique / blank / verbose_name は既存維持

新規プレイヤーの生成ロジック (models/player.py:save) は k=8 → k=12 に更新済。
既存 8 桁 friend_id の 12 桁化は、破壊的データ操作を避けるため本 migration
では実施しない (CLAUDE.md「破壊的データマイグレーションの禁止」原則遵守)。

既存 8 桁ユーザーの backfill は management command 経由:
    python manage.py backfill_friend_id_12digit --dry-run    # 影響確認
    python manage.py backfill_friend_id_12digit --confirm    # 実行

【2026-08-07】上記コマンドは **削除済**。2026-07-03 に本番で実行して全ユーザー
12 桁化を確認済み (STATUS.md FEAT-478 Phase 1)、以降に作られる行は最初から
12 桁なので再実行の余地が無くなったため。復元が要るなら:
    git log --diff-filter=D -- backend/api/management/commands/backfill_friend_id_12digit.py

Mobile 側は formatFriendId helper で長さ判定 → 12 桁は 4-4-4 (「0000-0000-0000」)、
8 桁は 4-4 (「0000-0000」) で表示するため、両者混在期間中も UI 破綻なし。

【Pre-mortem】
- S1 unique 制約: max_length を緩めるだけの AlterField は既存 8 桁データを
  そのまま保持。DB スキーマ上 varchar(12) に拡張されるだけで既存レコードに
  影響なし (PostgreSQL は varchar(N) の N 拡張を on-line で実行、lock なし)。
- S2 unique + max_length 変更の race: unique 制約は変わらない (unique=True 維持)、
  8 桁と 12 桁は文字数が違うので絶対に衝突しない (「12345678」と「123456789012」
  は unique 制約上別値)。
- S3 rollback: max_length を 12 → 8 に戻すと、12 桁 friend_id が truncate される
  リスク。Django migration は reverse を提供するが、実運用では 12 桁 → 8 桁の
  rollback は使わない想定。
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0166_task_suggestion_bulk_seed'),
    ]

    operations = [
        migrations.AlterField(
            model_name='playerprofile',
            name='friend_id',
            field=models.CharField(
                blank=True,
                max_length=12,
                unique=True,
                verbose_name='フレンドID',
            ),
        ),
    ]
