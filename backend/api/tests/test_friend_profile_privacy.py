"""【FEAT-396 (2026-05-31)】FriendPlayerSerializer の固定化契約テスト。

セマンティクス変更 (案 D-1):
- public_habits: 常に [] (習慣の内容は常に非公開)
- best_streak: all_private 無視で常に計算 (継続日数は常に公開、モチベーション源)
- monthly_rate: 常に 0 (率からの内容推察を防ぐ)

4 シナリオで契約を縛る:
- A: all_private=True でも best_streak は実値を返す (旧仕様では 0 だった)
- B: all_private=False でも public_habits は常に空 list
- C: all_private=False でも monthly_rate は常に 0
- D: name / level 等のプロフィール基本情報は通常通り返却 (退行確認)
"""
from datetime import date as date_type

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import FriendStatus
from api.models import Friendship, Habit, HabitLog, PlayerProfile

User = get_user_model()


# throttle 緩和 (既存 test_social_auth_atomic.py と同パターン)
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
class FriendProfilePrivacyContractTest(APITestCase):
    """【FEAT-396】FriendPlayerSerializer の「習慣内容非公開・継続日数公開」契約。"""

    def setUp(self):
        # ── 自分 (me) ─────────────────────────────────────
        self.me_user = User.objects.create_user(
            username='me', password='password',
        )
        self.me_player = PlayerProfile.objects.create(
            user=self.me_user, name='自分',
        )
        self.me_token = Token.objects.create(user=self.me_user)

        # ── フレンド (= 表示対象) ──────────────────────
        self.friend_user = User.objects.create_user(
            username='friend', password='password',
        )
        self.friend_player = PlayerProfile.objects.create(
            user=self.friend_user,
            name='フレンドB',
            level=5,
        )
        # フレンド申請 + 承認 (FriendProfileView は accepted 必須)
        Friendship.objects.create(
            from_player=self.me_player,
            to_player=self.friend_player,
            status=FriendStatus.ACCEPTED,
        )
        # 認証ヘッダー
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.me_token.key}')

    def _create_habit_with_streak(self, name, streak, best_streak, is_public=True):
        """フレンドの習慣を best_streak 付きで作成。"""
        return Habit.objects.create(
            player=self.friend_player,
            name=name,
            category='運動',
            frequency='daily',
            reset_cycle='daily',
            difficulty='normal',
            habit_type='count',
            streak=streak,
            best_streak=best_streak,
            is_public=is_public,
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ A: all_private=True でも best_streak は実値を返す
    # ─────────────────────────────────────────────────────────────────
    def test_streak_always_public_even_when_all_private_true(self):
        """all_private=True でも best_streak は実値返却 (FEAT-396 中核挙動)。

        旧仕様: all_private=True → best_streak=0 (モチベーション源喪失)
        新仕様: all_private 無視で max(best_streak) 実値返却
        """
        self.friend_player.all_private = True
        self.friend_player.save(update_fields=['all_private'])

        self._create_habit_with_streak('習慣1', streak=5, best_streak=30)
        self._create_habit_with_streak('習慣2', streak=10, best_streak=45)

        url = reverse('friend-profile', kwargs={'player_id': self.friend_player.id})
        response = self.client.get(url)

        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(
            response.data['best_streak'], 45,
            msg='all_private=True でも best_streak は max(45) 実値を返すべき (FEAT-396)',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ B: all_private=False でも public_habits は常に空
    # ─────────────────────────────────────────────────────────────────
    def test_public_habits_always_empty_even_when_all_private_false(self):
        """public_habits は all_private に関係なく常に空 (FEAT-396 中核挙動)。

        旧仕様: all_private=False → 公開習慣を返却
        新仕様: 常に空 list (習慣の内容は他者と共有しない)
        """
        self.friend_player.all_private = False
        self.friend_player.save(update_fields=['all_private'])

        self._create_habit_with_streak('運動', streak=5, best_streak=10, is_public=True)
        self._create_habit_with_streak('読書', streak=3, best_streak=8, is_public=True)

        url = reverse('friend-profile', kwargs={'player_id': self.friend_player.id})
        response = self.client.get(url)

        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(
            response.data['public_habits'], [],
            msg='public_habits は all_private に関係なく常に空 list を返すべき (FEAT-396)',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ C: monthly_rate は常に 0
    # ─────────────────────────────────────────────────────────────────
    def test_monthly_rate_always_zero(self):
        """monthly_rate は all_private に関係なく常に 0 (FEAT-396 案 D-1)。

        旧仕様: all_private=False → 実際の達成率を返却
        新仕様: 常に 0 (率からの習慣内容推察を防ぐ)
        """
        self.friend_player.all_private = False
        self.friend_player.save(update_fields=['all_private'])

        habit = self._create_habit_with_streak('運動', streak=5, best_streak=10)
        # HabitLog で実達成を記録 (旧仕様だと monthly_rate > 0 になる)
        today = date_type.today()
        for day in range(1, today.day + 1):
            HabitLog.objects.create(
                habit=habit,
                date=date_type(today.year, today.month, day),
                count=1,
            )

        url = reverse('friend-profile', kwargs={'player_id': self.friend_player.id})
        response = self.client.get(url)

        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(
            response.data['monthly_rate'], 0,
            msg='monthly_rate は all_private に関係なく常に 0 を返すべき (FEAT-396 案 D-1)',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ D: name / level 等は通常通り返却 (退行確認)
    # ─────────────────────────────────────────────────────────────────
    def test_basic_profile_fields_returned_normally(self):
        """name / level / friend_id 等のプロフィール基本情報は退行ゼロ。

        プライバシー設定強化に伴い基本情報まで隠れていないか確認。
        フレンドの「名前 / レベル / 設定キャラ」表示はバトル機能のため必須。
        """
        self.friend_player.all_private = True  # privacy ON でも基本情報は表示
        self.friend_player.save(update_fields=['all_private'])

        url = reverse('friend-profile', kwargs={'player_id': self.friend_player.id})
        response = self.client.get(url)

        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(response.data['name'], 'フレンドB')
        self.assertEqual(response.data['level'], 5)
        self.assertTrue(
            isinstance(response.data.get('friend_id', ''), str),
            msg='friend_id は str であるべき (退行確認)',
        )

    def test_E_friend_level_reflects_post_deploy_level_up(self):
        """【codebase_review 20260704 P1-新 回帰防止】FEAT-478 Phase 2b デプロイ後に
        フレンドがレベルアップしても、フレンドプロフィール API が新しいレベルを返す。

        旧 (バグ状態、hotfix 前): FriendPlayerSerializer が PlayerProfile.level (旧 field、
        Phase 2b 以降どこからも書き込まれない孤立フィールド) を素の ModelSerializer field
        として読んでいたため、フレンドから見えるレベルは Phase 2b デプロイ時点で凍結。
        新 (hotfix 後): SerializerMethodField + obj.battle.level (PlayerBattleState、
        NEW state proxy) 経由で読むため、レベルアップが即座にフレンドから見える。

        本テストは write path を通す形で「NEW state に書き込み → API 経由で読み取り」の
        契約を縛る。旧実装ではここが 5 のままだったため FAIL していたはず。
        """
        # フレンドがレベルアップ (habit_count_service や battle.py 等が実施する
        # NEW state 書込パターンと同一)
        battle_state = self.friend_player.battle
        battle_state.level = 10
        battle_state.save(update_fields=['level'])

        url = reverse('friend-profile', kwargs={'player_id': self.friend_player.id})
        response = self.client.get(url)

        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(
            response.data['level'], 10,
            'FriendPlayerSerializer は NEW state (obj.battle.level) から '
            '読み取るべき。5 が返る場合は旧 field 直接参照の回帰',
        )

    def test_F_friend_request_lite_dict_reflects_post_deploy_level_up(self):
        """【codebase_review 20260704 P1-新 回帰防止】フレンド申請一覧 (軽量 dict) 経路も
        レベルアップを反映する。

        `_friend_player_lite_dict` (social.py) は `FriendPlayerSerializer` とは別経路
        (N+1 回避目的の軽量 payload) で、フレンド申請の送信/受信一覧で使用される。
        こちらも `p.level` (旧 field 直接参照) から `p.battle.level` (NEW state) 経由に
        書き換えた回帰防止テスト。

        フレンド申請 pending 状態で受信側 (self.me_player) が /friend-requests/ を呼び、
        送信側 (self.friend_player) のレベルを取得する経路を通す。
        """
        # 既存 setUp は accepted 状態でフレンド関係を作っているため、
        # 新規に別プレイヤーから pending 申請を作成 (受信一覧に載る)
        other_user = User.objects.create_user(username='other', password='p')
        other_player = PlayerProfile.objects.create(user=other_user, name='フレンドC')
        # NEW state 経由でレベルアップ (旧実装は p.level だけ更新されない状態が
        # 起きる可能性があるため、明示的に NEW state のみ更新して bug の再現条件を作る)
        other_battle = other_player.battle
        other_battle.level = 15
        other_battle.save(update_fields=['level'])

        Friendship.objects.create(
            from_player=other_player,
            to_player=self.me_player,
            status=FriendStatus.PENDING,
        )

        url = reverse('friend-requests')
        response = self.client.get(url)

        self.assertEqual(response.status_code, http_status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1, '1 件の受信 pending 申請')
        self.assertEqual(
            response.data[0]['player']['level'], 15,
            '_friend_player_lite_dict は NEW state (p.battle.level) 経由で '
            '読むべき。1 が返る場合は旧 field 直接参照の回帰',
        )
