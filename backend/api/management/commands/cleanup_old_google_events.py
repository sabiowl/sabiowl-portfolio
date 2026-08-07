"""【FEAT-425 (2026-06-11)】Google カレンダー同期 TimelineEvent の保持期間制限 cleanup。

ユーザー要望「DB サーバのデータ量節約のため、Google カレンダー同期データの保管期間を
制限したい」(2026-06-11) を受けた batch cleanup。

設計:
  - source='google' で `date < today - N 日` のレコードを削除 (default N=30)
  - source='local' (Sabiowl 起源) は対象外 (古くても保持、ユーザーの永続記録)
  - source='apple' も同じ閾値で削除 (将来分離可能、現状は外部同期データ統一扱い)
  - Render scheduler で日次実行 (推奨 23:00 JST、低トラフィック時間帯)

CLAUDE.md「破壊的データマイグレーション禁止」原則:
  本 cleanup は user data 削除を含むため、migration ではなく management command
  として分離 (FEAT-250 反省準拠)。`--dry-run` で対象数を確認 → `--confirm` で実行。
  ユーザーは Google から再同期すれば過去データを復元できる (情報喪失ではなく
  「外部参照のキャッシュ削除」相当) ため、削除は安全。

Usage:
    python manage.py cleanup_old_google_events --dry-run
    python manage.py cleanup_old_google_events --confirm
    python manage.py cleanup_old_google_events --confirm --days 60

経緯:
  - 2026-06-11: FEAT-425 起票、ユーザー要望「データ量節約」採択 (案 C)。
  - 不採択: 案 A (完全ローカル保存) = multi-device 喪失 / 案 B (ハイブリッド) =
    Google API レート制限リスク。

関連:
  - external_sync.py (Google → TimelineEvent インポート経路)
  - migration 0113 (timeline_event_unique_constraint_source、source 別 unique)
"""
from datetime import timedelta

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone


# 削除対象の source (= 外部カレンダー同期で取り込んだ events)。
# source='local' (Sabiowl 起源、ユーザーが手動作成) は対象外。
_TARGET_SOURCES = ('google', 'apple')

_DEFAULT_RETENTION_DAYS = 30


class Command(BaseCommand):
    help = (
        '【FEAT-425】Google / Apple カレンダー同期 TimelineEvent の保持期間制限。'
        ' source=google/apple で N 日 (default 30) より古いレコードを削除する。'
        ' source=local (Sabiowl 起源) は対象外。'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='対象数のみ報告し、削除しない',
        )
        parser.add_argument(
            '--confirm',
            action='store_true',
            help='実際に削除を実行 (--dry-run と同時指定は不可)',
        )
        parser.add_argument(
            '--days',
            type=int,
            default=_DEFAULT_RETENTION_DAYS,
            help=f'保持日数 (default {_DEFAULT_RETENTION_DAYS} 日)。'
                 f'today - days より前の date を持つレコードが削除対象。',
        )

    def handle(self, *args, **options):
        dry_run = options['dry_run']
        confirm = options['confirm']
        days = options['days']

        # 排他: --dry-run / --confirm の両方なし、または両方ありは error
        if dry_run == confirm:
            raise CommandError(
                '--dry-run または --confirm のいずれか 1 つを指定してください '
                '(両方なし or 両方ありは不可、安全弁)。'
            )

        if days < 1:
            raise CommandError(
                f'--days は 1 以上を指定してください (指定値: {days})。'
            )

        from ...models import TimelineEvent  # late import で circular 回避

        today = timezone.localdate()
        cutoff_date = today - timedelta(days=days)

        target_qs = TimelineEvent.objects.filter(
            source__in=_TARGET_SOURCES,
            date__lt=cutoff_date,
        )
        target_count = target_qs.count()

        self.stdout.write(
            f'[cleanup_old_google_events] today={today}, '
            f'cutoff_date={cutoff_date}, retention_days={days}'
        )
        self.stdout.write(
            f'[cleanup_old_google_events] target sources={_TARGET_SOURCES}, '
            f'date < {cutoff_date} の対象レコード: {target_count} 件'
        )

        if dry_run:
            self.stdout.write(
                self.style.WARNING(
                    f'[cleanup_old_google_events] dry-run: {target_count} 件が'
                    f' 削除対象です。実際の削除は --confirm を指定して実行してください。'
                )
            )
            return

        # --confirm 経路: 実際に削除
        with transaction.atomic():
            # `delete()` 自体は count を返すが、明示的に確認用に変数受け取り。
            deleted_count, _ = target_qs.delete()

        self.stdout.write(
            self.style.SUCCESS(
                f'[cleanup_old_google_events] {deleted_count} 件削除しました。'
            )
        )
