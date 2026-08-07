"""
ユーザー削除コマンド（開発用）

【SEC-15 M-01 (2026-05-30)】DEBUG=True + SQLite + --confirm の三重ガード追加。
`DevLoginView` (views/auth/guest.py:97-102) と同じパターンで、production
PostgreSQL 上で誤って実行されることを構造的に防ぐ。

使い方:
  python manage.py delete_user subaru                       # 単一ユーザー削除
  python manage.py delete_user subaru@example.com
  python manage.py delete_user --all --confirm              # 全ユーザー削除 (二重確認必須)

ガード:
  - DEBUG=True 必須 (本番では即座に拒否)
  - SQLite 接続必須 (PostgreSQL = 本番 DB では拒否)
  - --all 指定時は --confirm も必須 (タイポ防止)
"""
from django.conf import settings as django_settings
from django.contrib.auth.models import User
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = 'ユーザーをユーザー名またはメールアドレスで削除します（開発用、DEBUG=True + SQLite 限定）'

    def add_arguments(self, parser):
        parser.add_argument('username', nargs='?', help='削除するユーザー名またはメールアドレス')
        parser.add_argument('--all', action='store_true', help='全ユーザーを削除する')
        # 【SEC-15 M-01】--all 指定時のタイポ事故防止。--confirm 同時指定で初めて発火。
        parser.add_argument('--confirm', action='store_true', help='--all と組み合わせて使用する確認フラグ')

    def handle(self, *args, **options):
        # ── 【SEC-15 M-01】三重ガード: DEBUG + SQLite + --confirm ──────────────
        # DevLoginView (views/auth/guest.py) と同じ「本番 DB に絶対に届かない」設計。
        # Render Free プランは Shell 不可で物理的に実行できないが、Render Standard 移行
        # 時や別環境にコピーされた際の事故を防ぐための defense in depth。
        is_debug  = getattr(django_settings, 'DEBUG', False)
        is_sqlite = django_settings.DATABASES['default']['ENGINE'].endswith('sqlite3')
        if not (is_debug and is_sqlite):
            self.stderr.write(self.style.ERROR(
                '本コマンドは DEBUG=True + SQLite 環境でのみ実行可能です。'
                ' 本番 (PostgreSQL) では実行できません。'
            ))
            return

        if options['all']:
            # 【SEC-15 M-01】--all は --confirm 必須 (タイポ事故防止)
            if not options.get('confirm'):
                self.stderr.write(self.style.ERROR(
                    '--all を指定する場合は --confirm も必須です。'
                    ' 例: python manage.py delete_user --all --confirm'
                ))
                return
            count, _ = User.objects.all().delete()
            self.stdout.write(self.style.SUCCESS(f'全ユーザー {count} 件を削除しました。'))
            return

        username = options.get('username')
        if not username:
            self.stderr.write('ユーザー名を指定してください。例: python manage.py delete_user subaru')
            return

        qs = (
            User.objects.filter(username__iexact=username) |
            User.objects.filter(email__iexact=username) |
            User.objects.filter(username__icontains=username)
        ).distinct()
        if not qs.exists():
            self.stderr.write(self.style.WARNING(f'ユーザー "{username}" が見つかりません。'))
            all_users = User.objects.all().values_list('id', 'username', 'email')
            if all_users:
                self.stdout.write('現在登録されているユーザー一覧:')
                for uid, uname, uemail in all_users:
                    self.stdout.write(f'  id={uid}  username={uname}  email={uemail}')
            else:
                self.stdout.write('ユーザーが1件も存在しません。')
            return

        for u in qs:
            self.stdout.write(f'削除: username={u.username}  email={u.email}')
        count, _ = qs.delete()
        self.stdout.write(self.style.SUCCESS(f'{count} 件のユーザーを削除しました。'))
