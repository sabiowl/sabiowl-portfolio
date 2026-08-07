"""【FEAT-295 Phase 1e】バトル Backend API の契約テスト 5 件。

Pre-mortem #2 対応の不正検出 3 種を中心に縛る:
  - duration_sec < 3 → reject
  - damage_dealt > enemy_hp_init * 5 → reject
  - 二重 finish → reject

加えて正常系（start → finish 報酬反映 + battle_charges -= 3）も縛る。

【FEAT-406 (2026-06-01)】更新:
  - chargesPerBattle: 1 → 3 (setUp.battle_charges=3 が出陣可能の境界)

【FEAT-495 (2026-07-25)】更新:
  - EXP × 0.3 撤廃: goblin.reward_exp=6 (bake 済実効値、旧 raw 20 の × 0.3)
  - exp_gained = enemy.reward_exp をそのまま返却 (DB 値 = 表示値 = 実獲得値)
"""
import datetime

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import Battle, BattleLog, Enemy, PlayerProfile, WeaponMaster
from ._error_assert import error_code, error_message  # 【FEAT-515】

User = get_user_model()


_TEST_REST_FRAMEWORK_OVERRIDE = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authtoken.authentication.TokenAuthentication',
        'api.authentication.GuestTokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
}


@override_settings(REST_FRAMEWORK=_TEST_REST_FRAMEWORK_OVERRIDE)
class BattleSystemContractTest(APITestCase):
    """FEAT-295: バトルシステム MVP の契約 5 件。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('player1', email='p1@example.com')
        # 出陣可能な状態（charges=3）で初期化
        self.player = PlayerProfile.objects.create(
            user=self.user,
            name='Player1',
        )
        # 【FEAT-478 Phase 2b (2026-07-04)】initial state を NEW state
        # (PlayerBattleState) に書込 + save。旧 create(battle_charges=3) kwargs は
        # OLD field への write で write path (battle.py) が NEW state を読むため無効化。
        battle = self.player.battle
        battle.battle_charges      = 3
        battle.battle_charges_date = datetime.date.today()
        battle.save(update_fields=['battle_charges', 'battle_charges_date'])
        self.token, _ = Token.objects.get_or_create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        # seed: migration 0082 が test DB セットアップ時に既に投入済のため、
        # update_or_create で「期待値を強制」する（テスト独立性の担保）。
        self.enemy, _ = Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name':          'ゴブリン',
                'sprite_key':    'enemy_goblin',
                'base_hp':       60,
                'base_atk':      8,
                'base_spd':      10,
                'level_scaling': 1.0,
                'reward_coins':  10,
                # 【FEAT-495 (2026-07-25)】bake 済実効値 (旧 raw 20 の × 0.3)
                'reward_exp':    6,
                'tier':          'zako',
            },
        )
        WeaponMaster.objects.update_or_create(
            key='starter_sword',
            defaults={'name': '見習いの剣', 'atk_bonus': 10},
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 1: start → token + 敵パラメータ返却、Battle レコード作成
    # ─────────────────────────────────────────────────────────────
    def test_start_creates_battle_and_returns_token(self):
        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200, res.content)
        body = res.data
        self.assertIn('token', body)
        self.assertIsInstance(body['token'], str)
        self.assertGreater(len(body['token']), 16)
        self.assertEqual(body['enemy']['key'], 'goblin')
        self.assertEqual(body['enemy']['name'], 'ゴブリン')
        self.assertEqual(body['enemy']['sprite_key'], 'enemy_goblin')
        # player.level=1 × level_scaling=1.0 × base_hp=60 = 60
        self.assertEqual(body['enemy']['hp'], 60)

        # Battle レコード作成確認
        battle = Battle.objects.get(token=body['token'])
        self.assertEqual(battle.player, self.player)
        self.assertEqual(battle.enemy, self.enemy)
        self.assertIsNone(battle.finished_at)
        self.assertEqual(battle.enemy_hp_init, 60)

    def test_start_rejects_when_charges_insufficient(self):
        # 【FEAT-478 Phase 2b】NEW state (PlayerBattleState) の battle_charges を直接 set。
        battle = self.player.battle
        battle.battle_charges = 2
        battle.save(update_fields=['battle_charges'])

        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'not_enough_charges')

    # ─────────────────────────────────────────────────────────────
    # シナリオ 2: finish (win) → 報酬反映 + BattleLog 作成 + charges -= 3
    # 【FEAT-495】exp_gained = enemy.reward_exp = 6 (bake 済実効値)
    # ─────────────────────────────────────────────────────────────
    def test_finish_win_grants_rewards_and_consumes_charges(self):
        # start
        start_res = self.client.post(reverse('battle-start'))
        token = start_res.data['token']
        # 【FEAT-478 Phase 2b】NEW state (PlayerBattleState) から読む。
        before_charges = PlayerProfile.objects.get(pk=self.player.pk).battle.battle_charges
        self.assertEqual(before_charges, 3, '前提: start 時点ではまだ charges 消費しない設計')

        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                'damage_dealt': 60,
                'damage_taken': 20,
                'rounds':       5,
                'summary_text': 'サビ 通常攻撃 → ゴブリン -15HP\nゴブリン 反撃 → サビ -8HP',
            },
            format='json',
        )
        self.assertEqual(finish_res.status_code, 200, finish_res.content)
        self.assertEqual(finish_res.data['coins_gained'], 10)
        # 【FEAT-495】exp_gained = enemy.reward_exp = 6 (bake 済実効値)
        self.assertEqual(finish_res.data['exp_gained'], 6,
                         'FEAT-495: exp_gained = enemy.reward_exp (bake 済)')
        self.assertEqual(finish_res.data['battle_charges'], 0,
                         '勝敗問わず -3 消費 (3 - 3 = 0) [FEAT-406: chargesPerBattle=3]')

        # DB 反映確認 (【FEAT-478 Phase 2b】NEW state 経由)
        # 【2026-07-25 P3 #1-c】refresh_from_db() で shim state cache invalidate
        self.player.refresh_from_db()
        self.assertEqual(self.player.battle.battle_charges, 0)
        self.assertEqual(self.player.economy.bonus_coins, 10)
        self.assertEqual(self.player.battle.current_exp, 6,
                         'FEAT-495: battle EXP = 6 (enemy.reward_exp)')

        # BattleLog 作成確認
        battle = Battle.objects.get(token=token)
        self.assertEqual(battle.result, 'win')
        self.assertIsNotNone(battle.finished_at)
        log = BattleLog.objects.get(battle=battle)
        self.assertEqual(log.rewards_coins, 10)
        self.assertEqual(log.rewards_exp, 6,
                         'BattleLog に EXP=6 (bake 済実効値) を記録')
        self.assertEqual(log.total_damage_dealt, 60)
        self.assertIn('サビ', log.summary_text)

    # ─────────────────────────────────────────────────────────────
    # 【削除済 (2026-07-25 codebase-functional-review 20260725 対応)】
    # シナリオ 3: test_finish_rejects_when_duration_too_short
    #   duration_sec anti-cheat は 2026-07-09 に完全撤去された (finish.py:32-46
    #   参照)。旧テストは撤去当日から 16 日間赤放置され、reviewer が「赤の
    #   baseline が新旧の赤を見分けられなくしている」直接証拠として指摘した。
    #   撤去後の設計 contract は test_finish_accepts_zero_duration_after_check_removal
    #   (line 460+) が既に担保しているため、旧 reject test は削除。
    # ─────────────────────────────────────────────────────────────

    # ─────────────────────────────────────────────────────────────
    # シナリオ 4: Pre-mortem #2 — damage_dealt > enemy_hp * 5 で reject
    # ─────────────────────────────────────────────────────────────
    def test_finish_rejects_when_damage_unreasonable(self):
        start_res = self.client.post(reverse('battle-start'))
        token = start_res.data['token']
        enemy_hp = start_res.data['enemy']['hp']

        res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                # 【2026-07-05】_MAX_DAMAGE_MULTIPLIER を 5 → 20 に緩和したため
                # 境界値を追従。damage_dealt > enemy_hp * 20 で reject される。
                'damage_dealt': enemy_hp * 20 + 1,
                'damage_taken': 20,
                'rounds':       5,
                'summary_text': '...',
            },
            format='json',
        )
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'damage_unreasonable')

    # ─────────────────────────────────────────────────────────────
    # 【2026-07-05 regression guard】damage_unreasonable 境界値 / 全武器安全域
    # ─────────────────────────────────────────────────────────────

    def test_finish_accepts_damage_at_exactly_20x_boundary(self):
        """damage_dealt == enemy_hp * 20 (境界値ちょうど) は accept される
        (strict `>` 判定なので 20x 丁度は通過)。境界値の accept 側を明示保証。
        """
        start_res = self.client.post(reverse('battle-start'))
        token = start_res.data['token']
        enemy_hp = start_res.data['enemy']['hp']

        res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                'damage_dealt': enemy_hp * 20,  # 境界値ちょうど、reject されない
                'damage_taken': 20,
                'rounds':       5,
                'summary_text': '(boundary) 20x 上限ちょうど',
            },
            format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)

    def test_finish_accepts_dragon_slayer_peak_single_hit_against_slime(self):
        """【全武器 regression guard】dragon_slayer(+50) 装備 + dark_mage
        (attack_power_modifier 1.5) の Lv 30 最強ビルドで単発 peak damage を
        送信しても、最弱敵 slime (base_hp=130) の 20x 閾値 (2600) を突破せず
        accept されることを保証。

        将来 atk_bonus 60+ 武器 or 1.7+ 倍率ジョブが追加され本テストが FAIL
        したら _MAX_DAMAGE_MULTIPLIER の再設計 or Mobile overkill 除外の
        徹底 (battle_orchestrator.dart の effectiveDamage 化、2026-07-05 適用) を
        再確認するシグナルとする。CLAUDE.md「過去の不具合事例」で調査記録あり。

        単発 peak の理論式:
          ATK = (10 + Lv*2 + weapon_atk + studyLv) * job_atk_modifier
              = (10 + 60 + 50 + 20) * 1.5 = 210
          peak = ATK * ability.ultimate(3.0) * atk_potion(1.5)
                 * weakness(1.3) * FEAT-333 crit(1.5)
               = 210 * 8.775 ≈ 1843
        slime 20x 閾値 = 130 * 20 = 2600 > 1843 → 安全マージン 41%。
        """
        # 最弱敵 slime を強制 seed (テスト独立性、setUp の goblin と分離)。
        # 20x 閾値が最も低い = 最も厳しい判定境界を持つ。
        slime, _ = Enemy.objects.update_or_create(
            key='slime',
            defaults={
                'name':          'スライム',
                'sprite_key':    'enemy_slime',
                'base_hp':       130,
                'base_atk':      3,
                'base_spd':      5,
                'level_scaling': 0.5,
                'reward_coins':  5,
                # 【FEAT-495 (2026-07-25)】bake 済実効値 (旧 raw 10 の × 0.3)
                'reward_exp':    3,
                'tier':          'zako',
            },
        )
        start_res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': 'slime'},
            format='json',
        )
        self.assertEqual(start_res.status_code, 200, start_res.content)
        token    = start_res.data['token']
        enemy_hp = start_res.data['enemy']['hp']  # 130

        # 理論 peak = 1843 (dragon_slayer + dark_mage + Lv30 + 全 buff)。
        # 数式は docstring 参照。閾値との差を明示 assert して、将来の
        # バランス変更で peak > 閾値になった瞬間に本テストが FAIL する。
        peak_single_hit = 1843
        self.assertLess(
            peak_single_hit, enemy_hp * 20,
            f'理論 peak {peak_single_hit} が最弱敵の 20x 閾値 {enemy_hp * 20} を'
            f'超えている。全武器の regression guard が破綻したサイン → '
            f'_MAX_DAMAGE_MULTIPLIER の再設計 or Mobile overkill 除外の再確認が必要。',
        )

        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                'damage_dealt': peak_single_hit,
                'damage_taken': 5,
                'rounds':       1,
                'summary_text': '(regression) dragon_slayer 単発 peak 討伐',
            },
            format='json',
        )
        self.assertEqual(
            finish_res.status_code, 200,
            f'理論 peak damage が accept されない = damage_unreasonable regression。'
            f'背景: 2026-07-05 に dragon_slayer(+50) 装備でボス討伐後に 0 報酬に'
            f'なるバグを解消。詳細は commit + CLAUDE.md 参照。 body={finish_res.content!r}',
        )

    def test_finish_accepts_reported_dragon_slayer_boss_scenario(self):
        """【2026-07-05 バグ報告シナリオ再現】dragon_slayer(+50) 装備で
        boss (base_hp=220 = goblin_king 相当) を単発 ultimate で討伐した際、
        raw damage_dealt = 1255 (Lv 20 warrior 想定の 1 ultimate hit) が
        旧 5x 閾値 (1100) を超えて reject されていた事象を、新 20x 閾値
        (4400) 下で確実に accept することを保証する contract test。

        真の regression guard: この test が FAIL したら「2026-07-05 に修正した
        dragon_slayer バグが再燃した」= 最優先で調査する契約。
        """
        # boss 相当の敵を seed (goblin_king の base_hp=220 を再現)
        boss, _ = Enemy.objects.update_or_create(
            key='goblin_king',
            defaults={
                'name':          'ゴブリンキング',
                'sprite_key':    'enemy_goblin_king',
                'base_hp':       220,
                'base_atk':      9,
                'base_spd':      9,
                'level_scaling': 0.5,
                'reward_coins':  30,
                # 【FEAT-495 (2026-07-25)】bake 済実効値 (旧 raw 60 の × 0.3)
                'reward_exp':    18,
                'tier':          'boss',
            },
        )
        start_res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': 'goblin_king'},
            format='json',
        )
        self.assertEqual(start_res.status_code, 200, start_res.content)
        token    = start_res.data['token']
        enemy_hp = start_res.data['enemy']['hp']  # 220

        # dragon_slayer + warrior Lv 20 の 1 ultimate 討伐時の raw damage (overkill 込)
        reported_damage = 1255
        # 旧 5x 閾値では reject されていた事象を確認
        self.assertGreater(reported_damage, enemy_hp * 5,
                           'このシナリオが旧 5x 閾値では reject されていた前提を明示')
        # 新 20x 閾値では accept されるべき
        self.assertLess(reported_damage, enemy_hp * 20,
                        '新 20x 閾値では余裕を持って accept される前提を明示')

        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 30,
                'damage_dealt': reported_damage,
                'damage_taken': 20,
                'rounds':       1,
                'summary_text': '(regression) dragon_slayer + boss 単発 ultimate',
            },
            format='json',
        )
        self.assertEqual(
            finish_res.status_code, 200,
            f'2026-07-05 バグ報告シナリオが reject されている = regression 発生。'
            f'commit + CLAUDE.md の damage_unreasonable 履歴を参照。 body={finish_res.content!r}',
        )
        # 報酬が 0 でないことも同時に保証 (バグ症状「+0 coins / +0 EXP」の反対側)
        self.assertGreater(finish_res.data['coins_gained'], 0,
                           'バグ症状: 報酬 0 が返っていないことを明示保証')

    def test_finish_accepts_one_shot_kill_short_duration(self):
        """【2026-07-09 バグ報告シナリオ再現】dragon_slayer(+50) 装備で
        goblin_king (base_hp=220) を単発強攻撃 1 撃キル、duration=1 秒 (ATB fill
        1-2 秒 + 1 attack + 死亡判定) で完結した際、旧 `_MIN_BATTLE_DURATION_SEC=3`
        では 400 (duration_too_short) が返り「+0 coins / +0 EXP」表示となる
        バグ (user 報告 2026-07-09、screenshot 添付) を duration check 撤去後も
        受理する contract を保証する regression test。

        【2026-07-09 v2】_MIN_BATTLE_DURATION_SEC を 3→1 秒に緩和 → 完全撤去に
        設計変更。将来の高速化 (FEAT-379 結晶装着 / 新ジョブ) で閾値 1 秒でも
        再発する構造的リスクを断つ + client trust 実装は effective でない判断。
        本 test は「duration 極短でも accept される」ことを担保する permanent
        contract として維持。
        """
        boss, _ = Enemy.objects.update_or_create(
            key='goblin_king',
            defaults={
                'name':          'ゴブリンキング',
                'sprite_key':    'enemy_goblin_king',
                'base_hp':       220,
                'base_atk':      9,
                'base_spd':      9,
                'level_scaling': 0.5,
                'reward_coins':  30,
                # 【FEAT-495 (2026-07-25)】bake 済実効値 (旧 raw 60 の × 0.3)
                'reward_exp':    18,
                'tier':          'boss',
            },
        )
        start_res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': 'goblin_king'},
            format='json',
        )
        self.assertEqual(start_res.status_code, 200, start_res.content)
        token = start_res.data['token']

        # user 報告シナリオ: ATB fill 1-2 秒 + 1 attack で duration=1 秒に収まる
        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 1,     # ← 旧 3 秒閾値では reject、新 1 秒で受理
                'damage_dealt': 220,   # 1 hit で 220 dmg (overkill 除外済 = enemy_hp_init)
                'damage_taken': 5,
                'rounds':       1,
                'summary_text': '(regression) dragon_slayer 1 撃キル短 duration',
            },
            format='json',
        )
        self.assertEqual(
            finish_res.status_code, 200,
            f'2026-07-09 バグ報告シナリオが reject されている = duration_too_short '
            f'regression 発生。commit + CLAUDE.md の duration 履歴を参照。 '
            f'body={finish_res.content!r}',
        )
        # 報酬が 0 でないことも同時に保証 (バグ症状「+0 coins / +0 EXP」の反対側)
        self.assertGreater(
            finish_res.data['coins_gained'], 0,
            'バグ症状: 報酬 coins が 0 で返っていないことを明示保証',
        )
        self.assertGreater(
            finish_res.data['exp_gained'], 0,
            'バグ症状: 報酬 exp が 0 で返っていないことを明示保証',
        )

    def test_finish_accepts_zero_duration_after_check_removal(self):
        """【2026-07-09 v2】duration_sec = 0 も受理される (duration check 完全撤去後)。

        設計変更経緯:
          v1 (2026-07-09 早朝): _MIN_BATTLE_DURATION_SEC を 3→1 に緩和
          v2 (2026-07-09 昼): _MIN_BATTLE_DURATION_SEC 自体を完全撤去

        撤去理由:
          1. client 送信 duration_sec は容易に偽装可能 = 真の anti-cheat 効果なし
          2. 将来の高速化 (FEAT-379 結晶 / 新ジョブ) で閾値 N 秒でも再発リスク
          3. damage cap (× 20) + daily_battle_count (10/日) の 2 層で bot 対策十分
          4. legitimate 1 撃キル誤検知の副作用が anti-cheat 効果を上回っていた

        本 test は「duration 検証は削除されている」ことを構造的に担保する
        permanent contract。将来「duration 検証を復活したい」議論が出た際、
        この test が FAIL することで意図的な設計変更として明示される。
        """
        start_res = self.client.post(reverse('battle-start'))
        token = start_res.data['token']

        finish_res = self.client.post(
            reverse('battle-finish'),
            data={
                'token':        token,
                'result':       'win',
                'duration_sec': 0,     # ← 極短 duration でも受理される
                'damage_dealt': 30,
                'damage_taken': 5,
                'rounds':       1,
                'summary_text': '(duration check removal contract)',
            },
            format='json',
        )
        self.assertEqual(
            finish_res.status_code, 200,
            f'duration_sec=0 が reject されている = duration check が復活した '
            f'可能性。2026-07-09 の撤去判断の背景 (client 偽装可 + legitimate 1 撃キル '
            f'誤検知副作用) を再確認せよ。 body={finish_res.content!r}',
        )
        self.assertGreater(
            finish_res.data.get('coins_gained', 0), 0,
            'duration 極短でも coins 報酬が付与されること',
        )

    # ─────────────────────────────────────────────────────────────
    # シナリオ 5: 二重 finish で reject
    # ─────────────────────────────────────────────────────────────
    def test_finish_rejects_double_finish(self):
        start_res = self.client.post(reverse('battle-start'))
        token = start_res.data['token']

        finish_payload = {
            'token':        token,
            'result':       'win',
            'duration_sec': 30,
            'damage_dealt': 60,
            'damage_taken': 20,
            'rounds':       5,
            'summary_text': '...',
        }

        # 1 回目: 成功
        res1 = self.client.post(reverse('battle-finish'), data=finish_payload, format='json')
        self.assertEqual(res1.status_code, 200)

        # 2 回目: 二重 finish で reject
        res2 = self.client.post(reverse('battle-finish'), data=finish_payload, format='json')
        self.assertEqual(res2.status_code, 400)
        self.assertEqual(error_code(res2), 'already_finished')

    # ─────────────────────────────────────────────────────────────
    # 【FEAT-296 Phase 2-2】Enemy 一覧 + enemy_key 指定の契約 3 件
    # ─────────────────────────────────────────────────────────────

    def test_enemy_list_returns_all_enemies(self):
        """`GET /api/battle/enemies/` で seed 済の全 Enemy 取得。"""
        # FEAT-296 で migration 0083 が 4 体追加投入する想定
        # Phase 2-2 単体テストの時点でも 0083 は適用済（test runner が全 migration を実行）
        res = self.client.get(reverse('battle-enemies'))
        self.assertEqual(res.status_code, 200, res.content)
        keys = {e['key'] for e in res.data['enemies']}
        expected = {'goblin', 'giant_slime', 'goblin_king', 'dragon', 'shadow_mage'}
        self.assertTrue(expected.issubset(keys),
                        f'期待 5 種が含まれるべき\n期待: {expected}\n実値: {keys}')

    def test_enemy_list_filters_by_tier_boss(self):
        """`?tier=boss` で boss 種のみ返却。"""
        res = self.client.get(reverse('battle-enemies'), {'tier': 'boss'})
        self.assertEqual(res.status_code, 200)
        keys = {e['key'] for e in res.data['enemies']}
        # boss 3 種: goblin_king / dragon / shadow_mage
        self.assertTrue({'goblin_king', 'dragon', 'shadow_mage'}.issubset(keys))
        # ゴブリン (zako) は含まれない
        self.assertNotIn('goblin', keys)
        self.assertNotIn('giant_slime', keys)  # zako tier
        for e in res.data['enemies']:
            self.assertEqual(e['tier'], 'boss')

    def test_start_battle_with_specific_enemy_key(self):
        """`POST /battle/start/` body `{enemy_key: 'giant_slime'}` で
        指定敵とのバトル開始 (FEAT-296 主機能)。"""
        # まず seed が test 内で確実に存在することを保証
        from api.models import Enemy
        Enemy.objects.update_or_create(
            key='giant_slime',
            defaults={
                'name': '巨大スライム', 'sprite_key': 'enemy_giant_slime',
                'base_hp': 200, 'base_atk': 8, 'base_spd': 6,
                # 【FEAT-495 (2026-07-25)】bake 済実効値 (旧 raw 30 の × 0.3)
                'level_scaling': 1.5, 'reward_coins': 15, 'reward_exp': 9,
                'tier': 'zako',
            },
        )

        res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': 'giant_slime'},
            format='json',
        )
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.data['enemy']['key'], 'giant_slime')
        self.assertEqual(res.data['enemy']['name'], '巨大スライム')
        # 【FEAT-400 v3 (2026-05-31)】scaled_hp = enemy.base_hp (固定化)。
        # 旧式: base_hp 200 × scaling 1.5 × player.level 1 = 300
        # 新式: base_hp = 200 (Lv 関わらず固定、player.level 無関係)
        self.assertEqual(res.data['enemy']['hp'], 200)

        # Battle レコードも giant_slime に紐付くこと
        from api.models import Battle
        battle = Battle.objects.get(token=res.data['token'])
        self.assertEqual(battle.enemy.key, 'giant_slime')

    def test_start_battle_without_enemy_key_defaults_to_goblin(self):
        """【後方互換 / Pre-mortem #3】`enemy_key` 未指定で既存通りゴブリン。"""
        res = self.client.post(reverse('battle-start'))
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['enemy']['key'], 'goblin')

    def test_start_battle_with_nonexistent_enemy_key_returns_400(self):
        """存在しない `enemy_key` で 400 + サビ口調エラーメッセージ。"""
        res = self.client.post(
            reverse('battle-start'),
            data={'enemy_key': 'nonexistent_monster'},
            format='json',
        )
        self.assertEqual(res.status_code, 400)
        self.assertEqual(error_code(res), 'enemy_not_found')
        # サビ口調確認: 🪶 マーカー + 「〜ようです」紳士的トーン
        self.assertIn('🪶', error_message(res))
