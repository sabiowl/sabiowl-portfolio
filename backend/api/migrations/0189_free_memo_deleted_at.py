"""【FEAT-502 (2026-07-26)】archived_at semantic 分離: user 削除は新 deleted_at へ。

CLAUDE.md 例外条項: master data ではないが、FEAT-500 の archived_at 意味混在を
正すための data migration。既存 row は「archived_at IS NOT NULL = user 削除」
(v1.0.4 リリース前 = archive_old_memos cron 未稼働なので他解釈が存在しない) を
前提に deleted_at へコピー、archived_at はクリアする。

背景 (FEAT-502 §1):
  FEAT-500 は migration 回避のため archived_at を soft delete に流用した。
  archive_old_memos cron が将来復活すると「30 日放置メモの auto archive」と
  「user 削除 (trash)」が同一 field で混在 → user 未削除メモが誤って完全削除
  可能になる地雷。v1.0.4 リリース前 (移行データほぼ空) の window で構造分離する。

Pre-mortem 予防 (§4 S1/S3):
  RunPython は archived メモ数十行以下想定 (dev test 分のみ) で timeout 低リスク。
  prod 適用前に `SELECT id, text, archived_at FROM api_freememo
  WHERE archived_at IS NOT NULL;` で行数・内容を目視、想定外なら中断して review。
"""
from django.db import migrations, models


def _migrate_archived_to_deleted(apps, schema_editor):
    FreeMemo = apps.get_model('api', 'FreeMemo')
    # v1.0.4 リリース前は archived_at IS NOT NULL = user 削除のみ
    updated = FreeMemo.objects.filter(archived_at__isnull=False).update(
        deleted_at=models.F('archived_at'),
        archived_at=None,
    )
    print(f'[FEAT-502 migration] moved {updated} rows from archived_at to deleted_at')


def _rollback_deleted_to_archived(apps, schema_editor):
    FreeMemo = apps.get_model('api', 'FreeMemo')
    FreeMemo.objects.filter(deleted_at__isnull=False).update(
        archived_at=models.F('deleted_at'),
        deleted_at=None,
    )


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0188_boss_reward_exp_monotonic'),
    ]

    operations = [
        migrations.AddField(
            model_name='freememo',
            name='deleted_at',
            field=models.DateTimeField(
                null=True, blank=True,
                help_text='【FEAT-502 (2026-07-26)】user 削除 (soft delete、ゴミ箱行) の格納先。'
                          'restore で null、purge で hard delete + row 消失。'
                          'archive_old_memos cron の archived_at とは意味的に独立。',
                verbose_name='削除日時 (soft delete)',
            ),
        ),
        migrations.AddIndex(
            model_name='freememo',
            index=models.Index(fields=['deleted_at'], name='idx_freememo_deleted_at'),
        ),
        migrations.AlterField(
            model_name='freememo',
            name='archived_at',
            field=models.DateTimeField(
                null=True, blank=True,
                help_text='【FEAT-502 (2026-07-26)】v1.0.4 で意味分離済。'
                          '本 field は将来の archive_old_memos cron 復活時の格納先として温存。'
                          'user 削除は deleted_at (FEAT-500 → FEAT-502)。',
                verbose_name='アーカイブ日時 (auto archive 用)',
            ),
        ),
        migrations.RunPython(_migrate_archived_to_deleted, _rollback_deleted_to_archived),
    ]
