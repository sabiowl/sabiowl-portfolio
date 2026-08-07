"""【FEAT-490 (2026-07-09)】GiftView 3 種セット化 (XP boost + coin + charge) の契約テスト。

Gift の schema 拡張と cap ロジックが意図通り動作するかを 5 シナリオで固定化する。
将来 balance 調整 (20 → 30 coins 等) や cap 変更 (3 → 5 senders 等) をする際は
本テストの hardcode 値を意図的に書き換える形で follow する。

5 シナリオ:
- S1: first gift (1 sender) → receiver に XP boost stock +1 / coins +20 / charges +1
- S2: 3 senders 済の状態で 4 sender 目 → XP boost のみ付与、coins=0 / charges=0
- S3: 3 senders 済の状態で **同じ 3 sender 内** から追加送信は per-friend 1/day で塞がれる
      (S2 のケースは "異なる 4 人目" が前提)
- S4: battle_charges が既に 30 到達 → coins +20 は付与、charges は 0 (silent skip、storage cap 遵守)
- S5: sender コスト無変動 (無償贈呈の設計哲学、FEAT-451 → FEAT-490 継続) の regression 確認
"""
from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import FriendStatus
from api.models import Friendship, Gift, Notification, PlayerProfile

User = get_user_model()


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
class GiftViewV2RewardsContractTest(APITestCase):
    """【FEAT-490】XP boost + coin + charge の 3 種セット + cap ロジック契約。"""

    # Cap 定数 (Backend と揃える、変更時は両方書き換える)
    EXPECTED_COINS_PER_GRANT   = 20
    EXPECTED_CHARGES_PER_GRANT = 1
    DAILY_SENDER_CAP           = 3
    STORAGE_CAP_BATTLE_CHARGES = 30

    def setUp(self):
        # ── receiver (自分、贈り物を受け取る側) ─────────────────
        self.receiver_user = User.objects.create_user(
            username='receiver', password='pw',
        )
        self.receiver = PlayerProfile.objects.create(
            user=self.receiver_user, name='受取人',
        )

    def _make_sender(self, index: int) -> tuple[PlayerProfile, Token]:
        """N 人目の sender + 承認済フレンド関係を作る。"""
        user = User.objects.create_user(username=f'sender{index}', password='pw')
        sender = PlayerProfile.objects.create(user=user, name=f'送信者{index}')
        Friendship.objects.create(
            from_player=sender, to_player=self.receiver,
            status=FriendStatus.ACCEPTED,
        )
        return sender, Token.objects.create(user=user)

    def _send_gift_as(self, token: Token) -> 'rest_framework.response.Response':
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')
        return self.client.post(f'/api/friends/{self.receiver.id}/gift/')

    def _refetch_receiver(self) -> PlayerProfile:
        """`PlayerProfile.economy` / `.battle` 等は `__dict__` キャッシュを持つため、
        gift 送信後の値検証は必ず fresh instance を fetch し直すこと。
        """
        return PlayerProfile.objects.get(pk=self.receiver.pk)

    # ─────────────────────────────────────────────────────────────────
    # S1: first gift → XP boost + coins +20 + charge +1 の全 3 種付与
    # ─────────────────────────────────────────────────────────────────
    def test_S1_first_gift_grants_all_three_rewards(self):
        """初回の gift で XP boost stock +1 / coins +20 / battle_charges +1 全て付与される。"""
        sender, token = self._make_sender(1)
        coins_before   = self.receiver.economy.bonus_coins
        charges_before = self.receiver.battle.battle_charges

        res = self._send_gift_as(token)

        self.assertEqual(res.status_code, http_status.HTTP_200_OK, msg=res.data)
        self.assertEqual(res.data['gifted_today'], True)
        self.assertEqual(res.data['coins_awarded'],   self.EXPECTED_COINS_PER_GRANT)
        self.assertEqual(res.data['charges_awarded'], self.EXPECTED_CHARGES_PER_GRANT)
        self.assertGreaterEqual(res.data['receiver_xp_boost_stock'], 1)

        receiver = self._refetch_receiver()
        self.assertEqual(
            receiver.economy.bonus_coins,
            coins_before + self.EXPECTED_COINS_PER_GRANT,
            msg='receiver coins should increase by 20',
        )
        self.assertEqual(
            receiver.battle.battle_charges,
            charges_before + self.EXPECTED_CHARGES_PER_GRANT,
            msg='receiver battle_charges should increase by 1',
        )

        # Gift レコードの audit 記録
        gift = Gift.objects.get(sender=sender, receiver=self.receiver)
        self.assertEqual(gift.coins_awarded,   self.EXPECTED_COINS_PER_GRANT)
        self.assertEqual(gift.charges_awarded, self.EXPECTED_CHARGES_PER_GRANT)

    # ─────────────────────────────────────────────────────────────────
    # S2: 3 senders 通過後の 4 人目 → XP boost のみ、coins/charges = 0 capped
    # ─────────────────────────────────────────────────────────────────
    def test_S2_fourth_sender_hits_daily_cap_xp_only(self):
        """3 人 sender からもらった後、4 人目からは XP boost のみ (cap 到達で coins/charges = 0)。"""
        # 1〜3 人目の gift (それぞれ 20 coins / 1 charge 付与)
        for i in range(1, self.DAILY_SENDER_CAP + 1):
            _sender, token = self._make_sender(i)
            self._send_gift_as(token)

        receiver_after_3 = self._refetch_receiver()
        coins_after_3   = receiver_after_3.economy.bonus_coins
        charges_after_3 = receiver_after_3.battle.battle_charges
        self.assertEqual(
            coins_after_3,
            self.EXPECTED_COINS_PER_GRANT * self.DAILY_SENDER_CAP,
            msg='3 senders 分 (60 coins) が積み上がっているはず',
        )

        # 4 人目 = cap 到達後
        sender4, token4 = self._make_sender(4)
        res = self._send_gift_as(token4)

        self.assertEqual(res.status_code, http_status.HTTP_200_OK, msg=res.data)
        self.assertEqual(res.data['coins_awarded'],   0, 'cap 到達で coins は 0')
        self.assertEqual(res.data['charges_awarded'], 0, 'cap 到達で charges も 0')
        self.assertGreaterEqual(
            res.data['receiver_xp_boost_stock'], self.DAILY_SENDER_CAP + 1,
            'XP boost は cap の影響を受けず 4 人目でも +1 されるはず',
        )

        receiver = self._refetch_receiver()
        self.assertEqual(
            receiver.economy.bonus_coins, coins_after_3,
            'cap 到達で coins は変動なし',
        )
        self.assertEqual(
            receiver.battle.battle_charges, charges_after_3,
            'cap 到達で battle_charges は変動なし',
        )

        # 4 人目の Gift レコードも audit で 0 を記録
        gift4 = Gift.objects.get(sender=sender4, receiver=self.receiver)
        self.assertEqual(gift4.coins_awarded,   0)
        self.assertEqual(gift4.charges_awarded, 0)

    # ─────────────────────────────────────────────────────────────────
    # S3: 同じ sender が同日 2 回目送信 → per-friend 1/day で 400 (旧仕様継続)
    # ─────────────────────────────────────────────────────────────────
    def test_S3_same_sender_twice_same_day_is_rejected(self):
        """同じ sender からの 2 回目 gift は per-friend 1/day で拒否される (旧仕様継続)。"""
        _sender, token = self._make_sender(1)

        res1 = self._send_gift_as(token)
        self.assertEqual(res1.status_code, http_status.HTTP_200_OK)

        res2 = self._send_gift_as(token)
        self.assertEqual(
            res2.status_code, http_status.HTTP_400_BAD_REQUEST,
            'per-friend 1/day 制限で 400 拒否',
        )
        # Gift レコードは 1 件のみ
        self.assertEqual(Gift.objects.filter(receiver=self.receiver).count(), 1)

    # ─────────────────────────────────────────────────────────────────
    # S4: battle_charges = 30 到達で charges だけ silent skip、coins は付与
    # ─────────────────────────────────────────────────────────────────
    def test_S4_storage_cap_30_skips_charges_but_grants_coins(self):
        """既に battle_charges=30 なら charges は 0 スキップ、coins は 20 通常付与。"""
        # receiver の battle_charges を storage 上限に設定
        self.receiver.battle.battle_charges = self.STORAGE_CAP_BATTLE_CHARGES
        self.receiver.battle.save(update_fields=['battle_charges'])
        coins_before = self.receiver.economy.bonus_coins

        _sender, token = self._make_sender(1)
        res = self._send_gift_as(token)

        self.assertEqual(res.status_code, http_status.HTTP_200_OK, msg=res.data)
        self.assertEqual(
            res.data['coins_awarded'], self.EXPECTED_COINS_PER_GRANT,
            'storage cap は coins に影響しない',
        )
        self.assertEqual(
            res.data['charges_awarded'], 0,
            'storage cap 30 到達で charges は silent skip',
        )

        receiver = self._refetch_receiver()
        self.assertEqual(
            receiver.battle.battle_charges,
            self.STORAGE_CAP_BATTLE_CHARGES,
            'storage cap は超過しない (30 のまま)',
        )
        self.assertEqual(
            receiver.economy.bonus_coins,
            coins_before + self.EXPECTED_COINS_PER_GRANT,
        )

    # ─────────────────────────────────────────────────────────────────
    # S5: sender コスト無変動 (無償贈呈設計、FEAT-451 → FEAT-490 継続)
    # ─────────────────────────────────────────────────────────────────
    def test_S5_sender_costs_nothing(self):
        """sender の diamonds / coins / battle_charges は gift 送信で変動しない (設計哲学)。"""
        sender, token = self._make_sender(1)
        # sender に事前ステータス (bonus_coins は coin の raw storage、上記 view code
        # と一致させる。compute_coins = habit_earned + bonus_coins - coins_spent)
        sender.economy.bonus_coins = 500
        sender.economy.diamonds = 30
        sender.economy.save(update_fields=['bonus_coins', 'diamonds'])
        sender.battle.battle_charges = 10
        sender.battle.save(update_fields=['battle_charges'])

        res = self._send_gift_as(token)
        self.assertEqual(res.status_code, http_status.HTTP_200_OK)

        # `.economy` / `.battle` は __dict__ キャッシュを持つため、
        # fresh PlayerProfile を fetch し直して DB 実値を検証する。
        fresh_sender = PlayerProfile.objects.get(pk=sender.pk)
        self.assertEqual(fresh_sender.economy.bonus_coins, 500, 'sender bonus_coins 無変動')
        self.assertEqual(fresh_sender.economy.diamonds,    30,  'sender diamonds 無変動')
        self.assertEqual(fresh_sender.battle.battle_charges, 10, 'sender battle_charges 無変動')

    # ─────────────────────────────────────────────────────────────────
    # 【gameplay_review 20260709 §A-1 対応】通知内訳契約 test 3 シナリオ
    # ─────────────────────────────────────────────────────────────────
    # 受信側の Notification body に「実際に届いた内訳」が反映されているか
    # (旧仕様の汎用文言「応援が届きましたよ」だけでは cap 到達時と 3 種セット時の
    # 差が受信側に伝わらなかった問題への回帰防止)。
    def _get_latest_gift_notification(self) -> Notification:
        return Notification.objects.filter(
            player=self.receiver, notif_type='gift',
        ).order_by('-created_at').first()

    def test_N1_notification_body_lists_all_three_when_full(self):
        """初回 gift (3 種フル付与) の通知本文に XP + コイン + チャージが列挙される。"""
        _sender, token = self._make_sender(1)
        self._send_gift_as(token)

        notif = self._get_latest_gift_notification()
        self.assertIsNotNone(notif, '通知が作成されているはず')
        self.assertIn('XP ブースト', notif.body)
        self.assertIn(f'コイン +{self.EXPECTED_COINS_PER_GRANT}', notif.body)
        self.assertIn(f'バトルチャージ +{self.EXPECTED_CHARGES_PER_GRANT}', notif.body)

    def test_N2_notification_body_omits_charge_when_storage_cap(self):
        """storage cap 30 到達で charge スキップ時、通知本文からチャージ表記が消える。"""
        self.receiver.battle.battle_charges = self.STORAGE_CAP_BATTLE_CHARGES
        self.receiver.battle.save(update_fields=['battle_charges'])

        _sender, token = self._make_sender(1)
        self._send_gift_as(token)

        notif = self._get_latest_gift_notification()
        self.assertIn('XP ブースト', notif.body)
        self.assertIn(f'コイン +{self.EXPECTED_COINS_PER_GRANT}', notif.body)
        self.assertNotIn('バトルチャージ', notif.body,
                         'storage cap 到達時は charge 表記なし')

    def test_N3_notification_body_xp_only_when_daily_cap_reached(self):
        """4 sender 目 (daily cap 到達) の通知本文は XP のみ、coins/charges 表記なし。"""
        # 1〜3 人目
        for i in range(1, self.DAILY_SENDER_CAP + 1):
            _sender, token = self._make_sender(i)
            self._send_gift_as(token)
        # 4 人目 = cap 到達後
        _sender4, token4 = self._make_sender(4)
        self._send_gift_as(token4)

        notif = self._get_latest_gift_notification()
        self.assertIn('XP ブースト', notif.body)
        self.assertNotIn('コイン', notif.body, 'cap 到達時は coins 表記なし')
        self.assertNotIn('バトルチャージ', notif.body, 'cap 到達時は charges 表記なし')
