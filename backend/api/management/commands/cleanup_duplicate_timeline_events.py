"""【FEAT-370 (2026-05-28)】BUG-70 構造解消: TimelineEvent 重複行 cleanup。

migration 0100 で UniqueConstraint を適用する前に、既存重複データを安全に削除する
ための 2 段階確認型 management command。

Usage:
    python manage.py cleanup_duplicate_timeline_events --dry-run
    python manage.py cleanup_duplicate_timeline_events --confirm

設計意図:
- CLAUDE.md「破壊的データマイグレーション禁止」遵守: cleanup を migration ではなく
  明示的な management command として分離。`--dry-run` でレビュー → `--confirm` で実行。
- `(player, date, title, start_time)` でグルーピングし最古 (pk 最小) を残して
  残りを削除する。HabitLog 紐付けは TimelineEvent には無いため CASCADE 影響なし。
- `select_for_update()` + `transaction.atomic()` で 1 グループ単位にロック取得 →
  選定 + delete を同一 transaction に閉じる (Pre-mortem シナリオ 2: race 防止)。
- 削除前に `pending_google_push=False` 先行更新で Google push race 防止
  (Pre-mortem シナリオ 3)。

経緯:
- 2026-05-27〜28: ユーザー実機で offline → online 復帰時の重複報告 → BUG-70 起票
- 2026-05-28: FEAT-370 として構造解消、本 command + migration 0100 + view 修正 +
  Flutter offline-aware 化の 4 軸でリリースブロッカー解消。

関連:
- FEAT-370 指示書 (`doc/instructions/FEAT-370_timeline_duplicate_structural_fix.md`)
- migration 0100 (`backend/api/migrations/0100_timeline_event_unique_constraint.py`)
- TimelineListView.post の IntegrityError catch (`backend/api/views/timeline.py`)
"""

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.db.models import Count


class Command(BaseCommand):
    help = (
        'TimelineEvent の (player, date, title, start_time) 重複行を cleanup する '
        '(FEAT-370 / BUG-70 構造解消)'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='重複対象の検出のみ、削除しない',
        )
        parser.add_argument(
            '--confirm',
            action='store_true',
            help='実際に削除を実行する (--dry-run と排他)',
        )

    def handle(self, *args, **options):
        # 遅延 import: 起動時の import 副作用回避
        from api.models import TimelineEvent

        dry_run = options['dry_run']
        confirm = options['confirm']

        if dry_run and confirm:
            raise CommandError('--dry-run と --confirm は同時指定できません')
        if not dry_run and not confirm:
            raise CommandError(
                '--dry-run または --confirm のいずれかを指定してください\n'
                '例: python manage.py cleanup_duplicate_timeline_events --dry-run'
            )

        # ── 重複グループ検出 (player, source, date, title, start_time で集約) ──
        # 【BUG-76 (2026-05-30) 同調修正】migration 0101 で UniqueConstraint に
        # source 軸を追加したため、cleanup 側も同調してグルーピングに source を含める。
        # これにより cross-source の同名予定 (Sabiowl ランチ + Google ランチ) は
        # 重複扱いされず、同一 source 内の真の重複のみが cleanup 対象になる。
        duplicates_qs = (
            TimelineEvent.objects
            .values('player_id', 'source', 'date', 'title', 'start_time')
            .annotate(count=Count('id'))
            .filter(count__gt=1)
            .order_by('player_id', 'source', 'date', 'title', 'start_time')
        )
        duplicates = list(duplicates_qs)  # evaluate once

        total_groups = len(duplicates)
        total_to_delete = sum(d['count'] - 1 for d in duplicates)

        self.stdout.write(
            self.style.WARNING(f'重複グループ数: {total_groups}')
        )
        self.stdout.write(
            self.style.WARNING(f'削除対象件数:   {total_to_delete}')
        )

        if total_groups == 0:
            self.stdout.write(self.style.SUCCESS('対象 0 件、何もしません'))
            return

        # 詳細 (先頭 10 件のみ)
        for dup in duplicates[:10]:
            self.stdout.write(
                f"  player={dup['player_id']} source={dup['source']!r} "
                f"date={dup['date']} title={dup['title']!r} "
                f"start_time={dup['start_time']} count={dup['count']}"
            )
        if total_groups > 10:
            self.stdout.write(f'  ... 他 {total_groups - 10} グループ')

        if dry_run:
            self.stdout.write(
                self.style.WARNING('--dry-run なので削除はスキップしました')
            )
            return

        # ── 実行 (--confirm) ────────────────────────────────────────────────
        deleted_count = 0
        for dup in duplicates:
            with transaction.atomic():
                # CLAUDE.md「pk 昇順ロック」遵守、player 単位で row lock 取得
                # 【BUG-76 同調修正】source 軸を filter に追加 (migration 0101 整合)
                rows = list(
                    TimelineEvent.objects
                    .select_for_update()
                    .filter(
                        player_id=dup['player_id'],
                        source=dup['source'],
                        date=dup['date'],
                        title=dup['title'],
                        start_time=dup['start_time'],
                    )
                    .order_by('pk')
                )
                if len(rows) <= 1:
                    # race で他 process が先に削除済 → skip
                    continue

                # 最古 (pk 最小) を残し、残りを削除
                to_delete_ids = [r.pk for r in rows[1:]]

                # Google push race 防止: 削除前に pending_google_push=False に
                # 先行 update し、fire-and-forget の push 対象から外す。
                TimelineEvent.objects.filter(pk__in=to_delete_ids).update(
                    pending_google_push=False,
                )
                deleted, _ = TimelineEvent.objects.filter(
                    pk__in=to_delete_ids,
                ).delete()
                deleted_count += deleted

        self.stdout.write(
            self.style.SUCCESS(f'削除完了: TimelineEvent {deleted_count} 件')
        )
