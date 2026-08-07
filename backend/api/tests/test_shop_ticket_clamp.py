"""【BUG-62】Shop チケット交換の上限クランプテスト。

機能レビュー 20260518 P0-1 で発見されたサイレント増殖バグの再発防止。
CLAUDE.md「ゲームバランス定数」契約 (`GachaBalance.*_TICKET_MAX`) を
コードレベルでテストで縛る。定数値そのものへの依存はしない
(定数は `GachaBalance` から参照、20260729 に daily 5→30 / weekly 4→10
に緩和済で本テストは追加変更不要)。

【BUG-112 (2026-06-14)】ticket_weekly はダイヤ 150 経路に移行。
【BUG-113 (2026-06-14)】ticket_monthly は Shop から完全撤去 (FEAT-433 で 21 日
  達成自動付与に一本化)。Shop に存在しない item_id は 404 を返す契約に変更。
【20260729】cap 数値変更 (daily 5→30 / weekly 4→10)。本テストは定数参照のため
  自動的に新 cap で動く (silent loss 実質ゼロ化、user feedback 対応)。
"""
from django.contrib.auth import get_user_model
from django.urls import reverse
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.constants import GachaBalance
from api.models import PlayerGachaStatus, PlayerProfile

User = get_user_model()


class ShopTicketClampTestCase(APITestCase):
    """Shop チケット交換が上限到達時に 400 を返すことを確認する。"""

    def setUp(self):
        self.user = User.objects.create_user(username='tester', password='password')
        # PlayerProfile はテスト用に十分なコインを `bonus_coins` で付与する。
        # compute_coins = sum(habit.total_exp // 10) + bonus_coins - coins_spent。
        # 習慣を作らずに bonus_coins だけ盛ることで、月マンスリー 800 コインも余裕でカバー。
        # 【BUG-112 (2026-06-14)】ticket_weekly がダイヤ 150 購入に変更されたため、
        # diamonds も同様に盛る (max チェックを diamonds 不足エラーで先取りされない)。
        self.player = PlayerProfile.objects.create(
            user=self.user,
            level=10,         # チケット交換 (100/300/800 コイン) を満たすレベル
            bonus_coins=10000,
            diamonds=10000,   # BUG-112: ticket_weekly = ダイヤ 150
        )
        self.gacha_status = PlayerGachaStatus.objects.create(player=self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')
        self.purchase_url = reverse('shop-purchase')

    def _purchase(self, item_id):
        return self.client.post(self.purchase_url, {'item_id': item_id}, format='json')

    # ── daily ─────────────────────────────────────────────────────────────
    def test_ticket_daily_purchase_at_max_rejects_with_400(self):
        """daily_tickets が DAILY_TICKET_MAX に達した状態で購入要求 → 400 拒否。"""
        self.gacha_status.daily_tickets = GachaBalance.DAILY_TICKET_MAX  # 5
        self.gacha_status.save()
        res = self._purchase('ticket_daily')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)
        # コインが消費されていないこと（無駄遣い防止の確認）
        self.player.refresh_from_db()
        self.assertEqual(self.player.coins_spent, 0)
        # チケット枚数も増えていない
        self.gacha_status.refresh_from_db()
        self.assertEqual(self.gacha_status.daily_tickets, GachaBalance.DAILY_TICKET_MAX)

    def test_ticket_daily_purchase_below_max_succeeds(self):
        """daily_tickets が DAILY_TICKET_MAX - 1 の状態で購入要求 → 成功、加算後 MAX に到達。"""
        self.gacha_status.daily_tickets = GachaBalance.DAILY_TICKET_MAX - 1  # 4
        self.gacha_status.save()
        res = self._purchase('ticket_daily')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED)
        self.gacha_status.refresh_from_db()
        self.assertEqual(self.gacha_status.daily_tickets, GachaBalance.DAILY_TICKET_MAX)

    # ── weekly ────────────────────────────────────────────────────────────
    def test_ticket_weekly_purchase_at_max_rejects_with_400(self):
        self.gacha_status.weekly_tickets = GachaBalance.WEEKLY_TICKET_MAX  # 4
        self.gacha_status.save()
        res = self._purchase('ticket_weekly')
        self.assertEqual(res.status_code, http_status.HTTP_400_BAD_REQUEST)

    def test_ticket_weekly_purchase_below_max_succeeds(self):
        self.gacha_status.weekly_tickets = GachaBalance.WEEKLY_TICKET_MAX - 1  # 3
        self.gacha_status.save()
        res = self._purchase('ticket_weekly')
        self.assertEqual(res.status_code, http_status.HTTP_201_CREATED)
        self.gacha_status.refresh_from_db()
        self.assertEqual(self.gacha_status.weekly_tickets, GachaBalance.WEEKLY_TICKET_MAX)

    # ── monthly (BUG-113: Shop から撤去) ─────────────────────────────────
    def test_ticket_monthly_purchase_returns_404(self):
        """【BUG-113 (2026-06-14)】ticket_monthly は SHOP_CATALOG から削除済。
        過去クライアントが古い item_id を送ってきても 404 で返す契約を縛る。
        Monthly チケットの入手経路は FEAT-433 (当月 21 日達成で自動付与) のみ。"""
        res = self._purchase('ticket_monthly')
        self.assertEqual(res.status_code, http_status.HTTP_404_NOT_FOUND)
        # コインも diamonds も消費されない
        self.player.refresh_from_db()
        self.assertEqual(self.player.coins_spent, 0)
        # monthly_tickets も増えていない
        self.gacha_status.refresh_from_db()
        self.assertEqual(self.gacha_status.monthly_tickets, 0)
