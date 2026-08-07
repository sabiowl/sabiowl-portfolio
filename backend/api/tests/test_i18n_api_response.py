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
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from pathlib import Path
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from api.models import Achievement, Character, PlayerProfile, TaskSuggestion

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
