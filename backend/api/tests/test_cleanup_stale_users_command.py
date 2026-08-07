"""FEAT-250: cleanup_stale_users management command の契約テスト。

migration 0073 から移行したロジックが「非管理者 User のみを削除する」契約を
守っていることを検証する。--dry-run / --confirm の排他性 + 必須性も含む。
"""
from io import StringIO

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase


class CleanupStaleUsersCommandTest(TestCase):
    def setUp(self):
        User = get_user_model()
        # superuser 1, staff 1, regular 3
        User.objects.create_user(
            'admin', email='admin@example.com',
            is_superuser=True, is_staff=True,
        )
        User.objects.create_user(
            'staff', email='staff@example.com',
            is_staff=True,
        )
        User.objects.create_user('regular1', email='regular1@example.com')
        User.objects.create_user('regular2', email='regular2@example.com')
        User.objects.create_user('regular3', email='regular3@example.com')

    def test_dry_run_does_not_delete(self):
        User = get_user_model()
        out = StringIO()
        call_command('cleanup_stale_users', '--dry-run', stdout=out)
        self.assertEqual(User.objects.count(), 5)  # 全件残る
        self.assertIn('削除対象: 非管理者 User 3 件', out.getvalue())
        self.assertIn('--dry-run なので削除はスキップしました', out.getvalue())

    def test_confirm_deletes_only_non_admin(self):
        User = get_user_model()
        out = StringIO()
        call_command('cleanup_stale_users', '--confirm', stdout=out)
        self.assertEqual(User.objects.count(), 2)  # admin + staff のみ残る
        self.assertEqual(
            User.objects.filter(is_superuser=False, is_staff=False).count(),
            0,
        )
        self.assertIn('削除完了: User', out.getvalue())

    def test_dry_run_and_confirm_exclusive(self):
        with self.assertRaises(CommandError):
            call_command('cleanup_stale_users', '--dry-run', '--confirm')

    def test_neither_flag_raises(self):
        with self.assertRaises(CommandError):
            call_command('cleanup_stale_users')

    def test_empty_target_is_safe_noop(self):
        # 通常 User を削除 → 対象 0 件で安全に no-op になる
        User = get_user_model()
        User.objects.filter(is_superuser=False, is_staff=False).delete()
        out = StringIO()
        call_command('cleanup_stale_users', '--confirm', stdout=out)
        self.assertEqual(User.objects.count(), 2)
        self.assertIn('対象 0 件', out.getvalue())
