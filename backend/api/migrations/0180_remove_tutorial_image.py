"""【FEAT-468 廃止 (2026-07-08)】チュートリアル carousel popup モデル削除。

**廃止理由**:
FEAT-485「使い方ガイド (WebView + Jekyll SSoT)」で代替済み。
admin 経由の画像管理は Single Source of Truth 原則から重複するため、
Backend + Mobile 両方で完全撤去する。本 migration は Backend 側の最終工程。

**本番影響**:
本番 DB の `TutorialImage.objects.count() == 0` を PM がユーザー側で確認済み
(2026-07-08、Render Shell 経由)。既存レコードがないため DeleteModel は空テーブル
を DROP するのみで、破壊的データ操作の対象外 (CLAUDE.md 「破壊的データマイグレーション
禁止」原則 に抵触しない)。

**operations の絞り込み**:
`makemigrations` が同時に検出した以下の pre-existing drift は本 migration の
スコープ外のため意図的に除外している (FEAT-465 の慣習を継承):
  - IAPReceipt / PlayerAnnouncementRead の RenameIndex
  - Announcement / IAPReceipt / MaintenanceConfig / PlayerAnnouncementRead /
    TaskSuggestion / PlayerProfile.active_job の `AlterField (BigAutoField 化 等)`
これらは別 FEAT でまとめて整理する。
"""
from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0179_morning_grassland_reward_scaling'),
    ]

    operations = [
        migrations.DeleteModel(
            name='TutorialImage',
        ),
    ]
