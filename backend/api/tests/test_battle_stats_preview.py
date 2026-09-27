"""【FEAT-535 Phase 7-3 (2026-08-29)】`battle_stats_preview` の契約テスト。

## このファイルの位置付け

`mobile/test/battle/battle_display_formula_contract_test.dart` と **同じ
worked example** をこちら側にも置く。同じ入力 → 同じ期待値を 2 つのテストが
持っていれば、**片方だけ直したときに必ずどちらかが落ちる**。

Dart 側は「係数が変わっていないか」を構造で見る (そして本ファイルを名指しで
落とす)。こちら側は「その係数で計算した結果が合っているか」を値で見る。

## 丸めが本題の 1 つ

Dart の `double.round()` は **half away from zero**、Python の組み込み
`round()` は **banker's rounding**。`attack_power_modifier = 1.5` は
`dark_mage` (闇魔導士、migration 0112) の**実在の値**なので、`.5` は
理論上の話ではない。
"""
from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings

from api.models import Character, CharacterStat, Job, PlayerProfile, PlayerWeapon, WeaponMaster
from api.services.battle_stats_preview import (
    ATHLETIC_HP_PER_LEVEL,
    CONTRIBUTION_REDUCTION_PER_LEVEL,
    CREATIVITY_CRIT_PER_LEVEL,
    HEALTH_REGEN_PER_LEVEL,
    MENTAL_ATB_PER_LEVEL,
    PLAYER_BASE_HP,
    PLAYER_HP_PER_LEVEL,
    PLAYER_SPD,
    STARTER_SWORD_ATK_BONUS,
    UNEQUIPPED_WEAPON_ATK,
    baseline_atk_for_enemy_table,
    compute_atb,
    compute_atk,
    compute_max_hp,
    compute_player_battle_stats,
    dart_round,
)

User = get_user_model()


class DartRoundingTest(TestCase):
    """🔴 Dart の `.round()` と Python 組み込み `round()` の差を縛る。"""

    def test_half_rounds_away_from_zero(self):
        # 組み込み round() は banker's なので 34 を返す。Dart は 35。
        self.assertEqual(round(34.5), 34, '前提: 組み込みは banker\'s rounding')
        self.assertEqual(dart_round(34.5), 35)
        self.assertEqual(dart_round(37.5), 38)
        self.assertEqual(dart_round(35.5), 36)

    def test_non_half_values_are_unaffected(self):
        self.assertEqual(dart_round(29.900000000000002), 30)
        self.assertEqual(dart_round(34.4), 34)
        self.assertEqual(dart_round(34.6), 35)

    def test_worked_example_matches_dart_g1(self):
        """Dart 側 G-1 と**同じ入力 / 同じ期待値**。

        base = 10 + 1*2 + 10 + 1 = 23 → 23 x 1.5 = 34.5 → 35
        base = 10 + 2*2 + 10 + 1 = 25 → 25 x 1.5 = 37.5 → 38
        """
        self.assertEqual(
            compute_atk(level=1, weapon_atk=10, study_lv=1, attack_power_modifier=1.5),
            35,
        )
        self.assertEqual(
            compute_atk(level=2, weapon_atk=10, study_lv=1, attack_power_modifier=1.5),
            38,
        )

    def test_dark_mage_modifier_is_really_1_5(self):
        """`.5` が理論上の話ではないことを DB で確かめる。"""
        dark_mage = Job.objects.filter(job_id='dark_mage').first()
        self.assertIsNotNone(dark_mage, 'dark_mage が seed されていない (migration 0112)')
        self.assertEqual(dark_mage.attack_power_modifier, 1.5)


class MaxHpWorkedExampleTest(TestCase):
    """Dart 側 E-3 と**同じ 3 件**。"""

    def test_matches_dart_e3(self):
        self.assertEqual(compute_max_hp(level=1, athletic_lv=0), 220)
        self.assertEqual(compute_max_hp(level=10, athletic_lv=5), 425)
        self.assertEqual(compute_max_hp(level=25, athletic_lv=12), 760)

    def test_constants_match_dart(self):
        # Dart 側 E-1 が同じ値を縛っている。
        self.assertEqual(PLAYER_BASE_HP, 200)
        self.assertEqual(PLAYER_HP_PER_LEVEL, 20)
        self.assertEqual(ATHLETIC_HP_PER_LEVEL, 5)


class AtbWorkedExampleTest(TestCase):
    """Dart 側 F-1 と同じ 2 件。"""

    def test_matches_dart_f1(self):
        self.assertAlmostEqual(compute_atb(atb_speed_modifier=0.9, mental_lv=5), 0.95)
        self.assertAlmostEqual(compute_atb(atb_speed_modifier=1.4, mental_lv=0), 1.4)

    def test_constants_match_dart(self):
        self.assertEqual(MENTAL_ATB_PER_LEVEL, 0.01)
        self.assertEqual(HEALTH_REGEN_PER_LEVEL, 2)
        self.assertEqual(CREATIVITY_CRIT_PER_LEVEL, 0.005)
        self.assertEqual(CONTRIBUTION_REDUCTION_PER_LEVEL, 0.005)
        self.assertEqual(PLAYER_SPD, 10)


class BaselineAtkIsNotGeneralisedTest(TestCase):
    """🔴 §4: 簡約式は敵一覧専用で、per-player とは別物であることを縛る。"""

    def test_two_distinct_tens_are_kept_apart(self):
        """`UNEQUIPPED_WEAPON_ATK` と `STARTER_SWORD_ATK_BONUS` は**別の意味**。

        今は同じ 10 だが、片方は「未装備のとき Dart が使う既定値」、もう片方は
        「実在の武器 starter_sword の値」。まとめると starter_sword を強化した
        ときに未装備の既定値まで一緒に動いてしまう。
        """
        from api.models import WeaponMaster

        self.assertEqual(UNEQUIPPED_WEAPON_ATK, 10)
        self.assertEqual(STARTER_SWORD_ATK_BONUS, 10)

        # 簡約式が仮定しているのは後者。DB の実値と一致していること。
        starter = WeaponMaster.objects.filter(key='starter_sword').first()
        self.assertIsNotNone(starter, 'starter_sword が seed されていない (migration 0082)')
        self.assertEqual(
            starter.atk_bonus, STARTER_SWORD_ATK_BONUS,
            'starter_sword.atk_bonus が変わりました。敵一覧の「想定撃数」が'
            '黙って嘘になります (baseline_atk_for_enemy_table)。',
        )

    def test_baseline_matches_20_plus_level_times_2(self):
        for level in (0, 1, 5, 18, 25, 48):
            with self.subTest(level=level):
                self.assertEqual(
                    baseline_atk_for_enemy_table(level),
                    20 + max(1, level) * 2,
                )

    def test_baseline_and_per_player_diverge_when_assumptions_break(self):
        """武器 / 学習力 / ジョブが基準と違えば、2 つは**必ず**別の値になる。

        ここが等しくなったら、per-player 側が簡約式に退化している
        (= §4 が禁じた「それらしいが嘘の数字」)。
        """
        level = 20
        baseline = baseline_atk_for_enemy_table(level)
        per_player = compute_atk(
            level=level,
            weapon_atk=45,            # mythril 相当
            study_lv=12,              # 学習力が育っている
            attack_power_modifier=1.5,  # dark_mage
        )
        # base = 10 + 20*2 + 45 + 12 = 107 → 107 x 1.5 = 160.5 → 161
        # (ここも `.5` —— half away from zero でなければ 160 になる)
        self.assertEqual(baseline, 60)
        self.assertEqual(per_player, 161)
        self.assertNotEqual(baseline, per_player)


class StatKeysMatchGameBalanceTest(TestCase):
    """`_STAT_KEYS` が `GameBalance.STAT_NAMES` と一致していること。

    ミラー側は 6 キーが必ず揃っている前提で `lv['学習力']` のように引くので、
    片方だけ増減すると **KeyError で admin が 500 になる**。
    定数を import せず明示 tuple にしているのは、Dart 側がリテラルキーで
    引いているのに合わせるため —— 代わりにここで一致を縛る。
    """

    def test_matches(self):
        from api.constants import GameBalance
        from api.services.battle_stats_preview import _STAT_KEYS

        self.assertEqual(list(_STAT_KEYS), list(GameBalance.STAT_NAMES))


class PerPlayerStatsTest(TestCase):
    """`compute_player_battle_stats` —— 実データから 7 項目を出す。"""

    def setUp(self):
        self.user = User.objects.create_user('bsp_user', email='bsp@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='BSP')
        self.player.battle.level = 10
        self.player.battle.save(update_fields=['level'])

    def _set_stats(self, **levels):
        for name, lv in levels.items():
            CharacterStat.objects.update_or_create(
                player=self.player, name=name, defaults={'level': lv},
            )

    def test_full_player_all_seven_items(self):
        weapon = WeaponMaster.objects.create(
            key='bsp_sword', name='テスト剣', atk_bonus=25,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=weapon, is_equipped=True,
        )
        job = Job.objects.get(job_id='dark_mage')
        char = Character.objects.filter(job=job).first()
        if char is None:
            char = Character.objects.create(
                key='bsp_char', name='テストキャラ', role='テスト',
                image_path='x.png', job=job,
            )
        self.player.active_character = char
        self.player.save(update_fields=['active_character'])
        self._set_stats(
            運動力=6, 学習力=4, 健康力=3, 精神力=5, 創造力=8, 貢献力=2,
        )

        result = compute_player_battle_stats(self.player)
        stats = result['stats']

        # ATK: base = 10 + 10*2 + 25 + 4 = 59 → 59 x 1.5 = 88.5 → 89 (half away)
        self.assertEqual(stats['atk'], 89)
        # maxHP: 200 + 10*20 + 6*5 = 430
        self.assertEqual(stats['max_hp'], 430)
        self.assertEqual(stats['spd'], 10)
        # ATB: 0.8 (dark_mage) + 5*0.01 = 0.85
        self.assertAlmostEqual(stats['atb_modifier'], 0.85)
        self.assertEqual(stats['hp_regen_per_turn'], 6)      # 3 x 2
        self.assertAlmostEqual(stats['crit_rate'], 0.04)     # 8 x 0.005
        self.assertAlmostEqual(stats['damage_reduction'], 0.01)  # 2 x 0.005

        i = result['inputs']
        self.assertFalse(i['weapon_missing'])
        self.assertFalse(i['job_missing'])
        self.assertEqual(i['missing_stats'], [])

    def test_atk_is_not_the_baseline_formula(self):
        """🔴 §4 の要求 —— per-player が簡約式に退化していないこと。

        同じ Lv でも、武器 / 学習力 / ジョブが違えば値が変わる。
        `_baseline_atk` を流用していたらここが 40 に張り付く。
        """
        weapon = WeaponMaster.objects.create(
            key='bsp_sword2', name='テスト剣2', atk_bonus=45,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=weapon, is_equipped=True,
        )
        self._set_stats(学習力=12)

        atk = compute_player_battle_stats(self.player)['stats']['atk']
        self.assertNotEqual(atk, baseline_atk_for_enemy_table(10))
        # base = 10 + 20 + 45 + 12 = 87、job 無しなので modifier 1.0
        self.assertEqual(atk, 87)


class FallbackVisibilityTest(TestCase):
    """🔴 Pre-mortem #6 —— フォールバックが効いたことが**画面で分かる**こと。

    黙って 10 を返すと admin では「武器を装備している」と誤読される。
    """

    def setUp(self):
        self.user = User.objects.create_user('bsp_fb', email='bspfb@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='FB')
        self.player.battle.level = 3
        self.player.battle.save(update_fields=['level'])

    def test_no_weapon_no_job_no_stats(self):
        result = compute_player_battle_stats(self.player)
        i, stats = result['inputs'], result['stats']

        # 未装備は 0 ではなく 10 (Dart の `?? 10`)。ただし旗を立てる。
        self.assertTrue(i['weapon_missing'])
        self.assertIsNone(i['weapon'])
        self.assertEqual(i['weapon_atk'], UNEQUIPPED_WEAPON_ATK)

        # ジョブ未設定は **modifier 1.0**。
        # ⚠️ Dart の `Job.fallback` (warrior / 1.3) ではない ——
        #    Backend の `_serialize_job(None)` が 1.0 を送るので、端末が
        #    実際に使うのは 1.0 のほう。
        self.assertTrue(i['job_missing'])
        self.assertEqual(i['attack_power_modifier'], 1.0)
        self.assertEqual(i['atb_speed_modifier'], 1.0)

        # stat 行が 1 つも無ければ **0** 扱い (CharacterStat の default 1 ではない)。
        self.assertEqual(len(i['missing_stats']), 6)
        self.assertTrue(all(v == 0 for v in i['stat_levels'].values()))

        # base = 10 + 3*2 + 10 + 0 = 26
        self.assertEqual(stats['atk'], 26)
        self.assertEqual(stats['max_hp'], 200 + 3 * 20)
        self.assertAlmostEqual(stats['atb_modifier'], 1.0)
        self.assertEqual(stats['hp_regen_per_turn'], 0)

    def test_character_without_job_is_also_a_fallback(self):
        char = Character.objects.create(
            key='bsp_nojob', name='ジョブ無し', role='テスト',
            image_path='x.png', job=None,
        )
        self.player.active_character = char
        self.player.save(update_fields=['active_character'])

        i = compute_player_battle_stats(self.player)['inputs']
        self.assertTrue(i['job_missing'])
        self.assertIsNotNone(i['active_character'])
        self.assertEqual(i['attack_power_modifier'], 1.0)

    def test_does_not_read_active_job(self):
        """🔴 §4 / FEAT-430 —— `PlayerProfile.active_job` を読まないこと。

        `active_job` にだけ dark_mage を入れ、`active_character` は未設定にする。
        読んでしまっていれば modifier が 1.5 になる。
        """
        self.player.active_job = Job.objects.get(job_id='dark_mage')
        self.player.active_character = None
        self.player.save(update_fields=['active_job', 'active_character'])

        i = compute_player_battle_stats(self.player)['inputs']
        self.assertTrue(i['job_missing'],
                        'active_job を読んでしまっている (FEAT-430 違反)')
        self.assertEqual(i['attack_power_modifier'], 1.0)


class AdminSectionTest(TestCase):
    """admin 側の配線 (Phase 7-2)。

    HTTP ではなく `ModelAdmin` を直接叩く。admin は MFA middleware の内側なので、
    ここで見たいこと (描画内容 / クエリ数 / list への混入) には HTTP は不要。
    """

    def setUp(self):
        from django.contrib import admin as django_admin

        self.user = User.objects.create_user('bsp_admin', email='bspadm@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='ADM')
        self.player.battle.level = 12
        self.player.battle.save(update_fields=['level'])
        self.admin = django_admin.site._registry[PlayerProfile]

    def test_admin_check_has_no_errors(self):
        """🔴 Pre-mortem #5 —— `admin.E121` を出さないこと。

        read-only の計算列を `list_editable` に混ぜると check が落ち、
        `build.sh` の migrate が止まって**デプロイ不能**になる (EnemyAdmin に前例)。
        """
        self.assertEqual(self.admin.check(), [])

    def test_preview_is_not_in_list_display_or_list_editable(self):
        """🔴 Pre-mortem #4 / #5 —— 一覧に混入していないこと。

        `list_display` に入れると 1 行ごとに CharacterStat 6 件 + PlayerWeapon +
        Character + Job を引いて N+1 になる。`list_editable` は上記のとおり
        check が落ちる。
        """
        self.assertIn('battle_stats_preview', self.admin.readonly_fields)
        self.assertNotIn('battle_stats_preview', self.admin.list_display)
        self.assertNotIn('battle_stats_preview',
                         getattr(self.admin, 'list_editable', ()))

    def test_renders_inputs_and_results(self):
        """結果だけでなく**入力も**出ていること (§7-2)。"""
        weapon = WeaponMaster.objects.create(
            key='bsp_adm_sword', name='監査の剣', atk_bonus=30,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=weapon, is_equipped=True,
        )
        CharacterStat.objects.create(player=self.player, name='運動力', level=4)

        html = str(self.admin.battle_stats_preview(self.player))

        # 入力
        self.assertIn('監査の剣', html)
        self.assertIn('30', html)
        self.assertIn('運動力 4', html)
        # 結果 (maxHP = 200 + 12*20 + 4*5 = 460)
        self.assertIn('460', html)
        # 注記 (ミラーであること / 「今の値」であること)
        self.assertIn('端末が計算しています', html)
        self.assertIn('今の値', html)

    def test_fallbacks_are_visible_not_silent(self):
        """🔴 Pre-mortem #6 —— 黙って 10 を出さない。"""
        html = str(self.admin.battle_stats_preview(self.player))
        self.assertIn('未装備', html)
        self.assertIn('ジョブ未解決', html)
        self.assertIn('0 として計算', html)

    def test_add_form_does_not_explode(self):
        """追加画面 (obj が未保存) でも例外にしない。"""
        self.assertIn('—', str(self.admin.battle_stats_preview(PlayerProfile())))
        self.assertIn('—', str(self.admin.battle_stats_preview(None)))

    def test_detail_render_query_count(self):
        """詳細 1 件あたりのクエリ数を固定する (§8「クエリ数を報告に書く」)。

        admin が実際に使う queryset (`get_queryset` の `select_related` 込み) で
        **フル装備のプレイヤー**を描画したときの本数を縛る。
        増えたら気づけることが目的で、絶対値そのものが目的ではない。
        """
        from django.test import RequestFactory

        weapon = WeaponMaster.objects.create(
            key='bsp_q_sword', name='計測の剣', atk_bonus=20,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=weapon, is_equipped=True,
        )
        job = Job.objects.get(job_id='dark_mage')
        char = Character.objects.create(
            key='bsp_q_char', name='計測キャラ', role='テスト',
            image_path='x.png', job=job,
        )
        self.player.active_character = char
        self.player.save(update_fields=['active_character'])
        for name in ('運動力', '学習力', '健康力', '精神力', '創造力', '貢献力'):
            CharacterStat.objects.create(player=self.player, name=name, level=3)

        request = RequestFactory().get('/admin/api/playerprofile/1/change/')
        request.user = self.user
        player = self.admin.get_queryset(request).get(pk=self.player.pk)

        # 1. CharacterStat 6 件を 1 本
        # 2. PlayerWeapon
        # 3. PlayerBattleState (`player.battle`)
        # 4. WeaponMaster (equipped.weapon の FK 解決)
        #
        # active_character / job は `select_related` 済で 0 本。
        # ⚠️ 3 は `select_related('battle_state')` では消せない —— `player.battle` は
        #    FEAT-478 の @property shim (`get_or_create`) で逆参照を見ないため。
        with self.assertNumQueries(4):
            self.admin.battle_stats_preview(player)

    def test_admin_queryset_prefetches_job(self):
        """一覧 / 詳細の queryset が `active_character__job` を 1 本にまとめている。

        ⚠️ 【FEAT-540 (2026-09-06)】**完全一致の assert をやめた。**
        旧実装は `select_related` の dict を丸ごと固定していたため、
        **別の列が正当に足されただけで落ちる**（実際 FEAT-540 が
        「最終アクティブ」列のために `streak_state` を足して落ちた）。

        このテストが守りたいのは「`active_character__job` が 1 本に
        まとまっていること」であって「他に何も足さないこと」ではない。
        個別に `assertIn` して、**落とされたら気づく / 足されても落ちない**形にする。
        """
        from django.test import RequestFactory

        request = RequestFactory().get('/admin/api/playerprofile/')
        request.user = self.user
        qs = self.admin.get_queryset(request)
        self.assertEqual(
            qs.query.select_related.get('active_character'), {'job': {}},
            msg='個票が読む active_character.job が 1 本にまとまっていない',
        )
        # 【FEAT-540】最終アクティブ列のための逆参照。
        # ⚠️ `player.battle` (shim) と違い `obj.streak_state` は逆参照そのものなので
        #    select_related が効く。落とすと一覧が N+1 に戻る。
        self.assertIn(
            'streak_state', qs.query.select_related,
            msg='FEAT-540 の最終アクティブ列が N+1 に戻っている',
        )


# 【2026-08-29 CI hotfix】staticfiles を素の storage に落とす。
#
# 本番設定は `config.storage.WhiteNoiseStaticFilesStorage`
# (CompressedManifestStaticFilesStorage 派生) で、admin テンプレートの
# `{% static %}` が **collectstatic 済みの STATIC_ROOT** を前提にする。
# CI は collectstatic を回さないので
#   ValueError: The file 'admin/css/base.css' could not be found
# で 500 になる (ローカルは collect 済みなので緑になり、CI だけ落ちた)。
#
# 本テストが見たいのは**自分が足した admin セクションが描画されるか**であって、
# 静的ファイルのパイプラインではない。依存を切る。
@override_settings(STORAGES={
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {
        'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage',
    },
})
class AdminChangePageSmokeTest(TestCase):
    """🔴 変更画面が実際に 200 で返ること。

    `battle_stats_preview()` を直接呼ぶ単体テストだけだと、**テンプレート段階で
    落ちるケースを取りこぼす** (readonly callable の戻り値の扱い / inline との
    組み合わせ等)。admin が 500 になるのはデプロイしてから気づく類の事故なので、
    HTTP でも 1 本通しておく。

    admin MFA は**無効化せず**、session に verified タイムスタンプを入れて通す。
    gate ごと切ってしまうと「MFA を通った後の画面」を見たことにならない。
    """

    def setUp(self):
        # `force_login` を使うのでパスワードは要らない。
        # 実値を書くと Portfolio Publish Gate の「汎用パスワード実値」に引っかかる
        # (2026-08-29 に実際に落とした)。
        self.admin_user = User.objects.create_user(
            'bsp_super', email='bspsuper@example.com',
            is_staff=True, is_superuser=True,
        )
        self.target_user = User.objects.create_user(
            'bsp_target', email='bsptarget@example.com',
        )
        self.player = PlayerProfile.objects.create(
            user=self.target_user, name='SMOKE',
        )
        self.player.battle.level = 7
        self.player.battle.save(update_fields=['level'])

    def _get_change_page(self):
        from django.urls import reverse
        from django.utils import timezone

        from api.middleware.admin_mfa import MFA_SESSION_KEY

        self.client.force_login(self.admin_user)
        session = self.client.session
        session[MFA_SESSION_KEY] = timezone.now().isoformat()
        session.save()
        return self.client.get(
            reverse('admin:api_playerprofile_change', args=[self.player.pk])
        )

    def test_change_page_renders_the_section(self):
        res = self._get_change_page()
        self.assertEqual(res.status_code, 200)
        html = res.content.decode('utf-8')
        self.assertIn('バトルステータス', html)
        # maxHP = 200 + 7*20 = 340
        self.assertIn('340', html)
        # フォールバックが画面に出ている (Pre-mortem #6)
        self.assertIn('未装備', html)

    def test_change_page_renders_for_a_fully_equipped_player(self):
        weapon = WeaponMaster.objects.create(
            key='bsp_smoke_sword', name='煙の剣', atk_bonus=18,
        )
        PlayerWeapon.objects.create(
            player=self.player, weapon=weapon, is_equipped=True,
        )
        char = Character.objects.create(
            key='bsp_smoke_char', name='煙キャラ', role='テスト',
            image_path='x.png', job=Job.objects.get(job_id='dark_mage'),
        )
        self.player.active_character = char
        self.player.save(update_fields=['active_character'])
        CharacterStat.objects.create(player=self.player, name='学習力', level=9)

        res = self._get_change_page()
        self.assertEqual(res.status_code, 200)
        html = res.content.decode('utf-8')
        self.assertIn('煙の剣', html)
        # base = 10 + 7*2 + 18 + 9 = 51 → 51 x 1.5 = 76.5 → 77 (half away from zero)
        self.assertIn('77', html)
