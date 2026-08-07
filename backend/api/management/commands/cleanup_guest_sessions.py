"""SEC-08 / H-03-new: 期限切れゲストのデータを削除する管理コマンド。

`GuestSession.last_active_at` が指定日数より古いゲストについて、
**PlayerProfile ごと** 削除する。CASCADE で習慣・タイムライン・ガチャ等の
配下データも消える。

実行例:
    python manage.py cleanup_guest_sessions --dry-run           # 影響確認
    python manage.py cleanup_guest_sessions --confirm           # 実行
    python manage.py cleanup_guest_sessions --days 14 --confirm

## 【2026-08-07】削除対象を PlayerProfile に変更した経緯

旧実装は `GuestSession` の行を削除していた。docstring には
「CASCADE で PlayerProfile + 関連データも全削除される」と書いてあったが、
**そうなっていなかった**。

`on_delete=CASCADE` は `GuestSession.player_profile` 側に付いているので、
CASCADE は **PlayerProfile → GuestSession** の向きにしか流れない
(`api/models/auth.py`)。GuestSession を消しても PlayerProfile は残り、
習慣・タイムライン・ガチャは孤児として残り続けていた。

しかも旧実装は「関連レコード総数: N」と出力するため、実行者は消えたと
信じてしまう。`cleanup_stale_users` は `User` を消すコマンドで、ゲストは
`PlayerProfile.user = null` なのでそちらでも消えない。つまり
**期限切れゲストのデータを purge する経路が存在しなかった**。

本コマンドは本番で自動実行されていない (cron 定義なし) ため、誤って消えた
データは無い。契約テスト `test_cleanup_guest_sessions_command.py` で発覚。

## 🔴 昇格済みユーザーを巻き込まないための guard

削除対象は `user__isnull=True` (= まだゲスト) に限定する。**これは必須**。

正式登録時、`views/auth/social.py` は `guest_session.delete()` を
**savepoint の外**で呼んでおり、コメントにも「失敗しても致命的ではない」と
書かれている。つまり **昇格済み (user あり) なのにセッションが残る状態が
構造的に起こりうる**。

旧実装はトークン 1 行しか消さないのでこれは無害だったが、PlayerProfile を
削除する今は **本物の登録ユーザーのアカウントが丸ごと消える**。
`user__isnull=True` はその一点を防ぐためにある。外さないこと。

なお昇格済みなのに残っているセッションは「消し忘れた認証情報」なので、
PlayerProfile は残したまま **セッション行だけ** 削除する (下記 §2)。

## なぜ --confirm を必須にしたか

旧実装はフラグ無しでいきなり削除していた。消えるのがトークン 1 行のうちは
それで済んだが、いまはユーザーの全データが消える。`cleanup_stale_users` と
同じく `--dry-run` / `--confirm` の排他必須に揃える。
"""

from datetime import timedelta

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from api.models import GuestSession, PlayerProfile


class Command(BaseCommand):
    help = '期限切れゲストの PlayerProfile を削除する（CASCADE で配下データも削除）'

    def add_arguments(self, parser):
        parser.add_argument(
            '--days',
            type=int,
            default=30,
            help='何日以上アクティブでないゲストを削除するか（デフォルト: 30 日）',
        )
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='削除対象を表示するだけで実際には削除しない',
        )
        parser.add_argument(
            '--confirm',
            action='store_true',
            help='実際に削除する（--dry-run と排他）',
        )

    def handle(self, *args, **options):
        days    = options['days']
        dry_run = options['dry_run']
        confirm = options['confirm']

        if dry_run and confirm:
            raise CommandError('--dry-run と --confirm は同時指定できません')
        if not dry_run and not confirm:
            raise CommandError(
                '--dry-run または --confirm のいずれかを指定してください\n'
                '例: python manage.py cleanup_guest_sessions --dry-run'
            )
        if days < 1:
            # --days 0 は「最終アクティブが現在時刻より前の全ゲスト」= 実質全件。
            # 負値は未来時刻が閾値になり、アクティブなゲストまで巻き込む。
            raise CommandError(f'--days は 1 以上を指定してください (指定値: {days})')

        threshold = timezone.now() - timedelta(days=days)
        stale_sessions = GuestSession.objects.filter(last_active_at__lt=threshold)

        # ── 1. まだゲストのプロフィール → 本体ごと削除 ────────────────────
        targets = PlayerProfile.objects.filter(
            guest_session__in=stale_sessions,
            user__isnull=True,          # 🔴 昇格済みを巻き込まない (docstring 参照)
        )
        target_ids = list(targets.values_list('id', flat=True))

        # ── 2. 昇格済みなのに残っているセッション → セッション行だけ削除 ──
        # `social.py` の `guest_session.delete()` が savepoint 外で失敗した
        # 残骸。アカウント本体は消さず、死んだ認証情報だけ片付ける。
        orphan_sessions = stale_sessions.filter(player_profile__user__isnull=False)
        orphan_count = orphan_sessions.count()

        self.stdout.write(
            f'削除対象: ゲスト {len(target_ids)} 件'
            f'（{days} 日以上非アクティブ、閾値 {threshold.isoformat()}）'
        )
        for profile in targets[:10]:
            self.stdout.write(
                f'  - player={profile.id} name={profile.name}'
                f' last_active={profile.guest_session.last_active_at.isoformat()}'
            )
        if len(target_ids) > 10:
            self.stdout.write(f'  ...他 {len(target_ids) - 10} 件')

        if orphan_count:
            self.stdout.write(self.style.WARNING(
                f'昇格済みユーザーに残ったセッション {orphan_count} 件'
                f'（アカウントは残し、セッション行のみ削除）'
            ))

        if not target_ids and not orphan_count:
            self.stdout.write(self.style.SUCCESS('対象 0 件、何もしません'))
            return

        if dry_run:
            self.stdout.write(self.style.WARNING(
                '--dry-run なので削除はスキップしました'
            ))
            return

        with transaction.atomic():
            # CASCADE で GuestSession + 習慣・タイムライン・ガチャ等が消える
            deleted, breakdown = PlayerProfile.objects.filter(
                id__in=target_ids
            ).delete()
            orphan_deleted, _ = orphan_sessions.delete()

        self.stdout.write(self.style.SUCCESS(
            f'ゲスト {len(target_ids)} 件を削除しました'
            f'（CASCADE 含む関連レコード総数: {deleted}）'
        ))
        if orphan_deleted:
            self.stdout.write(self.style.SUCCESS(
                f'残存セッション {orphan_deleted} 件を削除しました'
            ))
        self.stdout.write(f'内訳: {breakdown}')
