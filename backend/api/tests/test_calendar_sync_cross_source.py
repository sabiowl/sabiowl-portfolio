"""【BUG-76 (2026-05-30)】Google sync 構造的 500 バグの再発防止契約テスト。

FEAT-370 migration 0100 の UniqueConstraint に source 軸が欠落していたことで
Google sync が 100% 失敗していた事象を再発防止する。

【再発防止対象】
- cross-source の同名予定 (Sabiowl 「ランチ」+ Google 「ランチ」) は共存可能
- 同一 source 内の重複は引き続き防止 (BUG-70 本来の目的維持)
- ExternalCalendarImportView の update_or_create が IntegrityError で 500 にならない

【関連】
- BUG-76 指示書 (`doc/instructions/BUG-76_calendar_sync_unique_constraint_source_missing.md`)
- migration 0101 (`backend/api/migrations/0101_timeline_event_unique_constraint_source.py`)
- ExternalCalendarImportView (`backend/api/views/calendar/external_sync.py`)
"""
from datetime import date

from django.contrib.auth.models import User
from django.db import IntegrityError, transaction
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, TimelineEvent


class CalendarSyncCrossSourceTest(APITestCase):
    """BUG-76 再発防止: cross-source の同名予定が共存可能であること。"""

    def setUp(self):
        self.user = User.objects.create_user(
            username='bug76_test',
            email='bug76@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.user, name='bug76_test')
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # Sabiowl 起源予定 (source='local') を事前作成
        TimelineEvent.objects.create(
            player=self.player,
            source='local',
            date=date(2026, 5, 30),
            title='ランチ',
            start_time='12:00',
            end_time='12:30',
            category='other',
            icon_key='event',
        )

    def test_google_sync_same_title_does_not_collide(self):
        """Google 起源の同名予定が既存 Sabiowl 予定と衝突せずに取り込める。

        BUG-76 の本質的 regression test。source 軸が制約に入っていれば、
        cross-source の同名予定 (player + date + title + start_time が同じ) は
        共存可能であるべき。
        """
        response = self.client.post('/api/calendar/import/', {
            'source': 'google',
            'events': [{
                'external_id': 'abc123@google.com',
                'title': 'ランチ',
                'date': '2026-05-30',
                'start_time': '12:00',
                'end_time': '12:30',
                'category': 'other',
                'memo': '',
            }],
        }, format='json')

        # 【FEAT-426】Google Calendar import は 410 use_local_storage を返す
        # (Google カレンダー同期機能を廃止しローカルストレージ経由に移行)
        self.assertEqual(
            response.status_code, 410,
            f'Google sync should return 410 but got {response.status_code}: {response.content}',
        )

    def test_google_sync_no_starttime_same_title_does_not_collide(self):
        """start_time なし版の cross-source 共存も同様に動作する。

        UniqueConstraint は start_time IS NULL の場合に別の partial index で
        制約されているため、こちらも同様に source 軸が追加されていること。
        """
        # start_time なしの Sabiowl 予定を追加
        TimelineEvent.objects.create(
            player=self.player,
            source='local',
            date=date(2026, 5, 31),
            title='終日イベント',
            start_time=None,
            end_time=None,
            category='other',
            icon_key='event',
        )

        response = self.client.post('/api/calendar/import/', {
            'source': 'google',
            'events': [{
                'external_id': 'def456@google.com',
                'title': '終日イベント',
                'date': '2026-05-31',
                'start_time': None,
                'end_time': None,
                'category': 'other',
                'memo': '',
            }],
        }, format='json')

        # 【FEAT-426】Google Calendar import は 410 use_local_storage を返す
        self.assertEqual(response.status_code, 410,
            f'Google sync (no start_time) should return 410 but got {response.status_code}')


class TimelineEventSameSourceDuplicateBlockedTest(APITestCase):
    """BUG-70 本来の目的維持: 同一 source 内の重複は引き続き IntegrityError。"""

    def setUp(self):
        self.user = User.objects.create_user(
            username='bug76_dup_test',
            email='bug76_dup@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.user, name='bug76_dup_test')

    def test_same_source_with_starttime_duplicate_raises_integrity_error(self):
        """同一 source + 同じ (player, date, title, start_time) は IntegrityError。

        BUG-70 本来の目的が source 軸追加後も維持されていることを証明する
        regression test。
        """
        TimelineEvent.objects.create(
            player=self.player,
            source='local',
            date=date(2026, 5, 30),
            title='ランチ',
            start_time='12:00',
            end_time='12:30',
            category='other',
            icon_key='event',
        )

        with self.assertRaises(IntegrityError):
            with transaction.atomic():
                TimelineEvent.objects.create(
                    player=self.player,
                    source='local',  # 同じ source
                    date=date(2026, 5, 30),
                    title='ランチ',
                    start_time='12:00',
                    end_time='12:30',
                    category='other',
                    icon_key='event',
                )

    def test_same_source_no_starttime_duplicate_raises_integrity_error(self):
        """同一 source + start_time NULL でも (player, date, title) 重複は防止。"""
        TimelineEvent.objects.create(
            player=self.player,
            source='local',
            date=date(2026, 5, 31),
            title='終日イベント',
            start_time=None,
            category='other',
            icon_key='event',
        )

        with self.assertRaises(IntegrityError):
            with transaction.atomic():
                TimelineEvent.objects.create(
                    player=self.player,
                    source='local',
                    date=date(2026, 5, 31),
                    title='終日イベント',
                    start_time=None,
                    category='other',
                    icon_key='event',
                )
