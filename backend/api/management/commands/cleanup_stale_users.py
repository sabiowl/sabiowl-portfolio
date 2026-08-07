"""
非管理者 User の cleanup management command。

FEAT-250: migration 0073 として破壊的データマイグレーションを実行していた
ロジックを、明示的に手動実行する management command に移行。

Usage:
    python manage.py cleanup_stale_users --dry-run     # 削除対象を表示するだけ
    python manage.py cleanup_stale_users --confirm     # 実行（--dry-run と併用不可）

設計意図:
- `migrate` パイプラインから破壊的データ操作を排除（FEAT-250 反省）
- `--dry-run` でレビュー → `--confirm` で実行の 2 段階確認
- 出力に削除件数と CASCADE 影響を明示

経緯:
- 2026-05-20: BUG-67 の応急処置として migration 0073 を作成、Render で
  4 件 / 97 行 CASCADE 削除を実行済
- 2026-05-21: FEAT-250 で migration 0073 を no-op 化、ロジックを本コマンドへ移植

関連:
- BUG-67 (`@transaction.atomic` + IntegrityError savepoint 修正、commit `cfd52c6`)
- FEAT-245 (3 段階削除パイプライン完全化、commit `f0ca9de`)
"""

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction


class Command(BaseCommand):
    help = '非管理者 User を全削除する（dev reset / stale user cleanup 用）'

    def add_arguments(self, parser):
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='削除対象を表示するだけで実行しない',
        )
        parser.add_argument(
            '--confirm',
            action='store_true',
            help='実行する（--dry-run と排他）',
        )

    def handle(self, *args, **options):
        dry_run = options['dry_run']
        confirm = options['confirm']

        if dry_run and confirm:
            raise CommandError('--dry-run と --confirm は同時指定できません')
        if not dry_run and not confirm:
            raise CommandError(
                '--dry-run または --confirm のいずれかを指定してください\n'
                '例: python manage.py cleanup_stale_users --dry-run'
            )

        User = get_user_model()
        target_qs = User.objects.filter(is_superuser=False, is_staff=False)
        target_count = target_qs.count()
        target_ids = list(target_qs.values_list('id', flat=True))

        self.stdout.write(
            self.style.WARNING(
                f'削除対象: 非管理者 User {target_count} 件'
            )
        )
        if target_count == 0:
            self.stdout.write(self.style.SUCCESS('対象 0 件、何もしません'))
            return

        # 詳細（最初の 10 件のみ）
        for u in target_qs[:10]:
            self.stdout.write(f'  - id={u.id} username={u.username} email={u.email}')
        if target_count > 10:
            self.stdout.write(f'  ... 他 {target_count - 10} 件')

        if dry_run:
            self.stdout.write(
                self.style.WARNING('--dry-run なので削除はスキップしました')
            )
            return

        # 実行
        # User.delete() で CASCADE 連鎖:
        #   auth.User → api.PlayerProfile (OneToOne) → 関連全データ
        #   + api.SocialAccount, authtoken.Token, etc.
        # AccountDeletionFeedback は IntegerField で FK でないため統計用に維持される。
        with transaction.atomic():
            deleted_count, deleted_by_model = User.objects.filter(
                id__in=target_ids
            ).delete()

        self.stdout.write(
            self.style.SUCCESS(f'削除完了: User {deleted_count} 件')
        )
        self.stdout.write('CASCADE 影響:')
        for model_label, count in deleted_by_model.items():
            self.stdout.write(f'  {model_label}: {count}')
