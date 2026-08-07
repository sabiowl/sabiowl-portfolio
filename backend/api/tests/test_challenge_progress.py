"""【FEAT-465→FEAT-466 (2026-06-24)】月次カテゴリチャレンジ進捗加算の契約テスト。

`challenge_progress_service.increment_challenge_progress` を中心に、
1 ユーザー 1 日 1 回ガード / カテゴリ別独立加算 / 終了済・非アクティブ除外 /
ToDo 除外 / ゲストユーザー対応を縛る (指示書 §5-1 C1-C8)。
"""
from datetime import date, timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import Challenge, ChallengeParticipation, Habit, PlayerProfile
from api.services.challenge_progress_service import increment_challenge_progress
from api.services.habit_count_service import apply_count_change

User = get_user_model()


class IncrementChallengeProgressTest(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='t', password='p')
        self.player = PlayerProfile.objects.create(user=self.user, name='T')
        self.today = date(2026, 7, 15)
        self.exercise_challenge = Challenge.objects.create(
            title='7 月運動チャレンジ', description='desc', category='運動',
            is_tiered=False, target_count_gold=100, reward_exp_gold=500,
            start_date=date(2026, 7, 1), end_date=date(2026, 7, 31),
        )

    # C1: 運動カテゴリの習慣達成 → 運動チャレンジに +1
    def test_C1_increments_matching_category_challenge(self):
        increment_challenge_progress(self.player, '運動', self.today)

        self.exercise_challenge.refresh_from_db()
        self.assertEqual(self.exercise_challenge.current_count, 1)
        participation = ChallengeParticipation.objects.get(
            player=self.player, challenge=self.exercise_challenge,
        )
        self.assertEqual(participation.contribution_count, 1)
        self.assertEqual(participation.last_contribution_date, self.today)

    # C2: 学習カテゴリの達成 → 学習チャレンジに +1 + 運動チャレンジは不変
    def test_C2_only_matching_category_incremented(self):
        study_challenge = Challenge.objects.create(
            title='7 月学習チャレンジ', description='desc', category='学習',
            is_tiered=False, target_count_gold=100, reward_exp_gold=500,
            start_date=date(2026, 7, 1), end_date=date(2026, 7, 31),
        )

        increment_challenge_progress(self.player, '学習', self.today)

        study_challenge.refresh_from_db()
        self.exercise_challenge.refresh_from_db()
        self.assertEqual(study_challenge.current_count, 1)
        self.assertEqual(self.exercise_challenge.current_count, 0)
        self.assertFalse(
            ChallengeParticipation.objects.filter(
                player=self.player, challenge=self.exercise_challenge,
            ).exists()
        )

    # C3: 同日 5 回達成 → +1 のみ (1 日 1 回ガード)
    def test_C3_same_day_multiple_calls_increments_once(self):
        for _ in range(5):
            increment_challenge_progress(self.player, '運動', self.today)

        self.exercise_challenge.refresh_from_db()
        self.assertEqual(self.exercise_challenge.current_count, 1)
        participation = ChallengeParticipation.objects.get(
            player=self.player, challenge=self.exercise_challenge,
        )
        self.assertEqual(participation.contribution_count, 1)

    # C4: 翌日達成 → さらに +1 (last_contribution_date 更新確認)
    def test_C4_next_day_increments_again(self):
        increment_challenge_progress(self.player, '運動', self.today)
        tomorrow = self.today + timedelta(days=1)
        increment_challenge_progress(self.player, '運動', tomorrow)

        self.exercise_challenge.refresh_from_db()
        self.assertEqual(self.exercise_challenge.current_count, 2)
        participation = ChallengeParticipation.objects.get(
            player=self.player, challenge=self.exercise_challenge,
        )
        self.assertEqual(participation.contribution_count, 2)
        self.assertEqual(participation.last_contribution_date, tomorrow)

    # C5: 終了済チャレンジ (end_date < today) は加算対象外
    def test_C5_ended_challenge_excluded(self):
        ended = Challenge.objects.create(
            title='6 月運動チャレンジ', description='desc', category='運動',
            is_tiered=False, target_count_gold=100, reward_exp_gold=500,
            start_date=date(2026, 6, 1), end_date=date(2026, 6, 30),
        )

        increment_challenge_progress(self.player, '運動', self.today)

        ended.refresh_from_db()
        self.assertEqual(ended.current_count, 0)
        self.assertFalse(
            ChallengeParticipation.objects.filter(
                player=self.player, challenge=ended,
            ).exists()
        )

    # C6: is_active=False は加算対象外
    def test_C6_inactive_challenge_excluded(self):
        self.exercise_challenge.is_active = False
        self.exercise_challenge.save(update_fields=['is_active'])

        increment_challenge_progress(self.player, '運動', self.today)

        self.exercise_challenge.refresh_from_db()
        self.assertEqual(self.exercise_challenge.current_count, 0)

    # C7: ToDo (habit_type='todo') 達成は加算対象外
    def test_C7_todo_habit_excluded(self):
        habit = Habit.objects.create(
            player=self.player, name='ToDo 運動', category='運動',
            difficulty='normal', habit_type='todo',
            frequency='daily', reset_cycle='daily',
        )

        apply_count_change(self.player, habit, 1, is_checklist=False)

        self.exercise_challenge.refresh_from_db()
        self.assertEqual(self.exercise_challenge.current_count, 0)
        self.assertFalse(
            ChallengeParticipation.objects.filter(
                player=self.player, challenge=self.exercise_challenge,
            ).exists()
        )

    # C8: ゲストユーザー (user=null PlayerProfile) でも加算される
    def test_C8_guest_player_increments(self):
        guest_player = PlayerProfile.objects.create(user=None, name='ゲスト')

        increment_challenge_progress(guest_player, '運動', self.today)

        self.exercise_challenge.refresh_from_db()
        self.assertEqual(self.exercise_challenge.current_count, 1)
        participation = ChallengeParticipation.objects.get(
            player=guest_player, challenge=self.exercise_challenge,
        )
        self.assertEqual(participation.contribution_count, 1)


class ChallengeInfoTextLocaleTest(TestCase):
    """【2026-08-03】チャレンジ画面の説明文が locale に追従する。

    ## なぜ必要か

    `info_text` は view にハードコードされた定数だった。FEAT-489 Phase 4 は
    「`_en` field を持つ master data」を対象にしたため、**view の定数**は
    census から漏れ、英語 UI でもこの 1 行だけ日本語で出ていた
    (2026-08-03 実機 QA で検出)。

    同じ形 (Backend が返す固定文言) は他にもあるので、代表例としてここで縛る。

    ## 認証について

    `force_authenticate` は使えない。DRF の強制認証は APIView の
    initialize_request 内で効くため、その手前の `I18nMiddleware` からは
    AnonymousUser に見える。実機と同じく Token を渡す
    (test_home_bootstrap_sabi.py と同じ規律)。
    """

    def setUp(self):
        self.user = User.objects.create_user(username='chal_locale', password='pw')
        PlayerProfile.objects.get_or_create(user=self.user)
        self.client = APIClient()
        token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def test_ja_returns_japanese(self):
        res = self.client.get('/api/challenges/', HTTP_ACCEPT_LANGUAGE='ja')
        self.assertEqual(res.status_code, 200)
        self.assertIn('貢献回数', res.data['info_text'])

    def test_en_returns_english(self):
        res = self.client.get('/api/challenges/', HTTP_ACCEPT_LANGUAGE='en-US,en;q=0.9')
        self.assertEqual(res.status_code, 200)
        info = res.data['info_text']
        self.assertIn('Contributions are counted', info)
        self.assertNotRegex(
            info, r'[぀-ヿ一-鿿]',
            msg=f'英語の info_text に日本語が混ざっている: {info!r}',
        )

    def test_unknown_locale_falls_back_to_ja(self):
        res = self.client.get('/api/challenges/', HTTP_ACCEPT_LANGUAGE='fr')
        self.assertEqual(res.status_code, 200)
        self.assertIn('貢献回数', res.data['info_text'])
