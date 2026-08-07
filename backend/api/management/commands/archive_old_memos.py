"""【FEAT-493 (2026-07-25) / FEAT-500 (2026-07-26) / FEAT-502 (2026-07-26) 更新】
30 日超の未処理仮メモを自動アーカイブする管理コマンド。

`FreeMemo.created_at` が指定日数より古く、`archived_at` が null かつ
`deleted_at` が null (= user がゴミ箱に入れていない) のメモを
`archived_at = now()` でバッチ更新する (物理削除ではない、心理負担軽減のため)。

✅ 【FEAT-502 (2026-07-26) で archived_at / deleted_at の意味分離を実施済】

**分離後の状況**:
  - `archived_at` = **auto archive (本 command 専用)** の格納先
  - `deleted_at`  = **user 削除 (trash)** の格納先 (FEAT-500 → FEAT-502)
  - `FreeMemoPurgeView` の通過条件は `deleted_at IS NOT NULL` (user 削除のみ purge 可)
  - フロント側 trash 一覧 (`?archived=true` param は後方互換で据置、内部 filter は
    `deleted_at__isnull=False`) は user 削除メモのみを表示する。

→ **本 command が archived_at を書いても、trash 画面 (deleted_at ベース) には
  一切出現しない**。FEAT-502 以前に存在した「30 日放置メモが全ユーザーの
  ゴミ箱に一斉出現 → 誤完全削除」の地雷は構造的に解消済。

**残る復活障壁**: Render Free tier は **Cron Jobs に非対応**
(send_reminders.py FEAT-284 と同事情) のため、本 command 自体はまだ起動されない。

**復活の選択肢** (FEAT-284 と同構造):
  - **代替案 A**: Render 有料プラン昇格で cron 復活 (月額コスト発生)
  - **代替案 B**: 外部 cron サービス (cron-job.org 等) から HTTP endpoint 経由で
    本コマンドを叩く (外部依存)
  - **代替案 C**: Flutter local notif の逆パターン = クライアント側で 30 日超
    メモを検出して非表示化 (バックエンド archived_at には触らない)

**復活時に auto archive 済メモをどう見せるか (v1.1+ の別 FEAT で設計)**:
  archived_at ベースの「休眠メモ」一覧 UI を新設するか、trash と別枠で
  「そっと畳んだメモ」として復元導線を用意するか等は cron 復活と同時に判断。

本 command は **将来の Render 有料プラン昇格 / 外部 cron 連携時に再利用できる
ロジック資産**として残置している。削除はしない。

実行例:
    python manage.py archive_old_memos              # 本番実行 (30 日超)
    python manage.py archive_old_memos --days 14    # 期間指定
    python manage.py archive_old_memos --dry-run    # 対象確認のみ
"""

from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from api.models import FreeMemo


class Command(BaseCommand):
    help = '30 日超の未処理フリーメモを自動アーカイブする (archived_at をセット、物理削除なし)'

    def add_arguments(self, parser):
        parser.add_argument(
            '--days',
            type=int,
            default=30,
            help='何日以上古いメモをアーカイブするか（デフォルト: 30 日）',
        )
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='対象を表示するだけで実際には更新しない',
        )

    def handle(self, *args, **options):
        days      = options['days']
        dry_run   = options['dry_run']
        now       = timezone.now()
        threshold = now - timedelta(days=days)

        # 【FEAT-502 (2026-07-26)】user がゴミ箱に入れたメモ (deleted_at IS NOT NULL)
        # は auto archive の対象外。archived_at と deleted_at は意味的に独立。
        targets = FreeMemo.objects.filter(
            created_at__lt=threshold,
            archived_at__isnull=True,
            deleted_at__isnull=True,
        )
        count = targets.count()

        if dry_run:
            self.stdout.write(
                self.style.WARNING(
                    f'[dry-run] {count} 件のメモがアーカイブ対象です'
                    f'（{days} 日以上前に作成、未アーカイブ）'
                )
            )
            for memo in targets[:10]:
                self.stdout.write(
                    f'  - id={memo.id} player={memo.player_id} '
                    f'created={memo.created_at.date().isoformat()} '
                    f'text={memo.text[:30]!r}'
                )
            if count > 10:
                self.stdout.write(f'  ...他 {count - 10} 件')
            return

        if count == 0:
            self.stdout.write('アーカイブ対象はありません。')
            return

        updated = targets.update(archived_at=now)
        self.stdout.write(
            self.style.SUCCESS(
                f'{updated} 件のフリーメモをアーカイブしました '
                f'（{days} 日以上前に作成、archived_at={now.date().isoformat()}）'
            )
        )
