"""【FEAT-538 (2026-08-29)】admin からのバトルステータス編集を安全にする契約テスト。

## このファイルが守るもの

FEAT-535 で**閲覧**は 1 画面に集約された。編集のほうは元々できていたが、
**壊れないことを誰も見ていなかった**。本ファイルはその 2 つの穴を縛る。

| # | 穴 | 縛り |
|---|---|---|
| A | `is_equipped` に DB 制約が無く、admin から 2 本装備が作れる | §1 |
| B | プレイヤー Lv を編集しても `max_exp` が追従しない | §2 |

## A が怖い理由 —— 「壊れた」ことに誰も気づけない

読み出し側 (`serializers.get_equipped_weapon` / `battle_stats_preview`) は
どちらも **順序指定のない先頭 1 件**なので、2 本装備になると
**同じプレイヤーの ATK がリクエストごとに違う値になりうる**。
例外も出ないしログにも残らない。

しかも `is_equipped` の model default は **`True`** である。
API 経路 (ガチャ / ショップ / ドロップ) は全部 `is_equipped=False` を
**明示して**作っているが、**admin から武器を 1 本足すと default の True が入る**
—— つまり補償対応で武器を配った瞬間に踏む。

## B が怖い理由 —— `while` が余計にまわる

`max_exp` が `level_to_max_exp(level)` から乖離すると、次の EXP 加算で
レベルアップ判定の `while` が意図しない回数まわる
(`exp_service.py` に同じ警告が既にある)。

`CharacterStat` 側は 2026-07-09 に 3 点セット
(`readonly_fields` / `save_model` / `save_formset`) で構造的に解決済みで、
**プレイヤー Lv 側だけ「人間が手で合わせること」という注意書きのまま**
残っていた。本ファイルはその非対称を消す。

## 経路を全部踏むこと

🔴 `save_model` だけ縛ると **inline 経由が素通りする**。inline は
`save_formset` を通るためで、前例が `PlayerStatsMatrixAdmin.save_formset`
(admin.py) にある。したがって Lv は

  1. `PlayerBattleStateAdmin` の詳細画面 (HTTP POST)
  2. `PlayerBattleStateAdmin` の `list_editable` (HTTP POST)
  3. `PlayerProfileAdmin` の `PlayerBattleStateInline` (`save_formset`)

の **3 経路すべて**にテストを置く。

## HTTP を使う理由

`ModelAdmin.save_model` を直接呼ぶだけだと、「その関数が呼ばれる経路に
本当に乗っているか」は検証していない。`list_editable` の一括保存が
`save_model` を 1 件ずつ呼ぶ、という前提そのものが**このテストの検証対象**
なので、実際に admin の URL を POST する。
"""
import re
from datetime import timedelta
from io import StringIO
from pathlib import Path

from django.contrib import admin as django_admin
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import RequestFactory, TestCase, override_settings
from django.urls import reverse
from django.utils import timezone

from api.constants import GameBalance
from api.models import (
    Character, CharacterStat, Job, PlayerBattleState, PlayerEconomyState,
    PlayerProfile, PlayerWeapon, WeaponMaster,
)

User = get_user_model()

_BACKEND = Path(__file__).resolve().parents[2]


# 【FEAT-535 CI hotfix と同じ理由】staticfiles を素の storage に落とす。
# 本番設定は WhiteNoise の manifest storage で、admin テンプレートの
# `{% static %}` が collectstatic 済みの STATIC_ROOT を前提にする。
# CI は collectstatic を回さないので 500 になる (ローカルだけ緑になる)。
_PLAIN_STATIC = override_settings(STORAGES={
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {
        'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage',
    },
})


class _AdminHttpTestCase(TestCase):
    """admin に HTTP でログインして POST するための土台。

    admin MFA は**無効化しない**。gate ごと切ると「MFA を通った後の画面」を
    見たことにならないので、session に verified タイムスタンプを入れて通す
    (FEAT-535 の `AdminChangePageSmokeTest` と同じ手口)。
    """

    def _login(self):
        from api.middleware.admin_mfa import MFA_SESSION_KEY

        # `force_login` を使うのでパスワードは要らない。実値を書くと
        # Portfolio Publish Gate の「汎用パスワード実値」に引っかかる。
        self.admin_user = User.objects.create_user(
            'feat538_super', email='feat538super@example.com',
            is_staff=True, is_superuser=True,
        )
        self.client.force_login(self.admin_user)
        session = self.client.session
        session[MFA_SESSION_KEY] = timezone.now().isoformat()
        session.save()

    def _messages(self, response):
        """redirect 後の message を文字列 list で取り出す。"""
        return [str(m) for m in response.context['messages']]


# ─────────────────────────────────────────────────────────────────────────────
# §1 A: 単一装備の保証
# ─────────────────────────────────────────────────────────────────────────────

@_PLAIN_STATIC
class SingleEquipInvariantTest(_AdminHttpTestCase):
    """🔴 admin のどの経路からでも `is_equipped=True` は 1 プレイヤー 1 本。

    **実装前はここが全部 red になる。** 現状 admin は何も守っていないので、
    チェックを 2 つ入れれば 2 本装備がそのまま DB に入る。
    """

    def setUp(self):
        self._login()
        self.owner_user = User.objects.create_user(
            'feat538_owner', email='feat538owner@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.owner_user, name='OWNER')
        # 他プレイヤー。収束処理が**他人に波及しない**ことの対照群。
        self.other_user = User.objects.create_user(
            'feat538_other', email='feat538other@example.com',
        )
        self.other = PlayerProfile.objects.create(user=self.other_user, name='OTHER')

        self.sword = WeaponMaster.objects.create(
            key='feat538_sword', name='旧の剣', atk_bonus=10,
        )
        self.axe = WeaponMaster.objects.create(
            key='feat538_axe', name='新の斧', atk_bonus=30,
        )
        self.pw_sword = PlayerWeapon.objects.create(
            player=self.player, weapon=self.sword, is_equipped=True,
        )
        self.pw_axe = PlayerWeapon.objects.create(
            player=self.player, weapon=self.axe, is_equipped=False,
        )
        # 他プレイヤーも 1 本装備している。
        self.other_pw = PlayerWeapon.objects.create(
            player=self.other, weapon=self.sword, is_equipped=True,
        )

    # ── helpers ──────────────────────────────────────────────────────────
    def _equipped_count(self, player=None):
        return PlayerWeapon.objects.filter(
            player=player or self.player, is_equipped=True,
        ).count()

    def _detail_post(self, pw, **overrides):
        data = {
            'player': str(pw.player_id),
            'weapon': str(pw.weapon_id),
            'is_equipped': 'on',
            'socket_1_crystal_type': '',
            'socket_2_crystal_type': '',
            'socket_3_crystal_type': '',
            '_save': '',
        }
        data.update(overrides)
        return self.client.post(
            reverse('admin:api_playerweapon_change', args=[pw.pk]),
            data, follow=True,
        )

    # ── 経路 1: 詳細画面 ─────────────────────────────────────────────────
    def test_detail_save_demotes_the_previously_equipped_one(self):
        res = self._detail_post(self.pw_axe)
        self.assertEqual(res.status_code, 200)

        self.pw_sword.refresh_from_db()
        self.pw_axe.refresh_from_db()
        self.assertTrue(self.pw_axe.is_equipped)
        self.assertFalse(
            self.pw_sword.is_equipped,
            '詳細画面から 2 本目を装備にしたのに、1 本目が装備のまま残っている。'
            'get_equipped_weapon() の .first() が非決定になり ATK が揺れる。',
        )
        self.assertEqual(self._equipped_count(), 1)

    def test_detail_save_reports_what_is_now_equipped(self):
        """収束したことを運営に伝えること (§3 Phase 1)。

        黙って 1 本に収束させると、「自分がチェックしたのに外れている」ように
        見える。何が装備されたのかを message で見せる。
        """
        res = self._detail_post(self.pw_axe)
        joined = ' / '.join(self._messages(res))
        self.assertIn('新の斧', joined)

    # ── 経路 2: list_editable (一覧の一括保存) ───────────────────────────
    def test_list_editable_save_converges_even_if_both_are_checked(self):
        """🔴 **同一 POST で 2 行とも True** にした場合。

        ここを「チェックを外した側が False になるから大丈夫」と考えると
        テストにならない (fix が無くても緑になる)。**両方 True** で POST して、
        それでも DB 上 1 本に収束することを見る。
        """
        res = self.client.post(
            reverse('admin:api_playerweapon_changelist'),
            {
                'form-TOTAL_FORMS': '3',
                'form-INITIAL_FORMS': '3',
                'form-MIN_NUM_FORMS': '0',
                'form-MAX_NUM_FORMS': '1000',
                'form-0-id': str(self.pw_sword.pk),
                'form-0-is_equipped': 'on',
                'form-1-id': str(self.pw_axe.pk),
                'form-1-is_equipped': 'on',
                'form-2-id': str(self.other_pw.pk),
                'form-2-is_equipped': 'on',
                '_save': '',
            },
            follow=True,
        )
        self.assertEqual(res.status_code, 200)
        self.assertEqual(
            self._equipped_count(), 1,
            'list_editable で 2 行とも True にしたら 2 本装備になった。'
            'save_model は list_editable でも 1 件ずつ呼ばれるので、'
            'そこで収束させれば防げる。',
        )
        # 他プレイヤーには波及しない。
        self.other_pw.refresh_from_db()
        self.assertTrue(self.other_pw.is_equipped)

    # ── 経路 3: 追加画面 (model default=True を踏む) ──────────────────────
    def test_adding_a_weapon_from_admin_does_not_create_a_second_equipped(self):
        """🔴 `is_equipped` の model default は **True**。

        補償対応で admin から武器を 1 本足すと、何も考えなくても True が入る。
        「2 本装備」が最も現実的に生まれる経路がここ。
        """
        mace = WeaponMaster.objects.create(
            key='feat538_mace', name='補償の槌', atk_bonus=50,
        )
        res = self.client.post(
            reverse('admin:api_playerweapon_add'),
            {
                'player': str(self.player.pk),
                'weapon': str(mace.pk),
                'is_equipped': 'on',
                'socket_1_crystal_type': '',
                'socket_2_crystal_type': '',
                'socket_3_crystal_type': '',
                '_save': '',
            },
            follow=True,
        )
        self.assertEqual(res.status_code, 200)
        self.assertEqual(
            self._equipped_count(), 1,
            'admin から武器を追加しただけで 2 本装備になった。',
        )

    # ── 装備を外す操作は他に波及しない ───────────────────────────────────
    def test_unequipping_does_not_promote_anything_else(self):
        """False に落とす操作で、勝手に別の武器が装備されないこと。

        「常に 1 本」ではなく「**多くとも 1 本**」が不変条件である。
        0 本 (全部外す) は正当な状態で、Dart 側は未装備なら 10 で計算する。
        """
        res = self._detail_post(self.pw_sword, is_equipped='')
        self.assertEqual(res.status_code, 200)
        self.pw_axe.refresh_from_db()
        self.assertFalse(self.pw_axe.is_equipped)
        self.assertEqual(self._equipped_count(), 0)


class EquipLogicIsNotDuplicatedTest(TestCase):
    """🔴 `EquipWeaponView` と admin が**同じヘルパー**を呼んでいること。

    複製すると 3 つ目の書き込み経路ができたときに同じ穴が空く。
    BUG-79 / FEAT-528 と同じ「二重真実値」の型なので、走査で禁じる。
    """

    _BULK_UNEQUIP = re.compile(r'\.update\(\s*is_equipped\s*=')

    def _read(self, *parts):
        return (_BACKEND.joinpath(*parts)).read_text(encoding='utf-8')

    def test_helper_module_exists_and_owns_the_bulk_unequip(self):
        helper = self._read('api', 'services', 'weapon_equip.py')
        self.assertTrue(
            self._BULK_UNEQUIP.search(helper),
            'services/weapon_equip.py が一括 unequip を持っていない。'
            'ここが単一真実値であるべき。',
        )

    def test_no_other_module_writes_is_equipped_in_bulk(self):
        offenders = []
        for path in sorted(_BACKEND.joinpath('api').rglob('*.py')):
            rel = path.relative_to(_BACKEND).as_posix()
            if 'migrations/' in rel or '/tests/' in rel:
                continue
            if rel.endswith('api/services/weapon_equip.py'):
                continue
            if self._BULK_UNEQUIP.search(path.read_text(encoding='utf-8')):
                offenders.append(rel)
        self.assertEqual(
            offenders, [],
            '一括 unequip が weapon_equip.py の外に複製されている: '
            f'{offenders}。view と admin は equip_exclusively() を呼ぶこと。',
        )

    def test_view_and_admin_both_call_the_helper(self):
        view = self._read('api', 'views', 'player.py')
        admin_src = self._read('api', 'admin.py')
        self.assertIn(
            'equip_exclusively', view,
            'EquipWeaponView が共有ヘルパーを呼んでいない。',
        )
        self.assertIn(
            'equip_exclusively', admin_src,
            'PlayerWeaponAdmin が共有ヘルパーを呼んでいない。',
        )


class EquipExclusivelyHelperTest(TestCase):
    """ヘルパー単体の振る舞い。"""

    def setUp(self):
        self.user = User.objects.create_user(
            'feat538_helper', email='feat538helper@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.user, name='HELPER')
        self.a = WeaponMaster.objects.create(key='feat538_h_a', name='A', atk_bonus=1)
        self.b = WeaponMaster.objects.create(key='feat538_h_b', name='B', atk_bonus=2)

    def test_returns_what_it_demoted(self):
        from api.services.weapon_equip import equip_exclusively

        pw_a = PlayerWeapon.objects.create(
            player=self.player, weapon=self.a, is_equipped=True,
        )
        pw_b = PlayerWeapon.objects.create(
            player=self.player, weapon=self.b, is_equipped=False,
        )
        demoted = equip_exclusively(self.player, pw_b)

        self.assertEqual([w.pk for w in demoted], [pw_a.pk])
        pw_a.refresh_from_db()
        self.assertFalse(pw_a.is_equipped)
        pw_b.refresh_from_db()
        self.assertTrue(pw_b.is_equipped)

    def test_is_idempotent(self):
        from api.services.weapon_equip import equip_exclusively

        pw_a = PlayerWeapon.objects.create(
            player=self.player, weapon=self.a, is_equipped=True,
        )
        self.assertEqual(equip_exclusively(self.player, pw_a), [])
        pw_a.refresh_from_db()
        self.assertTrue(pw_a.is_equipped)


class CheckDuplicateEquippedWeaponsCommandTest(TestCase):
    """§3 Phase 2 —— 重複検出コマンド。

    ⚠️ **既定は検出のみ**。`--fix` を付けたときだけ収束させる。
    運営が意図して 2 本にしている可能性を、コマンド側が勝手に潰さないため
    (Pre-mortem #4)。
    """

    def setUp(self):
        self.user = User.objects.create_user(
            'feat538_cmd', email='feat538cmd@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.user, name='DUP')
        self.old = WeaponMaster.objects.create(
            key='feat538_c_old', name='古い剣', atk_bonus=10,
        )
        self.new = WeaponMaster.objects.create(
            key='feat538_c_new', name='新しい剣', atk_bonus=40,
        )

    def _make_duplicate(self):
        pw_old = PlayerWeapon.objects.create(
            player=self.player, weapon=self.old, is_equipped=True,
        )
        pw_new = PlayerWeapon.objects.create(
            player=self.player, weapon=self.new, is_equipped=True,
        )
        # acquired_at は auto_now_add なので queryset.update() で押し戻す。
        PlayerWeapon.objects.filter(pk=pw_old.pk).update(
            acquired_at=timezone.now() - timedelta(days=30),
        )
        return pw_old, pw_new

    def _run(self, *args):
        out = StringIO()
        call_command('check_duplicate_equipped_weapons', *args, stdout=out)
        return out.getvalue()

    def test_clean_database_reports_zero(self):
        PlayerWeapon.objects.create(
            player=self.player, weapon=self.old, is_equipped=True,
        )
        self.assertIn('0', self._run())

    def test_detects_without_changing_anything(self):
        self._make_duplicate()
        output = self._run()

        self.assertIn('DUP', output)
        self.assertEqual(
            PlayerWeapon.objects.filter(
                player=self.player, is_equipped=True).count(),
            2,
            '既定実行で DB を書き換えている。--fix を付けたときだけ直すこと。',
        )

    def test_fix_keeps_the_most_recent_acquisition(self):
        pw_old, pw_new = self._make_duplicate()
        self._run('--fix')

        pw_old.refresh_from_db()
        pw_new.refresh_from_db()
        self.assertFalse(pw_old.is_equipped)
        self.assertTrue(
            pw_new.is_equipped,
            '--fix は最新 acquired_at を残すこと (直近に配ったものが意図の可能性が高い)。',
        )


# ─────────────────────────────────────────────────────────────────────────────
# §2 B: max_exp をプレイヤー Lv に追従させる
# ─────────────────────────────────────────────────────────────────────────────

@_PLAIN_STATIC
class PlayerLevelMaxExpFollowTest(_AdminHttpTestCase):
    """🔴 Lv を編集したら `max_exp` が **3 経路すべて**で追従すること。

    **実装前はここが全部 red になる。** 今あるのは
    「level 手動変更時は max_exp も同期して調整すること」という
    人間への注意書きだけで、コードは何もしていない。
    """

    #: わざと乖離させた値。追従すればこれは消える。
    STALE_MAX_EXP = 100
    NEW_LEVEL = 20

    def setUp(self):
        self._login()
        self.owner_user = User.objects.create_user(
            'feat538_lv', email='feat538lv@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.owner_user, name='LVUP')
        battle = self.player.battle
        battle.level = 1
        battle.current_exp = 4321   # 補償で意図的に入れた高い EXP を模す
        battle.max_exp = self.STALE_MAX_EXP
        battle.save()

    @property
    def expected(self):
        return GameBalance.level_to_max_exp(self.NEW_LEVEL)

    def _reloaded(self):
        return PlayerBattleState.objects.get(pk=self.player.pk)

    def _battle_post_data(self, **overrides):
        data = {
            'player': str(self.player.pk),
            'level': str(self.NEW_LEVEL),
            'current_exp': '4321',
            'max_exp': str(self.STALE_MAX_EXP),   # readonly になれば無視される
            'allocatable_points': '0',
            'battle_charges': '0',
            'battle_charges_date': '',
            'daily_battle_count': '0',
            'daily_battle_count_date': '',
            'daily_exp_count': '0',
            'daily_exp_count_date': '',
            'daily_battle_limit_bonus': '0',
            'daily_battle_limit_purchase_count': '0',
            '_save': '',
        }
        data.update(overrides)
        return data

    # ── 経路 1: 単体 admin の詳細画面 ────────────────────────────────────
    def test_detail_save_recomputes_max_exp(self):
        res = self.client.post(
            reverse('admin:api_playerbattlestate_change', args=[self.player.pk]),
            self._battle_post_data(), follow=True,
        )
        self.assertEqual(res.status_code, 200)
        self.assertEqual(
            self._reloaded().max_exp, self.expected,
            '詳細画面で Lv を上げたのに max_exp が古いまま。'
            '次の EXP 加算でレベルアップの while が余計にまわる。',
        )

    # ── 経路 2: 単体 admin の list_editable ──────────────────────────────
    def test_list_editable_save_recomputes_max_exp(self):
        res = self.client.post(
            reverse('admin:api_playerbattlestate_changelist'),
            {
                'form-TOTAL_FORMS': '1',
                'form-INITIAL_FORMS': '1',
                'form-MIN_NUM_FORMS': '0',
                'form-MAX_NUM_FORMS': '1000',
                'form-0-player': str(self.player.pk),
                'form-0-level': str(self.NEW_LEVEL),
                'form-0-current_exp': '4321',
                'form-0-battle_charges': '0',
                '_save': '',
            },
            follow=True,
        )
        self.assertEqual(res.status_code, 200)
        self.assertEqual(
            self._reloaded().max_exp, self.expected,
            'list_editable で Lv を上げたのに max_exp が古いまま。',
        )

    # ── 経路 3: PlayerProfile 詳細の inline ──────────────────────────────
    #
    # 🔴 ここが `save_model` では発火しない経路。前例は
    #    PlayerStatsMatrixAdmin.save_formset。
    def _inline_formset(self, inline_model, data_for):
        request = RequestFactory().post('/')
        request.user = self.admin_user
        profile_admin = django_admin.site._registry[PlayerProfile]
        inline = next(
            i for i in profile_admin.get_inline_instances(request, self.player)
            if i.model is inline_model
        )
        FormSet = inline.get_formset(request, self.player)
        prefix = FormSet.get_default_prefix()
        data = {
            f'{prefix}-TOTAL_FORMS': '1',
            f'{prefix}-INITIAL_FORMS': '1',
            f'{prefix}-MIN_NUM_FORMS': '0',
            f'{prefix}-MAX_NUM_FORMS': '1',
        }
        data.update({f'{prefix}-0-{k}': v for k, v in data_for.items()})
        formset = FormSet(data, instance=self.player)
        self.assertTrue(formset.is_valid(), formset.errors)
        return request, profile_admin, formset

    def test_inline_save_recomputes_max_exp(self):
        request, profile_admin, formset = self._inline_formset(
            PlayerBattleState, self._battle_post_data(),
        )
        profile_admin.save_formset(request, form=None, formset=formset, change=True)
        self.assertEqual(
            self._reloaded().max_exp, self.expected,
            'inline 経由 (PlayerProfile 詳細画面) だけ素通りしている。'
            'save_model ではなく save_formset を通る経路。',
        )

    def test_other_inlines_still_save_through_super(self):
        """PlayerBattleState 以外の inline を壊していないこと。

        `save_formset` を override すると、分岐を書き忘れた inline が
        **保存されなくなる**。economy inline で 1 本見ておく。
        """
        self.player.economy.save()   # OneToOne の行を実在させる
        request, profile_admin, formset = self._inline_formset(
            PlayerEconomyState, {
                'player': str(self.player.pk),
                'diamonds': '777',
                'bonus_coins': '0',
                'character_exchange_tickets': '0',
                'diamonds_total': '0',
                'coins_spent': '0',
                'diamond_bonus_date': '',
                'streak_protection_count': '0',
                'last_streak_protection_used_at': '',
                'xp_boost_active_until': '',
            },
        )
        profile_admin.save_formset(request, form=None, formset=formset, change=True)
        self.assertEqual(
            PlayerEconomyState.objects.get(pk=self.player.pk).diamonds, 777,
            'save_formset の分岐で economy inline の保存が落ちている。',
        )

    # ── current_exp は運営の入力を尊重する ───────────────────────────────
    def test_current_exp_is_never_touched(self):
        """⚠️ Lv を**下げた**ときに `current_exp > max_exp` になりうるが、
        勝手に切り詰めない。

        support が補償として意図的に高い EXP を入れている場合があり、
        それを黙って削るのは**運営の意図を壊す**。追従させるのは
        `max_exp` だけ。
        """
        res = self.client.post(
            reverse('admin:api_playerbattlestate_change', args=[self.player.pk]),
            self._battle_post_data(level='1', current_exp='99999'), follow=True,
        )
        self.assertEqual(res.status_code, 200)
        reloaded = self._reloaded()
        self.assertEqual(reloaded.current_exp, 99999)
        self.assertEqual(reloaded.max_exp, GameBalance.level_to_max_exp(1))
        self.assertGreater(reloaded.current_exp, reloaded.max_exp)

    # ── 手で触れないようにする ───────────────────────────────────────────
    def test_max_exp_is_readonly_on_every_editing_surface(self):
        """自動追従だけだと、詳細画面に編集欄が残って混乱する。

        `CharacterStat` 側と同じく **触れなくする**ところまでやる。
        """
        battle_admin = django_admin.site._registry[PlayerBattleState]
        self.assertIn('max_exp', battle_admin.readonly_fields)

        profile_admin = django_admin.site._registry[PlayerProfile]
        inline = next(
            i for i in profile_admin.inlines if i.model is PlayerBattleState
        )
        self.assertIn(
            'max_exp', inline.readonly_fields,
            'inline 側に readonly が無いと、画面上は編集できるのに'
            '保存すると黙って上書きされる (最悪の UX)。',
        )

    def test_admin_check_still_passes(self):
        """⚠️ readonly の列を `list_editable` に混ぜると `admin.E121` で
        `manage.py check` が落ち、build.sh の migrate が止まる。"""
        self.assertEqual(django_admin.site._registry[PlayerBattleState].check(), [])
        self.assertEqual(django_admin.site._registry[PlayerProfile].check(), [])

    def test_stale_note_is_gone(self):
        """人間への注意書きが**構造**に置き換わったこと。

        「手で同期して」と書いたままにすると、読んだ人が
        「まだ自動じゃないのか」と信じて余計な操作をする。
        """
        src = (_BACKEND / 'api' / 'admin.py').read_text(encoding='utf-8')
        self.assertNotIn('max_exp も同期して調整すること', src)


# ─────────────────────────────────────────────────────────────────────────────
# §3 Phase 4: 個票から編集画面への導線
# ─────────────────────────────────────────────────────────────────────────────

class BattleStatsPreviewLinksTest(TestCase):
    """FEAT-535 の個票から、各入力の編集画面へ行けること。

    ⚠️ **URL をハードコードしないこと。** `ADMIN_URL` は環境変数で
    差し替わる (Render で予測困難なパスにしている) ので、`/admin/...` と
    書くと dev か prod のどちらかが壊れる。
    """

    def setUp(self):
        self.user = User.objects.create_user(
            'feat538_link', email='feat538link@example.com',
        )
        self.player = PlayerProfile.objects.create(user=self.user, name='LINK')
        # `player.battle` は FEAT-478 の @property shim (get_or_create) なので、
        # 先に触っておかないと計測ブロックの中で INSERT が走ってクエリ数がずれる。
        self.player.battle.save()
        self.admin = django_admin.site._registry[PlayerProfile]

    def _html(self):
        return str(self.admin.battle_stats_preview(self.player))

    def test_weapon_link_points_at_the_filtered_changelist(self):
        html = self._html()
        expected = (
            reverse('admin:api_playerweapon_changelist')
            + f'?player__id__exact={self.player.pk}'
        )
        self.assertIn(expected, html)

    def test_stats_link_points_at_the_matrix_change_page(self):
        html = self._html()
        self.assertIn(
            reverse('admin:api_playerstatsmatrix_change', args=[self.player.pk]),
            html,
        )

    def test_level_link_points_at_the_battle_state_change_page(self):
        html = self._html()
        self.assertIn(
            reverse('admin:api_playerbattlestate_change', args=[self.player.pk]),
            html,
        )

    def test_no_hardcoded_admin_path_in_admin_module(self):
        """`reverse()` 由来であることを構造で縛る。

        値の比較だけだと、たまたま `ADMIN_URL` が既定 (`admin/`) の環境では
        ハードコードでも緑になる。ソースにリテラルが無いことまで見る。
        """
        src = (_BACKEND / 'api' / 'admin.py').read_text(encoding='utf-8')
        for literal in ("'/admin/", '"/admin/'):
            self.assertNotIn(
                literal, src,
                f'admin.py に {literal} がある。ADMIN_URL は環境変数なので'
                'dev か prod のどちらかで壊れる。reverse() を使うこと。',
            )

    def test_links_do_not_add_queries(self):
        """導線を足したせいでクエリが増えていないこと。

        FEAT-535 の `test_detail_render_query_count` が 4 本を縛っている。
        `reverse()` は DB を引かないので、ここも同じ本数のまま。
        """
        weapon = WeaponMaster.objects.create(
            key='feat538_link_sword', name='導線の剣', atk_bonus=20,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=weapon, is_equipped=True,
        )
        char = Character.objects.create(
            key='feat538_link_char', name='導線キャラ', role='テスト',
            image_path='x.png', job=Job.objects.get(job_id='dark_mage'),
        )
        self.player.active_character = char
        self.player.save(update_fields=['active_character'])
        for name in ('運動力', '学習力', '健康力', '精神力', '創造力', '貢献力'):
            CharacterStat.objects.create(player=self.player, name=name, level=3)

        request = RequestFactory().get('/')
        request.user = self.user
        player = self.admin.get_queryset(request).get(pk=self.player.pk)
        with self.assertNumQueries(4):
            self.admin.battle_stats_preview(player)
