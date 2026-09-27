"""【FEAT-516】**API のレスポンス本文**が英語で返ることを縛る契約テスト。

## なぜ serializer の単体テストでは足りないか

`I18nFieldMixin` は `context['request'].locale` を読む。**view が context に
`request` を渡し忘れると、常に ja が返る**。例外は出ない。`_en` を用意しても、
翻訳を投入しても、英語にならない。

2026-08-04 の実測では、i18n serializer の呼び出し **13 箇所中 12 箇所**で
`request` が渡されていなかった:

| 場所 | serializer |
|---|---|
| `gamification.py` × 4 | `CharacterSerializer` |
| `task_suggestion.py` × 1 | `TaskSuggestionSerializer` |
| `habits.py` × 4 / `home.py` × 1 / `player.py` × 2 | `PlayerProfileSerializer` (nested に Character を含む) |

つまり **FEAT-489 Phase 4 で serializer を i18n 対応にした作業が、
どの画面にも届いていなかった**。`test_i18n.py` の 22 本はすべて
serializer / middleware の単体テストで、**レスポンス本文を検査したものが
1 本も無かった**ため検出できなかった (20260802 review の指摘と同じ形)。

## だから本テストは HTTP を叩く

「英語の値が DB に入っている」ではなく「**英語でユーザーに届く**」を縛る。
"""
import datetime

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from pathlib import Path
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient, APITestCase

from api.models import (
    Achievement, Battle, BattleLog, Challenge, ChallengeParticipation, Character,
    Enemy, PlayerProfile, TaskSuggestion,
)

User = get_user_model()

_JSON = Path(__file__).resolve().parents[3] / 'doc' / 'i18n' / 'master_data_en.json'


def _has_japanese(text: str) -> bool:
    return any('぀' <= c <= 'ヿ' or '一' <= c <= '鿿' for c in text or '')


class I18nApiResponseTest(TestCase):
    """英語 locale で叩いたとき、レスポンス本文が英語になる。"""

    @classmethod
    def setUpTestData(cls):
        # 翻訳を投入した状態を作る (未投入だと ja fallback で必ず落ちてしまい、
        # 「配線されているか」ではなく「翻訳があるか」を測ることになる)。
        # `GachaReward` は migration ではなく実行時 (`_ensure_gacha_rewards`) に
        # lazy seed される。テスト DB は migration しか適用されないので、
        # **先に seed しないと翻訳ファイルの GachaReward 行が「対象なし」で弾かれる**。
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        call_command('translate_master_data', file=str(_JSON), verbosity=0)

    def setUp(self):
        self.user = User.objects.create_user(username='i18n_api', password='pw')
        PlayerProfile.objects.get_or_create(user=self.user)
        self.client = APIClient()
        token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def _get(self, url, lang):
        return self.client.get(url, HTTP_ACCEPT_LANGUAGE=lang)

    # ── 実績画面 ─────────────────────────────────────────────────────
    def test_achievements_return_english(self):
        res = self._get('/api/achievements/', 'en')
        self.assertEqual(res.status_code, 200)
        rows = res.data['achievements']
        self.assertTrue(rows, '実績が 0 件では検証にならない')

        jp = [r['name'] for r in rows if _has_japanese(r['name'])]
        self.assertEqual(jp, [], f'英語 locale なのに実績名が日本語: {jp[:5]}')

        jp_desc = [r['description'] for r in rows if _has_japanese(r['description'])]
        self.assertEqual(jp_desc, [], f'実績説明が日本語: {jp_desc[:3]}')

    def test_achievements_return_japanese_for_ja(self):
        """ja では日本語のまま (英語に倒し切っていないこと)。"""
        res = self._get('/api/achievements/', 'ja')
        names = [r['name'] for r in res.data['achievements']]
        self.assertTrue(
            any(_has_japanese(n) for n in names),
            'ja locale なのに日本語の実績名が 1 件も無い',
        )

    # ── タスク候補 ───────────────────────────────────────────────────
    def test_task_suggestions_return_english(self):
        # `type` 必須 (event / todo / habit)
        res = self._get('/api/task-suggestions/?type=habit', 'en')
        self.assertEqual(res.status_code, 200)
        rows = res.data if isinstance(res.data, list) else res.data.get('results', [])
        self.assertTrue(rows, 'タスク候補が 0 件では検証にならない')
        jp = [r['title'] for r in rows if _has_japanese(r.get('title', ''))]
        self.assertEqual(jp, [], f'タスク候補が日本語: {jp[:5]}')

    # ── キャラクター (nested 経由も含む) ─────────────────────────────
    def test_characters_return_english(self):
        res = self._get('/api/characters/', 'en')
        self.assertEqual(res.status_code, 200)
        rows = res.data if isinstance(res.data, list) else res.data.get('characters', [])
        self.assertTrue(rows, 'キャラが 0 件では検証にならない')
        jp = [r['name'] for r in rows if _has_japanese(r.get('name', ''))]
        self.assertEqual(jp, [], f'キャラ名が日本語: {jp[:5]}')

    def test_home_bootstrap_nested_character_is_english(self):
        """`PlayerProfileSerializer` の nested `active_character` も英語になる。

        DRF は nested serializer に親の context を引き継ぐので、
        **親に request を渡し忘れると nested も道連れ**で ja になる。
        """
        character = Character.objects.filter(name_en__gt='').first()
        self.assertIsNotNone(character, '英訳済キャラが無いと検証にならない')
        player = self.user.player_profile
        player.active_character = character
        player.save(update_fields=['active_character'])

        res = self._get('/api/home/', 'en')
        self.assertEqual(res.status_code, 200)
        nested = res.data['player'].get('active_character')
        self.assertIsNotNone(nested, 'active_character が返っていない')
        self.assertFalse(
            _has_japanese(nested['name']),
            f"nested キャラ名が日本語: {nested['name']!r} "
            '(親 serializer に request context を渡し忘れていないか)',
        )


class I18nSerializerContextWiringTest(TestCase):
    """`_en` は入っているのに ja が返る = context の渡し忘れ、を切り分ける。

    翻訳の有無ではなく **配線** が原因であることを、失敗時に判別できるようにする。
    """

    @classmethod
    def setUpTestData(cls):
        # `GachaReward` は migration ではなく実行時 (`_ensure_gacha_rewards`) に
        # lazy seed される。テスト DB は migration しか適用されないので、
        # **先に seed しないと翻訳ファイルの GachaReward 行が「対象なし」で弾かれる**。
        from api.views.gacha import _ensure_gacha_rewards
        _ensure_gacha_rewards()
        call_command('translate_master_data', file=str(_JSON), verbosity=0)

    def test_db_actually_holds_english(self):
        """前提確認 —— DB 側には英訳が入っている。

        これが落ちるなら原因は配線ではなく翻訳の投入漏れ。
        """
        for model, field in ((Achievement, 'name_en'),
                             (Character, 'name_en'),
                             (TaskSuggestion, 'title_en')):
            empty = model.objects.filter(**{f'{field}__exact': ''}).count()
            self.assertEqual(
                empty, 0,
                f'{model.__name__}.{field} が {empty} 件空。'
                'translate_master_data の投入漏れ (配線の問題ではない)',
            )


@override_settings(REST_FRAMEWORK={
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.TokenAuthentication',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
})
class I18nBattleEnemyNameTest(APITestCase):
    """【2026-08-09】バトル系 view の敵名が locale で切り替わる。

    ## なぜ必要か (実際に起きたこと)

    英語スクリーンショットの撮影中に、**UI は英語なのに敵名だけ「闇の騎士」**
    という状態が見つかった。原因は `BattleStartView` が生の `enemy.name` を
    返していたこと (`views/battle/start.py`)。同じレスポンス辞書のすぐ下で
    `player_job` は `request.locale` を渡せていたので、**同一関数内での
    付け忘れ**だった。`BattleLogListView` にも同じ漏れがあった。

    掲示板 (`EnemyListView`) だけは `get_i18n_field` を使えていたため、
    英語ユーザーには **「掲示板は Dark Knight → タップすると闇の騎士」**
    という断絶になっていた。

    ## なぜ既存のテストで防げなかったか

    - `check_i18n_coverage` は **DB に `name_en` が入っているか**しか見ない。
      view が使っているかは検査しないので、緑のまま通っていた
    - `test_i18n.py` の 22 本は serializer / middleware の単体テスト
    - 本ファイルの既存テストは実績 / タスク候補 / キャラのみで、**バトルは対象外**

    だから「英語の値が DB にある」ではなく「**英語でユーザーに届く**」を
    HTTP で縛る、という本ファイルの方針をバトルにも広げる。
    """

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('i18n_battle', email='ib@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='Tester')

        # 出陣可能な状態 (3 charges で 1 戦)。
        # 【FEAT-478 Phase 2b】NEW state (PlayerBattleState) 側に書く。
        battle_state = self.player.battle
        battle_state.battle_charges      = 3
        battle_state.battle_charges_date = datetime.date.today()
        battle_state.save(update_fields=['battle_charges', 'battle_charges_date'])

        # ja / en を両方持つ敵。migration seed 済の row を update_or_create で
        # 期待値に固定する (テスト独立性)。
        self.enemy, _ = Enemy.objects.update_or_create(
            key='goblin',
            defaults={
                'name':          'ゴブリン',
                'name_en':       'Goblin',
                'sprite_key':    'enemy_goblin',
                'base_hp':       60,
                'base_atk':      8,
                'base_spd':      10,
                'reward_coins':  10,
                'reward_exp':    6,
                'unlock_level':  1,
                'tier':          'zako',
            },
        )
        token, _ = Token.objects.get_or_create(user=self.user)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def _start(self, lang):
        return self.client.post(
            reverse('battle-start'), {'enemy_key': 'goblin'},
            format='json', HTTP_ACCEPT_LANGUAGE=lang,
        )

    def _make_log(self):
        battle = Battle.objects.create(
            player=self.player, enemy=self.enemy,
            enemy_hp_init=60, enemy_atk_init=8,
            started_at=timezone.now(), finished_at=timezone.now(),
            result='win', token='t' * 16,
        )
        BattleLog.objects.create(battle=battle, summary_text='', rounds=3)

    # ── 出陣 (バトル画面のネームプレート + ダメージログの供給元) ──────────
    def test_battle_start_enemy_name_is_english(self):
        res = self._start('en')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(
            res.data['enemy']['name'], 'Goblin',
            '英語 locale で敵名が英語になっていない。'
            'start.py の enemy dict が get_i18n_field を通っているか確認',
        )

    def test_battle_start_enemy_name_is_japanese_for_ja(self):
        res = self._start('ja')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['enemy']['name'], 'ゴブリン')

    def test_battle_start_enemy_key_stays_locale_independent(self):
        """`key` は Mobile 側の switch key。**絶対に locale 依存にしない**。

        `name` を i18n 化するときに隣の `key` まで巻き込むと、sprite 解決や
        分岐が英語 locale でだけ壊れる。`_serialize_job` の `job_id` と同じ規律。
        """
        for lang in ('ja', 'en'):
            self.assertEqual(self._start(lang).data['enemy']['key'], 'goblin')

    # ── バトル履歴一覧 ───────────────────────────────────────────────
    def test_battle_logs_enemy_name_is_english(self):
        self._make_log()
        res = self.client.get(reverse('battle-logs'), HTTP_ACCEPT_LANGUAGE='en')
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.data['logs'][0]['enemy_name'], 'Goblin')

    def test_battle_logs_enemy_name_is_japanese_for_ja(self):
        self._make_log()
        res = self.client.get(reverse('battle-logs'), HTTP_ACCEPT_LANGUAGE='ja')
        self.assertEqual(res.data['logs'][0]['enemy_name'], 'ゴブリン')

    # ── 掲示板と出陣が食い違わない (今回の症状そのもの) ──────────────────
    def test_board_and_start_agree_in_english(self):
        """掲示板の表示名と、そこから出陣した先の敵名が一致する。

        個別に英語化されていても **片方だけ直す** と再発するため、
        2 経路の一致そのものを縛る。
        """
        board = self.client.get(reverse('battle-enemies'), HTTP_ACCEPT_LANGUAGE='en')
        listed = next(e['name'] for e in board.data['enemies'] if e['key'] == 'goblin')
        started = self._start('en').data['enemy']['name']
        self.assertEqual(
            listed, started,
            f'掲示板 "{listed}" と出陣後 "{started}" で敵名が食い違う',
        )


@override_settings(REST_FRAMEWORK={
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.TokenAuthentication',
    ],
    'DEFAULT_THROTTLE_CLASSES': [],
    'DEFAULT_THROTTLE_RATES': {},
})
class I18nChallengeResponseTest(APITestCase):
    """【2026-08-11】チャレンジ名 / 説明文が locale で切り替わる。

    ## なぜ必要か (実際に起きたこと)

    英語スクリーンショットの撮影中に、**UI は Challenge / times / more to go と
    英語なのに、チャレンジ名と説明文だけ「健康チャレンジ」「みんなで健康習慣を
    達成しよう！」と日本語**で出ていた。

    `views/challenge.py` には次のコメントが残っていた:

        `title` / `description` は Challenge model に `_en` field が無いため
        英語 locale でも日本語のまま返る。migration を伴う横断対応として別途扱う。

    しかし **その横断対応 (FEAT-516 / migration 0200) は既に完了していた**。
    field は追加されたのに view の配線だけが取り残され、コメントも当時のまま
    だったので、読んだ人は「まだ field が無い」と誤解する状態になっていた。

    同じ漏れが `challenge_reward_service.grant_pending_rewards()` にもあり、
    報酬 SnackBar のチャレンジ名も日本語で返っていた。

    ## Challenge 特有の事情

    Challenge は **seed も management command も無く、Django admin で手動作成
    する運用**。`translate_master_data` (静的 JSON) では埋められないため、
    admin の fieldsets に `title_en` / `description_en` を出すところまでが
    セットで必要になる (`ChallengeAdmin` を同時に修正した理由)。
    """

    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user('i18n_chal', email='ic@example.com')
        self.player = PlayerProfile.objects.create(user=self.user, name='Tester')
        today = datetime.date.today()
        self.challenge = Challenge.objects.create(
            title='健康チャレンジ',
            title_en='Health Challenge',
            description='みんなで健康習慣を達成しよう！',
            description_en='Build healthy habits together!',
            category='健康',
            is_active=True,
            is_tiered=True,
            target_count_bronze=50, target_count_silver=100, target_count_gold=150,
            reward_exp_bronze=100, reward_exp_silver=200, reward_exp_gold=300,
            start_date=today - datetime.timedelta(days=1),
            end_date=today + datetime.timedelta(days=20),
        )
        token, _ = Token.objects.get_or_create(user=self.user)
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')

    def _get(self, lang):
        return self.client.get(reverse('challenge-list'), HTTP_ACCEPT_LANGUAGE=lang)

    def test_challenge_title_and_description_are_english(self):
        res = self._get('en')
        self.assertEqual(res.status_code, 200)
        row = next(c for c in res.data['active'] if c['id'] == self.challenge.id)
        self.assertEqual(row['title'], 'Health Challenge')
        self.assertEqual(row['description'], 'Build healthy habits together!')

    def test_challenge_stays_japanese_for_ja(self):
        row = next(
            c for c in self._get('ja').data['active'] if c['id'] == self.challenge.id
        )
        self.assertEqual(row['title'], '健康チャレンジ')
        self.assertEqual(row['description'], 'みんなで健康習慣を達成しよう！')

    def test_empty_english_falls_back_to_japanese(self):
        """英訳未入力なら日本語に落ちる (画面が空欄にならない)。

        admin で `title_en` を入れ忘れた月があっても、英語ユーザーに
        空文字が出るのではなく日本語が出る、という degrade を固定する。
        """
        self.challenge.title_en = ''
        self.challenge.description_en = ''
        self.challenge.save(update_fields=['title_en', 'description_en'])

        row = next(
            c for c in self._get('en').data['active'] if c['id'] == self.challenge.id
        )
        self.assertEqual(row['title'], '健康チャレンジ')
        self.assertEqual(row['description'], 'みんなで健康習慣を達成しよう！')

    # 【FEAT-536 Phase 2-1 (2026-08-29)】旧 `test_admin_exposes_english_fields` は
    # ここにあったが、**`ChallengeAdmin` 決め打ち**だったので走査に置き換えた。
    # 現在は `test_i18n_field_census.py::AdminExposesEnglishFieldsTest`。
    #
    # 🔴 **ここに個別の admin テストを書き足さないこと。** Challenge を直した
    # 2026-08-11 の時点で、隣に同じ穴が 2 つ空いたまま
    # (`GachaReward` / `WeaponMaster`) で、さらに `MaintenanceConfig` も同型
    # だった —— **決め打ちのテストは、書いた人が思い出した 1 件しか守らない**。

    def test_pending_reward_challenge_title_is_english(self):
        """報酬 SnackBar 用の `challenge_title` も英語になる。

        `grant_pending_rewards()` は service 層で、view とは別に
        `challenge.title` を組み立てていた。**view だけ直すと
        「一覧は Health Challenge / 報酬通知は 健康チャレンジ」**になる。

        `/api/home/` からも同じ service が呼ばれるので、そちらにも locale を
        渡している (渡し忘れると Home の SnackBar だけ日本語に戻る)。
        """
        today = datetime.date.today()
        ended = Challenge.objects.create(
            title='学習チャレンジ',
            title_en='Learning Challenge',
            description='みんなで学習習慣を達成しよう！',
            description_en='Build learning habits together!',
            category='学習',
            is_active=True, is_tiered=True,
            target_count_bronze=1, target_count_silver=100, target_count_gold=150,
            reward_exp_bronze=100, reward_exp_silver=200, reward_exp_gold=300,
            current_count=50,
            start_date=today - datetime.timedelta(days=40),
            end_date=today - datetime.timedelta(days=1),   # 終了済
        )
        ChallengeParticipation.objects.create(
            player=self.player, challenge=ended,
            contribution_count=5,
            last_contribution_date=today - datetime.timedelta(days=2),
        )

        res = self._get('en')
        titles = [r['challenge_title'] for r in res.data['pending_rewards']]
        self.assertIn(
            'Learning Challenge', titles,
            f'報酬の challenge_title が英語になっていない: {titles}',
        )

    def test_admin_translation_prompt_js_is_wired_and_collectable(self):
        """翻訳プロンプト JS が admin に読み込まれ、collectstatic で拾える。

        ファイルを置いただけでは admin に出ない (Media 未指定) し、Media に
        書いただけでも本番では出ない (`AppDirectoriesFinder` が拾えない場所に
        あると `collectstatic` から漏れる)。**両方**を縛る。

        本番の admin で静かに動かなくなる類の不具合なので、実機で気付くまでの
        距離が長い。
        """
        from django.contrib.staticfiles import finders

        from api.admin import ChallengeAdmin

        path = 'admin/js/i18n_translate_prompt.js'
        self.assertIn(
            path, list(ChallengeAdmin.Media.js),
            'ChallengeAdmin.Media.js に翻訳プロンプト JS が無い',
        )
        self.assertIsNotNone(
            finders.find(path),
            f'{path} を staticfiles finder が解決できない。'
            'collectstatic から漏れるので本番 admin でボタンが出ない',
        )
