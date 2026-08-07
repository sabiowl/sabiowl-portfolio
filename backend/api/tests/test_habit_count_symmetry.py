"""【FEAT-289】 HabitCountView / ChecklistItemToggleView 対称性契約テスト。

過去 4 ヶ月で 5 件のバグ起源 (FEAT-229 / FEAT-239 / BUG-A / BUG-2026-0512-02 /
BUG-K) を構造解決するための CI ガード。`services.habit_count_service.
apply_count_change` への中央化により、本テストが緑である限り 2 経路の対称性が
保たれることを契約として縛る。

検証シナリオ:
    A: count habit を +1 → -1 → +1 と、checklist habit を check ON → OFF → ON
       した時、両者で player.current_exp / HabitLog.count / habit.streak が
       一致する (= 構造的対称性)
    B: +1 → -1 → +1 → -1 ... を 10 回反復しても player.current_exp は
       最初の状態に戻る (= BUG-A 「EXP 無制限増殖」を構造的防止)
    C: 【BUG-96 (2026-06-12)】HabitCountView (count 経路) と
       ChecklistItemToggleView (checklist 経路) はどちらも plus / check ON で
       battle_charges +1 する (両経路で完全対称、旧 FEAT-289 の
       「checklist は battle_charges スキップ」は撤回済み)
"""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.utils import timezone
from rest_framework import status as http_status
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import ChecklistItem, Habit, HabitLog, PlayerProfile
from api.services.exp_service import create_default_stats

User = get_user_model()


# Throttle を切る (HabitCountView の habit_action scope が反復テストで効くため)
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
class HabitCountSymmetryContractTest(APITestCase):
    """count 経路 (HabitCountView) と checklist 経路 (ChecklistItemToggleView)
    の対称性契約。"""

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username='sym_tester', password='pw')
        # Legendary 難易度を使わないので level=10 で十分。max_exp=10000 で
        # 1 回のテスト内では level-up しないようにマージンを取る。
        self.player = PlayerProfile.objects.create(
            user=self.user,
            level=10,
            max_exp=10000,
            mode='training',
        )
        create_default_stats(self.player)
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

    # ─────────────────────────────────────────────────────────────────
    # ヘルパー
    # ─────────────────────────────────────────────────────────────────

    def _create_count_habit(self) -> Habit:
        return Habit.objects.create(
            player=self.player,
            name='count_h',
            category='運動',
            difficulty='normal',
            habit_type='count',
            frequency='daily',
            reset_cycle='daily',
        )

    def _create_checklist_habit(self) -> tuple[Habit, ChecklistItem]:
        habit = Habit.objects.create(
            player=self.player,
            name='checklist_h',
            category='運動',
            difficulty='normal',
            habit_type='checklist',
            frequency='daily',
            reset_cycle='daily',
        )
        item = ChecklistItem.objects.create(habit=habit, text='step 1')
        return habit, item

    def _post_count(self, habit_pk: int, action: str):
        return self.client.post(
            f'/api/habits/{habit_pk}/count/',
            {'action': action},
            format='json',
        )

    def _post_checklist_toggle(self, habit_pk: int, item_pk: int):
        return self.client.post(
            f'/api/habits/{habit_pk}/checklist/{item_pk}/toggle/',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ A: count と checklist で同等遷移後の最終状態が一致する
    # ─────────────────────────────────────────────────────────────────

    def test_count_path_and_checklist_path_yield_equivalent_exp_and_streak(self):
        """count habit を +1 → -1 → +1、checklist habit を ON → OFF → ON した
        最終状態で、player.current_exp の **差分**, HabitLog.count, habit.streak
        が両者で一致することを縛る。

        (絶対値ではなく差分で比較するのは、両 habit が独立に EXP を player に
         加算するため。差分が同等 ⇔ 同じ EXP 経路を辿った証拠。)
        """
        # ── count 経路 ────────────────────────────────────────────────
        baseline_exp = PlayerProfile.objects.get(pk=self.player.pk).battle.current_exp
        h_count = self._create_count_habit()

        self.assertEqual(self._post_count(h_count.pk, 'plus').status_code, 200)
        self.assertEqual(self._post_count(h_count.pk, 'minus').status_code, 200)
        self.assertEqual(self._post_count(h_count.pk, 'plus').status_code, 200)

        count_player = PlayerProfile.objects.get(pk=self.player.pk)
        count_exp_delta = count_player.battle.current_exp - baseline_exp
        count_log = HabitLog.objects.get(habit=h_count, date=timezone.localdate())
        h_count.refresh_from_db()

        # ── checklist 経路 (player.current_exp はここでさらに加算される) ─
        baseline_exp_2 = count_player.battle.current_exp
        h_check, item = self._create_checklist_habit()

        self.assertEqual(self._post_checklist_toggle(h_check.pk, item.pk).status_code, 200)  # ON
        self.assertEqual(self._post_checklist_toggle(h_check.pk, item.pk).status_code, 200)  # OFF
        self.assertEqual(self._post_checklist_toggle(h_check.pk, item.pk).status_code, 200)  # ON

        check_player = PlayerProfile.objects.get(pk=self.player.pk)
        check_exp_delta = check_player.battle.current_exp - baseline_exp_2
        check_log = HabitLog.objects.get(habit=h_check, date=timezone.localdate())
        h_check.refresh_from_db()

        # ── 対称性検証: EXP delta / HabitLog.count / habit.streak が一致 ───
        self.assertEqual(
            count_exp_delta, check_exp_delta,
            f'count 経路と checklist 経路で player.current_exp 増分が乖離: '
            f'count={count_exp_delta}, checklist={check_exp_delta} '
            '(BUG-A / BUG-2026-0512-02 系の bonus_exp 非対称が再発した可能性)',
        )
        self.assertEqual(
            count_log.count, check_log.count,
            f'HabitLog.count: count={count_log.count}, checklist={check_log.count} '
            '(両経路で +1 → -1 → +1 後は count=1 が期待値)',
        )
        self.assertEqual(count_log.count, 1)
        self.assertEqual(
            h_count.streak, h_check.streak,
            f'habit.streak: count={h_count.streak}, checklist={h_check.streak} '
            '(両経路で初日達成のため streak=1 が期待値)',
        )
        self.assertEqual(h_count.streak, 1)

    # ─────────────────────────────────────────────────────────────────
    # シナリオ B: +1 / -1 反復で EXP 漏れがない (BUG-A 構造防止)
    # ─────────────────────────────────────────────────────────────────

    def test_repeated_plus_minus_does_not_leak_exp_count_path(self):
        """count habit に対し +1 / -1 を 10 回反復すると player.current_exp が
        最初の値に戻る。BUG-A の「stat bonus / adventure bonus が non-対称で
        EXP が無制限に増殖する」を構造的に防止。"""
        habit = self._create_count_habit()
        initial_exp = PlayerProfile.objects.get(pk=self.player.pk).battle.current_exp

        for _ in range(10):
            self.assertEqual(self._post_count(habit.pk, 'plus').status_code, 200)
            self.assertEqual(self._post_count(habit.pk, 'minus').status_code, 200)

        final = PlayerProfile.objects.get(pk=self.player.pk)
        self.assertEqual(
            final.battle.current_exp, initial_exp,
            f'+1/-1 10 回反復後の EXP が変化: initial={initial_exp}, '
            f'final={final.battle.current_exp} (BUG-A の bonus_exp 非対称が再発した可能性)',
        )

    def test_repeated_check_toggle_does_not_leak_exp_checklist_path(self):
        """checklist habit を ON/OFF 反復しても EXP が最初の値に戻る。
        BUG-2026-0512-02 (checklist 経路の bonus_exp 非対称) の構造防止。"""
        habit, item = self._create_checklist_habit()
        initial_exp = PlayerProfile.objects.get(pk=self.player.pk).battle.current_exp

        for _ in range(10):
            self.assertEqual(
                self._post_checklist_toggle(habit.pk, item.pk).status_code, 200,
            )  # ON
            self.assertEqual(
                self._post_checklist_toggle(habit.pk, item.pk).status_code, 200,
            )  # OFF

        final = PlayerProfile.objects.get(pk=self.player.pk)
        self.assertEqual(
            final.battle.current_exp, initial_exp,
            f'checklist ON/OFF 10 回反復後の EXP が変化: initial={initial_exp}, '
            f'final={final.battle.current_exp} (BUG-2026-0512-02 の checklist 非対称が再発)',
        )

    # ─────────────────────────────────────────────────────────────────
    # シナリオ C: 【BUG-96】battle_charges 加算の対称性契約
    # ─────────────────────────────────────────────────────────────────

    def test_battle_charges_plus_one_on_both_count_and_checklist_paths(self):
        """count 経路・checklist 経路ともに plus / check ON で battle_charges +1 する。

        【BUG-96 (2026-06-12)】旧 FEAT-289 の「checklist は battle_charges
        スキップ (既存挙動踏襲)」を撤回し、count と完全同等に加算する。"""
        # ── count 経路: plus で battle_charges +1 ────────────────────
        before_count = PlayerProfile.objects.get(pk=self.player.pk).battle.battle_charges
        h_count = self._create_count_habit()
        self.assertEqual(self._post_count(h_count.pk, 'plus').status_code, 200)
        after_count = PlayerProfile.objects.get(pk=self.player.pk).battle.battle_charges
        self.assertEqual(
            after_count, before_count + 1,
            f'count plus で battle_charges +1 されない: {before_count} → {after_count}',
        )

        # ── checklist 経路: toggle ON でも battle_charges +1 (BUG-96) ──
        before_check = after_count
        h_check, item = self._create_checklist_habit()
        self.assertEqual(self._post_checklist_toggle(h_check.pk, item.pk).status_code, 200)
        after_check = PlayerProfile.objects.get(pk=self.player.pk).battle.battle_charges
        self.assertEqual(
            after_check, before_check + 1,
            f'checklist ON で battle_charges +1 されない: {before_check} → {after_check} '
            '(BUG-96 契約に違反)',
        )

    # ─────────────────────────────────────────────────────────────────
    # 補助シナリオ: minus 連打の冪等性 (BUG-2026-01 構造維持)
    # ─────────────────────────────────────────────────────────────────

    def test_minus_on_empty_log_is_idempotent(self):
        """まだ達成していない count habit に minus を連打しても
        EXP / streak が破壊されない (BUG-2026-01 の構造維持)。"""
        habit = self._create_count_habit()
        initial_exp = PlayerProfile.objects.get(pk=self.player.pk).battle.current_exp
        initial_streak = habit.streak

        for _ in range(5):
            res = self._post_count(habit.pk, 'minus')
            self.assertEqual(
                res.status_code, http_status.HTTP_200_OK,
                f'minus on empty log should be idempotent 200, got {res.status_code}: {res.data}',
            )
            self.assertEqual(res.data['diamond_earned'], False)
            self.assertEqual(res.data['exp_gain'], 0)

        final = PlayerProfile.objects.get(pk=self.player.pk)
        self.assertEqual(final.battle.current_exp, initial_exp)
        habit.refresh_from_db()
        self.assertEqual(habit.streak, initial_streak)
