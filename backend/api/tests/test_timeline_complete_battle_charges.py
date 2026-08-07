"""【FEAT-295 後続 hotfix 2026-05-24】タイムライン予定完了で battle_charges +1 の契約テスト。

ユーザー要望「習慣 3 回必須は不公平、タイムライン予定の完了も含めてほしい」に
対応する `TimelineCompleteView.post` の修正契約を縛る:

- 初回完了 → `battle_charges +1`（max 30 上限）
- 再完了（冪等）→ `battle_charges` 不変
- 30 個（上限）所持時の完了 → `battle_charges = 30` のまま（上限維持）
  【FEAT-410 (2026-06-01)】max は 9 → 30 に変更済み (10 戦分ストック)

旧実装は `HabitCountView` の plus 経路のみで battle_charges を加算していたため、
タイムライン中心ユーザー（カレンダー的に予定を立てて達成するスタイル）が
バトル体験できない不公平が発生していた。本テストで構造的に再発防止。
"""
from datetime import date as date_type

from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import PlayerProfile, TimelineEvent

User = get_user_model()


# throttle / 認証クラスの最小構成（test_timeline_list_filters.py を踏襲）
_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.ExpiringTokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class TimelineCompleteBattleChargesTest(APITestCase):
    """タイムライン予定完了で battle_charges が正しく加算される契約。"""

    def setUp(self):
        self.user   = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(
            user=self.user,
            battle_charges_date=date_type.today(),
        )
        self.token  = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        self.event = TimelineEvent.objects.create(
            player=self.player,
            title='テスト予定',
            date=date_type(2026, 5, 24),
        )

    def _complete_url(self, pk: int) -> str:
        return f'/api/timeline/{pk}/complete/'

    # 【FEAT-478 Phase 2b (2026-07-04)】write path が player.battle
    # (PlayerBattleState、@property proxy) 経由に書き換えられたため、
    # 契約テストも NEW state (self.player.battle.battle_charges) を assert する。
    # 旧テスト (self.player.battle_charges = OLD field) は Phase 2b 未反映の
    # stale 値を見ていたため、Phase 2b 導入で不整合。

    def test_battle_charges_increment_on_first_complete(self):
        """初回完了で battle_charges が 0 → 1 に加算される。"""
        self.assertEqual(self.player.battle.battle_charges, 0)

        response = self.client.post(self._complete_url(self.event.pk))

        self.assertEqual(response.status_code, 200)
        # 【2026-07-25 P3 #1-c】API 経由で DB 更新 → shim state cache invalidation。
        # PlayerProfile.refresh_from_db() が 4 state cache を invalidate する
        # (models/player.py の refresh_from_db override)。
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.battle_charges, 1)

    def test_battle_charges_idempotent_on_recomplete(self):
        """既に完了済の予定を再 POST しても battle_charges は不変（冪等契約）。"""
        # 初回完了
        self.client.post(self._complete_url(self.event.pk))
        self.player.refresh_from_db()
        first_charges = self.player.battle.battle_charges  # 1

        # 再 POST: 既に is_completed=True なので冪等で battle_charges 加算しない
        response = self.client.post(self._complete_url(self.event.pk))
        self.assertEqual(response.status_code, 200)

        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.battle_charges, first_charges)
        # 念のため明示的に 1（増えていない）も確認
        self.assertEqual(self.player.battle.battle_charges, 1)

    def test_battle_charges_clamped_at_max_30(self):
        """30 個（上限）所持時に完了しても battle_charges = 30 のまま（max_charges 上限維持）。
        【FEAT-410 (2026-06-01)】max は 9 → 30 に変更 (timeline.py: if charges < 30: += 1)。"""
        # 上限手動で 30 にセット (【FEAT-478 Phase 2b】NEW state に直接 set)
        battle = self.player.battle
        battle.battle_charges = 30
        battle.save(update_fields=['battle_charges'])

        response = self.client.post(self._complete_url(self.event.pk))

        self.assertEqual(response.status_code, 200)
        # battle_charges=30 で上限到達 → 加算されない
        self.assertEqual(self.player.battle.battle_charges, 30)
