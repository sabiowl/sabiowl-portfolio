"""【新規 (2026-06-25)】サビセリフ拡充の契約テスト。

`backend/api/sabi_dialogue.yaml` の home プール拡充 + `home.knowledge_general`
新規プール + `views/sabi.py:get_sabi_message` の knowledge ゲート追加に伴う
構造契約 + 統合シナリオを縛る。

検証シナリオ:
    Y1: home 配下に knowledge_general プールが存在し、件数下限 (8 件以上) を満たす
    Y2: 全 home プールの全エントリが「サビ口調禁句」(感嘆符 / 〜じゃ / 〜だね /
        〜なのじゃ / 〜ですぞ) を含まない
    Y3: get_sabi_message は seed % 7 == 0 + total > 0 + level override 不発時に
        knowledge_general から返す (統合シナリオ)
    Y4: total == 0 のときは knowledge_general が発火せず no_habits に落ちる
    Y5: level >= 30 + seed % 5 == 0 のときは knowledge_general より high_level 優先
"""
import hashlib
from datetime import date as date_t
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase

from api.models import PlayerProfile
from api.sabi_loader import load_sabi_dialogue
from api.views.sabi import _SABI_MESSAGES, get_sabi_message

User = get_user_model()


class SabiDialogueYamlStructureTest(TestCase):
    """Y1, Y2: YAML 構造 + 口調 lint。"""

    def test_Y1_knowledge_general_pool_exists_and_has_minimum_entries(self):
        dlg = load_sabi_dialogue()
        home = dlg['home']
        self.assertIn('knowledge_general', home,
                      'home.knowledge_general プールが未定義')
        pool = home['knowledge_general']
        self.assertIsInstance(pool, list)
        self.assertGreaterEqual(len(pool), 8,
                                'knowledge_general は 8 件以上を維持すること '
                                '(seed % 7 == 0 経路で同じセリフが連続する印象を回避)')

    def test_Y2_no_banned_tone_in_home_pools(self):
        """サビ口調禁句が home プール全エントリに混入していないことを縛る。"""
        # 感嘆符は知識系で 1 件 fact 末尾に許容したくなる誘惑があるが、
        # CLAUDE.md 「サビ台詞では使わない (穏やかな確信を「。」で表現)」を厳守。
        banned = ['!', '!', '〜じゃ', 'じゃよ', 'じゃのう', 'ですぞ', 'なのじゃ',
                  '〜だよ', '〜だね']

        dlg = load_sabi_dialogue()
        home = dlg['home']
        violations = []
        for pool_name, pool in home.items():
            if not isinstance(pool, list):
                continue
            for entry in pool:
                if not isinstance(entry, str):
                    continue
                for token in banned:
                    if token in entry:
                        violations.append((pool_name, token, entry))

        self.assertEqual(violations, [], f'禁句混入: {violations}')


class GetSabiMessageKnowledgeGateTest(TestCase):
    """Y3, Y4, Y5: get_sabi_message の knowledge_general 選択ゲート。"""

    def setUp(self):
        self.user = User.objects.create_user(username='sabitest', password='p')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='T', level=10,
        )

    def _force_seed_mod7_zero(self, player_id: int) -> str:
        """player.id + date 文字列で seed % 7 == 0 になる組合せを探す。

        get_sabi_message は `md5(f"{player.id}{timezone.localdate()}")` を seed と
        するため、テスト用にどの date が seed % 7 == 0 を満たすかを探索する。
        """
        # 2026-01-01 から順に試す
        d = date_t(2026, 1, 1)
        for _ in range(365):
            seed_str = f"{player_id}{d}"
            seed = int(hashlib.md5(seed_str.encode()).hexdigest(), 16)
            if seed % 7 == 0:
                return d
            d = date_t(d.year + (d.month + d.day) // 365, ((d.month - 1) % 12) + 1,
                       ((d.day) % 28) + 1)
        # 万一見つからない場合は AssertionError
        raise AssertionError(f'player_id={player_id} で seed % 7 == 0 を満たす日付が見つかりません')

    def test_Y3_knowledge_general_selected_when_seed_mod7_zero(self):
        """seed % 7 == 0 + total > 0 + level override 不発で knowledge_general 選択。"""
        target_date = self._force_seed_mod7_zero(self.player.id)
        seed_str = f"{self.player.id}{target_date}"
        seed = int(hashlib.md5(seed_str.encode()).hexdigest(), 16)
        # 前提条件チェック: seed % 5 != 0 (high_level override 不発)
        # かつ self.player.level >= 5 (early_level 対象外)
        self.assertEqual(seed % 7, 0)

        # high_level の発火条件 (level >= 30 and seed % 5 == 0) を回避するため
        # player.level = 10 のまま (early_level も発火しない)。
        # ただし seed % 5 == 0 だと level >= 30 ではないため high_level は発火しない、
        # 安全。

        with patch('api.views.sabi.timezone') as mock_tz:
            mock_tz.localdate.return_value = target_date
            msg = get_sabi_message(self.player, {'completed': 1, 'total': 3})

        self.assertIn(msg, _SABI_MESSAGES['knowledge_general'],
                      f'knowledge_general 経路が機能していない: msg={msg!r}')

    def test_Y4_knowledge_general_not_selected_when_total_zero(self):
        """total == 0 では knowledge_general 不発、no_habits 優先。"""
        target_date = self._force_seed_mod7_zero(self.player.id)
        with patch('api.views.sabi.timezone') as mock_tz:
            mock_tz.localdate.return_value = target_date
            msg = get_sabi_message(self.player, {'completed': 0, 'total': 0})

        self.assertIn(msg, _SABI_MESSAGES['no_habits'])
        self.assertNotIn(msg, _SABI_MESSAGES['knowledge_general'])

    def test_Y5_high_level_priority_over_knowledge_general(self):
        """level >= 30 + seed % 5 == 0 のとき high_level が knowledge_general に優先。

        knowledge ゲートは elif chain で level override の後段にあるため、
        high_level/early_level が発火する場合は knowledge は選ばれない。
        """
        # seed % 7 == 0 かつ seed % 5 == 0 → seed % 35 == 0 になる日付を探す。
        self.player.level = 35
        self.player.save()

        d = date_t(2026, 1, 1)
        found = None
        for _ in range(3000):
            seed_str = f"{self.player.id}{d}"
            seed = int(hashlib.md5(seed_str.encode()).hexdigest(), 16)
            if seed % 35 == 0:
                found = d
                break
            d = date_t(d.year + (d.month + d.day) // 365, ((d.month - 1) % 12) + 1,
                       ((d.day) % 28) + 1)

        if found is None:
            self.skipTest('seed % 35 == 0 の日付が探索範囲で見つからず (理論上 ~3% で発生)')

        with patch('api.views.sabi.timezone') as mock_tz:
            mock_tz.localdate.return_value = found
            msg = get_sabi_message(self.player, {'completed': 2, 'total': 3})

        self.assertIn(msg, _SABI_MESSAGES['high_level'],
                      'high_level override が knowledge_general に優先されていない')
        self.assertNotIn(msg, _SABI_MESSAGES['knowledge_general'])


class GetSabiMessageNonceTest(TestCase):
    """【新規 (2026-06-26)】pull-to-refresh 用 nonce が seed に組み込まれる契約。

    検証シナリオ:
        Y6: nonce 未指定 (default '') と '0' は別 seed_str だが、テストでは
            「未指定 != '1' != '2' を含む 5 連続 nonce で複数のメッセージ種類が
             含まれる」(同じ pool の中で異なるエントリが選ばれる) ことを確認
        Y7: 同じ nonce を 2 回呼んでも同じメッセージ (決定的)
    """

    def setUp(self):
        self.user = User.objects.create_user(username='nonce_tester', password='p')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='T', level=10,
        )

    def test_Y6_different_nonces_produce_variety(self):
        """nonce を変えると seed が変わり、複数試行で異なるメッセージが
        含まれる (= 単一固定でないこと)。
        """
        with patch('api.views.sabi.timezone') as mock_tz:
            mock_tz.localdate.return_value = date_t(2026, 6, 26)
            # 6 回 nonce を変えて呼び、3 種以上のユニークメッセージが返ることを確認
            # (理論上 7 回中 7 種全部出るとは限らないが、3 種以上は十分高確率)
            messages = set()
            for i in range(7):
                msg = get_sabi_message(
                    self.player,
                    {'completed': 1, 'total': 3},
                    nonce=str(i),
                )
                messages.add(msg)
            self.assertGreaterEqual(
                len(messages), 3,
                'nonce を 7 通り変えても 3 種類未満のメッセージ → seed 撹乱効果不足',
            )

    def test_Y7_same_nonce_returns_same_message(self):
        """同一 nonce では決定的に同じメッセージ (冪等性)。"""
        with patch('api.views.sabi.timezone') as mock_tz:
            mock_tz.localdate.return_value = date_t(2026, 6, 26)
            msg1 = get_sabi_message(
                self.player, {'completed': 1, 'total': 3}, nonce='42',
            )
            msg2 = get_sabi_message(
                self.player, {'completed': 1, 'total': 3}, nonce='42',
            )
        self.assertEqual(msg1, msg2)

    def test_Y8_default_nonce_matches_legacy_behavior(self):
        """nonce 未指定 (default '') で従来 (seed = player.id + date) と完全一致。"""
        with patch('api.views.sabi.timezone') as mock_tz:
            mock_tz.localdate.return_value = date_t(2026, 6, 26)
            msg_default = get_sabi_message(
                self.player, {'completed': 1, 'total': 3},
            )
            msg_empty_nonce = get_sabi_message(
                self.player, {'completed': 1, 'total': 3}, nonce='',
            )
        self.assertEqual(msg_default, msg_empty_nonce,
                         'default nonce と empty string nonce が同等でない')


class SabiMessageDBOverrideTest(TestCase):
    """【新規 (2026-06-26)】SabiMessage admin 編集 → セリフ即時反映の契約。

    検証シナリオ:
        Y9:  DB に SabiMessage(pool='home_no_habits') を追加すると、
             YAML 既存セリフが上書きされて DB content のみが選ばれる
        Y10: is_active=False の SabiMessage は DB 一覧から除外され、
             YAML フォールバックに戻る
        Y11: 別プールへの SabiMessage 追加は対象プールにのみ影響、
             他プールは YAML のまま
        Y12: SabiMessage save 時に sabi_loader cache が自動 invalidate される
    """

    def setUp(self):
        # Django cache を毎テストで cleanup (LocMemCache 残骸排除)
        from django.core.cache import cache
        cache.clear()
        from api.models import SabiMessage
        SabiMessage.objects.all().delete()
        self.user = User.objects.create_user(username='db_override_tester', password='p')
        self.player = PlayerProfile.objects.create(
            user=self.user, name='T', level=10,
        )

    def test_Y9_db_overrides_yaml_for_target_pool(self):
        from api.models import SabiMessage
        from api.sabi_loader import load_sabi_dialogue, clear_cache

        # DB に 1 件追加 (home_no_habits を完全に上書き)
        SabiMessage.objects.create(
            pool='home_no_habits',
            content='【DB テスト用】唯一の no_habits セリフ',
            is_active=True,
            sort_order=0,
        )
        clear_cache()  # 念のため (signal は同プロセス起動時しか登録されない)

        dlg = load_sabi_dialogue()
        no_habits_pool = dlg['home']['no_habits']
        self.assertEqual(len(no_habits_pool), 1,
                         'DB プール上書き後は DB 件数のみ反映される (YAML は完全に置換)')
        self.assertEqual(no_habits_pool[0], '【DB テスト用】唯一の no_habits セリフ')

    def test_Y10_inactive_db_records_fall_back_to_yaml(self):
        from api.models import SabiMessage
        from api.sabi_loader import load_sabi_dialogue, clear_cache

        # is_active=False のレコードは無視される → YAML が活きる
        SabiMessage.objects.create(
            pool='home_no_habits',
            content='【無効化済】このセリフは出ない',
            is_active=False,
            sort_order=0,
        )
        clear_cache()

        dlg = load_sabi_dialogue()
        no_habits_pool = dlg['home']['no_habits']
        self.assertNotIn('【無効化済】このセリフは出ない', no_habits_pool)
        # YAML の元プールが活きている (1 件以上、サビ口調セリフが含まれる)
        self.assertGreaterEqual(len(no_habits_pool), 3)

    def test_Y11_db_pool_isolation(self):
        from api.models import SabiMessage
        from api.sabi_loader import load_sabi_dialogue, clear_cache

        # home_all_done のみ DB 追加
        SabiMessage.objects.create(
            pool='home_all_done',
            content='【DB】all_done のみ上書き',
            is_active=True,
        )
        clear_cache()

        dlg = load_sabi_dialogue()
        # home_all_done は DB 上書きで 1 件
        self.assertEqual(dlg['home']['all_done'], ['【DB】all_done のみ上書き'])
        # home_no_habits は YAML のまま (DB 上書きされない)
        self.assertGreaterEqual(len(dlg['home']['no_habits']), 3)
        self.assertNotIn('【DB】all_done のみ上書き', dlg['home']['no_habits'])

    def test_Y12_save_invalidates_cache_via_signal(self):
        from api.models import SabiMessage
        from api.sabi_loader import load_sabi_dialogue

        # 1 回目: YAML のみ (DB 空)
        before = list(load_sabi_dialogue()['home']['no_habits'])

        # SabiMessage 追加 → post_save signal → cache invalidate
        SabiMessage.objects.create(
            pool='home_no_habits',
            content='【signal テスト】 cache invalidate 確認用セリフ',
            is_active=True,
        )

        # 2 回目: signal で cache invalidate されたため、次のロードで DB 反映
        after = load_sabi_dialogue()['home']['no_habits']
        self.assertNotEqual(before, after,
                            'signal による cache invalidate が機能していない')
        self.assertEqual(len(after), 1, 'DB プール上書きで 1 件のみのはず')
