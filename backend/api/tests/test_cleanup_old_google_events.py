"""【FEAT-425 (2026-06-11)】cleanup_old_google_events management command の契約テスト。

シナリオで削除範囲 + 保護範囲を契約として固定:
  1. 31 日以上前の Google event は削除される
  2. 30 日ぴったりの Google event は保持される (cutoff_date = today - 30、`<` 比較)
  3. 29 日前の Google event は保持される
  4. source='local' (Sabiowl 起源) は古くても触らない
  5. --dry-run は削除しない、出力に「dry-run」を含む
  6. --dry-run / --confirm 両方なし or 両方あり は error
  7. --days で保持日数カスタマイズ
  8. --days < 1 は error
"""
from datetime import timedelta
from io import StringIO

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase
from django.utils import timezone

from api.models import PlayerProfile, TimelineEvent


User = get_user_model()


class CleanupOldGoogleEventsTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.user = User.objects.create_user(username='cleanup_test@example.com')
        # PlayerProfile は post_save signal で自動作成される可能性があるが、
        # 念のため明示作成 (signal の有無に依存しない)。
        cls.player, _ = PlayerProfile.objects.get_or_create(
            user=cls.user,
            defaults={'name': 'テスト'},
        )

    def _make_event(self, days_ago, source='google', suffix='x'):
        today = timezone.localdate()
        return TimelineEvent.objects.create(
            player=self.player,
            source=source,
            external_id=f'ext-{source}-{days_ago}-{suffix}',
            title=f'event {days_ago}d ({source})',
            date=today - timedelta(days=days_ago),
            category='other',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1-3: 削除範囲 vs 保護範囲 (境界条件)
    # ─────────────────────────────────────────────────────────────
    def test_old_google_event_31_days_is_deleted(self):
        ev = self._make_event(days_ago=31, source='google')
        call_command('cleanup_old_google_events', '--confirm', stdout=StringIO())
        self.assertFalse(TimelineEvent.objects.filter(pk=ev.pk).exists())

    def test_boundary_30_days_is_kept(self):
        """cutoff_date = today - 30、`date < cutoff_date` 比較で 30 日前は残る。"""
        ev = self._make_event(days_ago=30, source='google')
        call_command('cleanup_old_google_events', '--confirm', stdout=StringIO())
        self.assertTrue(TimelineEvent.objects.filter(pk=ev.pk).exists())

    def test_recent_google_event_29_days_is_kept(self):
        ev = self._make_event(days_ago=29, source='google')
        call_command('cleanup_old_google_events', '--confirm', stdout=StringIO())
        self.assertTrue(TimelineEvent.objects.filter(pk=ev.pk).exists())

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4: source='local' (Sabiowl 起源) は対象外
    # ─────────────────────────────────────────────────────────────
    def test_local_event_is_never_deleted(self):
        # 1 年前の local 起源 event でも残る = ユーザーの永続記録は保護
        ev = self._make_event(days_ago=365, source='local')
        call_command('cleanup_old_google_events', '--confirm', stdout=StringIO())
        self.assertTrue(TimelineEvent.objects.filter(pk=ev.pk).exists())

    # ─────────────────────────────────────────────────────────────
    # シナリオ 5: --dry-run は削除しない、出力に「dry-run」
    # ─────────────────────────────────────────────────────────────
    def test_dry_run_does_not_delete(self):
        ev = self._make_event(days_ago=31, source='google')
        out = StringIO()
        call_command('cleanup_old_google_events', '--dry-run', stdout=out)
        self.assertTrue(TimelineEvent.objects.filter(pk=ev.pk).exists())
        self.assertIn('dry-run', out.getvalue())

    # ─────────────────────────────────────────────────────────────
    # シナリオ 6: 排他制御 (両方なし / 両方あり = error)
    # ─────────────────────────────────────────────────────────────
    def test_requires_dry_run_or_confirm(self):
        with self.assertRaises(CommandError):
            call_command('cleanup_old_google_events', stdout=StringIO())

    def test_dry_run_and_confirm_together_is_error(self):
        with self.assertRaises(CommandError):
            call_command(
                'cleanup_old_google_events', '--dry-run', '--confirm',
                stdout=StringIO(),
            )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 7-8: --days カスタマイズ + バリデーション
    # ─────────────────────────────────────────────────────────────
    def test_custom_retention_days(self):
        """--days=60 で 60 日以前を削除、それ以内は保持。"""
        old = self._make_event(days_ago=61, source='google', suffix='old')
        recent = self._make_event(days_ago=59, source='google', suffix='recent')
        call_command(
            'cleanup_old_google_events', '--confirm', '--days', '60',
            stdout=StringIO(),
        )
        self.assertFalse(TimelineEvent.objects.filter(pk=old.pk).exists())
        self.assertTrue(TimelineEvent.objects.filter(pk=recent.pk).exists())

    def test_invalid_days_value(self):
        with self.assertRaises(CommandError):
            call_command(
                'cleanup_old_google_events', '--confirm', '--days', '0',
                stdout=StringIO(),
            )
