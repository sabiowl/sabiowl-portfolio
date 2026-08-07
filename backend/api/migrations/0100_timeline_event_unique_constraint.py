"""【FEAT-370 (2026-05-28) + hotfix 2026-05-28】BUG-70 構造解消: TimelineEvent 重複防止 UniqueConstraint。

【hotfix 経緯】
本 migration は当初 AddConstraint のみで設計したが、Render 本番 deploy で既存重複データ
(`player_id=35, date=2026-05-28, title=就寝, start_time=23:00:00` 等) と UniqueConstraint
適用が衝突し `psycopg2.errors.UniqueViolation` で build.sh 全体が失敗、Render auto-deploy が
完全ブロックされる事象が発生 (Pre-mortem シナリオ 1 の的中)。

当初設計では「migration 適用前に management command を Render Shell から手動実行」を
予防策に置いていたが、**Render Free プランは Shell アクセスを提供しない** という前提
見落としにより、cleanup を含む新コードを deploy する deploy 自体が migration で失敗する
chicken-and-egg 構造になっていた。

【CLAUDE.md「破壊的データマイグレーション禁止」原則の 1 回限り例外】
原則は「① 意図しないデータ削除を予防、② 2 段階確認 (--dry-run → --confirm) を強制」の
2 目的。本件は:
  - ① **意図しないではなく、明確に意図された BUG-70 重複データ cleanup**
  - ② 2 段階確認の代わりに `cleanup_duplicate_timeline_events.py` management command を
       並行維持して別環境 (local + 将来 Paid プラン Shell) での再利用性を確保

これらにより PM 判断責任で原則の例外措置として承認 (2026-05-28、deploy ブロック緊急復旧)。
通常運用では本 hotfix パターンを採用してはならず、management command による 2 段階手動
実行が標準。

【設計ノート】
- Django 4.2 では `UniqueConstraint(nulls_distinct=False)` が未サポート (5.0+ 機能)、
  かつ Postgres は default で NULL を区別する仕様のため、start_time の有無で
  2 つの部分 UniqueConstraint に分割する。
  1. start_time IS NOT NULL → (player, date, title, start_time) で unique
  2. start_time IS NULL     → (player, date, title)            で unique
- cleanup ロジックは management command `cleanup_duplicate_timeline_events` と
  完全同等 (最古 pk を残し、それ以外を delete、pk 昇順ロック、pending_google_push 先行
  update で Google push race 防止)。
- `reverse_code=migrations.RunPython.noop` で rollback 時の復元はしない (forward only)。
"""
from django.db import migrations, models, transaction
from django.db.models import Count


def _cleanup_duplicate_timeline_events(apps, schema_editor):
    """BUG-70 緊急復旧専用 cleanup (build.sh 自動 migrate 経由)。

    本来は `cleanup_duplicate_timeline_events.py` management command で 2 段階確認
    (--dry-run → --confirm) すべきだが、Render Free プランは Shell アクセスを
    提供しないため、migration 内 RunPython で 1-deploy 復旧する。

    削除ロジック: `(player, date, title, start_time)` でグルーピング → 最古 (pk 最小)
    を残し、それ以外を delete。pk 昇順ロックで cleanup 中 race 防止、
    `pending_google_push=False` 先行 update で Google Calendar push race 防止。
    """
    TimelineEvent = apps.get_model('api', 'TimelineEvent')

    # (player, date, title, start_time) で重複検出
    duplicates = list(
        TimelineEvent.objects
        .values('player', 'date', 'title', 'start_time')
        .annotate(count=Count('id'))
        .filter(count__gt=1)
    )

    total_groups = len(duplicates)
    total_to_delete = sum(d['count'] - 1 for d in duplicates)

    print(f'[FEAT-370 cleanup] 重複グループ数: {total_groups}')
    print(f'[FEAT-370 cleanup] 削除対象件数:   {total_to_delete}')

    if total_groups == 0:
        print('[FEAT-370 cleanup] 重複なし、cleanup スキップ')
        return

    deleted_count = 0
    for dup in duplicates:
        with transaction.atomic():
            rows = (
                TimelineEvent.objects
                .select_for_update()
                .filter(
                    player_id=dup['player'],
                    date=dup['date'],
                    title=dup['title'],
                    start_time=dup['start_time'],
                )
                .order_by('pk')  # pk 昇順ロック (CLAUDE.md 遵守)
            )
            rows_list = list(rows)
            if len(rows_list) <= 1:
                continue  # race で他 process が先に削除済の場合
            # 最古 (pk 最小) を残し、残りを delete
            # 削除前に pending_google_push=False に update (Google push race 防止)
            to_delete_ids = [r.pk for r in rows_list[1:]]
            TimelineEvent.objects.filter(pk__in=to_delete_ids).update(
                pending_google_push=False,
            )
            deleted, _ = TimelineEvent.objects.filter(pk__in=to_delete_ids).delete()
            deleted_count += deleted

    print(f'[FEAT-370 cleanup] 削除完了: {deleted_count} 件')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0099_enemy_unlock_and_balance_tuning'),
    ]

    operations = [
        # 【FEAT-370 hotfix 2026-05-28】既存重複データを cleanup してから UniqueConstraint
        # を適用する 1-deploy 復旧構成 (Render Free プラン Shell 不可前提)。
        # 詳細は本ファイル冒頭 docstring を参照。
        migrations.RunPython(
            _cleanup_duplicate_timeline_events,
            reverse_code=migrations.RunPython.noop,
        ),
        migrations.AddConstraint(
            model_name='timelineevent',
            constraint=models.UniqueConstraint(
                fields=['player', 'date', 'title', 'start_time'],
                condition=models.Q(start_time__isnull=False),
                name='unique_timeline_event_with_starttime',
            ),
        ),
        migrations.AddConstraint(
            model_name='timelineevent',
            constraint=models.UniqueConstraint(
                fields=['player', 'date', 'title'],
                condition=models.Q(start_time__isnull=True),
                name='unique_timeline_event_no_starttime',
            ),
        ),
    ]
