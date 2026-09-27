# -*- coding: utf-8 -*-
"""【FEAT-525 (2026-08-21)】`set_checklist_items` の契約テスト。

「習慣を編集」画面のチェックリスト項目にドラッグハンドルが出ているのに
並び替えられない —— 実装が無かった —— という報告への対応。項目の
**追加・削除・並び替えを 1 往復で表現する**宣言的フィールドを PATCH に追加した。

本テストが縛る不変条件は 3 系統ある。

1. **宣言的セマンティクス** (§5 backend)
   id あり = 更新 / id なし = 作成 / 配列に無い id = 削除、order = 配列の index。

2. **🔴 `done_date` の保持** (Pre-mortem #1)
   id あり項目を `delete` + `create` にすると当日のチェックが全部外れる。
   **順序だけを見るテストでは通ってしまう**ので、ここで明示的に assert する。

3. **🔴 旧クライアントの後方互換** (Pre-mortem #2)
   v1.0.5 が公開中、`1.1.0+6` が審査中で、どちらも `add_checklist_items` /
   `delete_checklist_items` を送る。この 2 フィールドを消す / 挙動を変えると
   既存ユーザーの項目追加・削除が壊れる。

Pre-mortem #3 (他 habit の id を混ぜて操作できる) は 400 で縛る。
Pre-mortem #5 (2 端末同時保存) はロック順序の構造縛りで代替する
(実際の並行実行は SQLite では再現できないため)。
"""
import inspect

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from api.models import ChecklistItem, Habit, PlayerProfile
from api.views import habits as habits_view

User = get_user_model()

_TEST_OVERRIDE = {
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


@override_settings(REST_FRAMEWORK=_TEST_OVERRIDE)
class ChecklistSetItemsTestCase(APITestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username='tester', password='password')
        self.player = PlayerProfile.objects.create(
            user=self.user, level=1, max_exp=10000, mode='training',
        )
        self.token = Token.objects.create(user=self.user)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {self.token.key}')

        self.habit = Habit.objects.create(
            player=self.player, name='朝の支度', category='健康',
            frequency='daily', reset_cycle='daily', habit_type='checklist',
            difficulty='normal',
        )
        self.a = ChecklistItem.objects.create(habit=self.habit, text='A', order=0)
        self.b = ChecklistItem.objects.create(habit=self.habit, text='B', order=1)
        self.c = ChecklistItem.objects.create(habit=self.habit, text='C', order=2)

    # ── helpers ──────────────────────────────────────────────────────────
    def _patch(self, body):
        return self.client.patch(f'/api/habits/{self.habit.id}/', body, format='json')

    def _texts_in_order(self):
        """`Meta.ordering = ['order', 'id']` 準拠の表示順で text を並べて返す。"""
        return list(
            ChecklistItem.objects.filter(habit=self.habit).values_list('text', flat=True)
        )

    # ── 1. 宣言的セマンティクス ──────────────────────────────────────────
    def test_1_reorder_updates_order_to_array_index(self):
        """並び替え → order が配列の index どおりに更新される。"""
        res = self._patch({'set_checklist_items': [
            {'id': self.c.id, 'text': 'C'},
            {'id': self.a.id, 'text': 'A'},
            {'id': self.b.id, 'text': 'B'},
        ]})
        self.assertEqual(res.status_code, 200, res.data)

        self.assertEqual(self._texts_in_order(), ['C', 'A', 'B'])
        self.c.refresh_from_db(); self.a.refresh_from_db(); self.b.refresh_from_db()
        self.assertEqual((self.c.order, self.a.order, self.b.order), (0, 1, 2))

        # レスポンス body も並び替え後の順序で返る (Flutter が再取得せず反映できる)
        self.assertEqual(
            [i['text'] for i in res.data['checklist_items']], ['C', 'A', 'B'],
        )

    def test_2_missing_ids_are_deleted_and_idless_entries_are_created(self):
        """配列に無い既存 id は削除、id 無し要素は新規作成される。"""
        res = self._patch({'set_checklist_items': [
            {'id': self.a.id, 'text': 'A'},
            {'text': '新しい項目'},          # 新規 (間に差し込む)
            {'id': self.c.id, 'text': 'C'},
            # B は配列に無い → 削除
        ]})
        self.assertEqual(res.status_code, 200, res.data)

        self.assertEqual(self._texts_in_order(), ['A', '新しい項目', 'C'])
        self.assertFalse(ChecklistItem.objects.filter(pk=self.b.pk).exists())
        created = ChecklistItem.objects.get(habit=self.habit, text='新しい項目')
        self.assertEqual(created.order, 1)

    def test_3_text_of_existing_item_is_updated(self):
        """id あり項目の text は更新される (同じ行を使い回す)。"""
        res = self._patch({'set_checklist_items': [
            {'id': self.a.id, 'text': 'A を書き換えた'},
            {'id': self.b.id, 'text': 'B'},
            {'id': self.c.id, 'text': 'C'},
        ]})
        self.assertEqual(res.status_code, 200, res.data)
        self.a.refresh_from_db()
        self.assertEqual(self.a.text, 'A を書き換えた')
        self.assertEqual(self.a.pk, ChecklistItem.objects.get(text='A を書き換えた').pk)

    def test_4_empty_list_removes_all_items(self):
        """空配列 = 全削除 (宣言的な意味どおり)。"""
        res = self._patch({'set_checklist_items': []})
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(ChecklistItem.objects.filter(habit=self.habit).count(), 0)

    def test_5_is_idempotent(self):
        """同じ body を 2 回送っても結果が変わらない (冪等)。"""
        body = {'set_checklist_items': [
            {'id': self.b.id, 'text': 'B'},
            {'text': '新規'},
            {'id': self.a.id, 'text': 'A'},
        ]}
        self.assertEqual(self._patch(body).status_code, 200)
        first = self._texts_in_order()

        # 2 回目は「新規」がすでに存在するが、id 無しなので**もう 1 件作られる**。
        # これは仕様どおり (id が無い = 新規作成の宣言)。Flutter は保存後に
        # 再取得した id 付きリストを送るので実運用では起きない。
        # ここで縛るのは「id 付きの部分は 2 回目でも同じ結果になる」こと。
        self.assertEqual(first[0], 'B')
        self.assertEqual(first[-1], 'A')

        body2 = {'set_checklist_items': [
            {'id': i.id, 'text': i.text}
            for i in ChecklistItem.objects.filter(habit=self.habit)
        ]}
        self.assertEqual(self._patch(body2).status_code, 200)
        self.assertEqual(self._texts_in_order(), first)
        self.assertEqual(self._patch(body2).status_code, 200)
        self.assertEqual(self._texts_in_order(), first)

    # ── 2. 🔴 done_date の保持 (Pre-mortem #1) ───────────────────────────
    def test_6_done_date_survives_reorder(self):
        """🔴 並び替えても当日のチェック状態が消えない。

        **本テストが FEAT-525 の最重要契約。** 実装が id あり項目を
        `delete` + `create` にしていると `done_date` が失われ、ユーザーから見ると
        「並べ替えたらチェックが全部外れた」という退行になる。
        `test_1` (順序) だけでは検出できない。
        """
        today = timezone.localdate()
        ChecklistItem.objects.filter(pk__in=[self.a.pk, self.b.pk]).update(done_date=today)

        res = self._patch({'set_checklist_items': [
            {'id': self.c.id, 'text': 'C'},
            {'id': self.b.id, 'text': 'B'},
            {'id': self.a.id, 'text': 'A'},
        ]})
        self.assertEqual(res.status_code, 200, res.data)

        self.a.refresh_from_db(); self.b.refresh_from_db()
        self.assertEqual(self.a.done_date, today, 'A の done_date が消えている')
        self.assertEqual(self.b.done_date, today, 'B の done_date が消えている')

        # 「同じ行を使い回している」ことを pk で直接縛る
        # (delete + create だと pk が変わるため、ここで落ちる)
        self.assertEqual(
            set(ChecklistItem.objects.filter(habit=self.habit).values_list('pk', flat=True)),
            {self.a.pk, self.b.pk, self.c.pk},
        )

        # レスポンスの is_done も True のまま (Flutter がそのまま描画する値)
        by_id = {i['id']: i for i in res.data['checklist_items']}
        self.assertTrue(by_id[self.a.id]['is_done'])
        self.assertTrue(by_id[self.b.id]['is_done'])
        self.assertFalse(by_id[self.c.id]['is_done'])

    def test_7_done_date_survives_text_edit_and_insertion(self):
        """text 更新 + 新規項目の差し込みが混ざっても done_date は保持される。"""
        today = timezone.localdate()
        ChecklistItem.objects.filter(pk=self.b.pk).update(done_date=today)

        res = self._patch({'set_checklist_items': [
            {'text': '先頭に差し込む'},
            {'id': self.b.id, 'text': 'B を書き換えた'},
            {'id': self.a.id, 'text': 'A'},
        ]})
        self.assertEqual(res.status_code, 200, res.data)

        self.b.refresh_from_db()
        self.assertEqual(self.b.text, 'B を書き換えた')
        self.assertEqual(self.b.done_date, today)
        self.assertEqual(self.b.order, 1)

    # ── 3. 権限 (Pre-mortem #3) ──────────────────────────────────────────
    def test_8_foreign_habit_item_id_returns_400(self):
        """🔴 他 habit の項目 id を混ぜると 400 (黙って無視しない)。"""
        other_habit = Habit.objects.create(
            player=self.player, name='別の習慣', category='学習',
            frequency='daily', reset_cycle='daily', habit_type='checklist',
        )
        foreign = ChecklistItem.objects.create(habit=other_habit, text='他所の項目', order=0)

        res = self._patch({'set_checklist_items': [
            {'id': self.a.id, 'text': 'A'},
            {'id': foreign.id, 'text': '他所の項目'},
        ]})
        self.assertEqual(res.status_code, 400, res.data)
        self.assertEqual(res.data['error']['code'], 'habit_update_checklist_item_not_found')

        # 何も適用されていないこと (400 なのに B / C だけ消えている等が起きない)
        self.assertEqual(self._texts_in_order(), ['A', 'B', 'C'])
        self.assertTrue(ChecklistItem.objects.filter(pk=foreign.pk).exists())

    def test_9_other_player_item_id_returns_400(self):
        """他プレイヤーの項目 id も同様に 400。"""
        other_user = User.objects.create_user(username='other', password='password')
        other_player = PlayerProfile.objects.create(
            user=other_user, level=1, max_exp=10000, mode='training',
        )
        other_habit = Habit.objects.create(
            player=other_player, name='他人の習慣', category='学習',
            frequency='daily', reset_cycle='daily', habit_type='checklist',
        )
        foreign = ChecklistItem.objects.create(habit=other_habit, text='他人の項目', order=0)

        res = self._patch({'set_checklist_items': [{'id': foreign.id, 'text': 'x'}]})
        self.assertEqual(res.status_code, 400, res.data)
        self.assertEqual(res.data['error']['code'], 'habit_update_checklist_item_not_found')
        foreign.refresh_from_db()
        self.assertEqual(foreign.text, '他人の項目')

    def test_10_habit_body_is_rolled_back_when_items_are_rejected(self):
        """項目側が 400 なら習慣本体の更新もロールバックされる。

        「名前だけ変わってリストは元のまま」という中途半端な状態を残さない。
        """
        res = self._patch({
            'name': '書き換わってはいけない名前',
            'set_checklist_items': [{'id': 999999, 'text': 'x'}],
        })
        self.assertEqual(res.status_code, 400, res.data)
        self.habit.refresh_from_db()
        self.assertEqual(self.habit.name, '朝の支度')

    # ── 4. payload 競合 / 正規化 ─────────────────────────────────────────
    def test_11_set_and_add_together_returns_400(self):
        """`set_` と `add_` を同時に送ると 400 (どちらかを黙って優先しない)。"""
        res = self._patch({
            'set_checklist_items': [{'id': self.a.id, 'text': 'A'}],
            'add_checklist_items': [{'text': '追加'}],
        })
        self.assertEqual(res.status_code, 400, res.data)
        self.assertEqual(
            res.data['error']['code'], 'habit_update_checklist_payload_conflict',
        )
        self.assertEqual(self._texts_in_order(), ['A', 'B', 'C'])

    def test_12_set_and_delete_together_returns_400(self):
        res = self._patch({
            'set_checklist_items': [{'id': self.a.id, 'text': 'A'}],
            'delete_checklist_items': [self.b.id],
        })
        self.assertEqual(res.status_code, 400, res.data)
        self.assertEqual(
            res.data['error']['code'], 'habit_update_checklist_payload_conflict',
        )
        self.assertEqual(self._texts_in_order(), ['A', 'B', 'C'])

    def test_13_duplicate_ids_are_first_wins(self):
        """重複 id は先勝ち (`HabitOrderView` の `dict.fromkeys` と同じ扱い)。"""
        res = self._patch({'set_checklist_items': [
            {'id': self.b.id, 'text': '先勝ちの text'},
            {'id': self.a.id, 'text': 'A'},
            {'id': self.b.id, 'text': '後から来た text'},
        ]})
        self.assertEqual(res.status_code, 200, res.data)
        self.b.refresh_from_db()
        self.assertEqual(self.b.text, '先勝ちの text')
        self.assertEqual(self.b.order, 0)
        self.assertEqual(self._texts_in_order(), ['先勝ちの text', 'A'])

    def test_14_blank_text_entries_are_ignored(self):
        """空文字 / 空白のみの text は無視される (作成しない)。

        `ChecklistItem.text` は必須なので「空の項目」は表現できない。
        id 付きで空文字が来た場合も同じくリストから落ちるため、
        宣言的な意味 (送ったリストに存在しない) のとおり削除される。
        """
        res = self._patch({'set_checklist_items': [
            {'id': self.a.id, 'text': 'A'},
            {'text': ''},
            {'text': '   '},
            {'id': self.b.id, 'text': '  '},   # 空白のみ → 落ちる = 削除
            {'id': self.c.id, 'text': 'C'},
        ]})
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(self._texts_in_order(), ['A', 'C'])
        self.assertFalse(ChecklistItem.objects.filter(pk=self.b.pk).exists())
        self.a.refresh_from_db(); self.c.refresh_from_db()
        self.assertEqual((self.a.order, self.c.order), (0, 1),
                         'order に穴が空いてはいけない')

    def test_15_text_is_stripped(self):
        res = self._patch({'set_checklist_items': [{'id': self.a.id, 'text': '  A  '}]})
        self.assertEqual(res.status_code, 200, res.data)
        self.a.refresh_from_db()
        self.assertEqual(self.a.text, 'A')

    def test_16_plain_strings_are_accepted_as_new_items(self):
        """文字列要素は text のみの新規項目として受ける (`POST /habits/` と同じ受け口)。"""
        res = self._patch({'set_checklist_items': ['文字列で追加', {'id': self.a.id, 'text': 'A'}]})
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(self._texts_in_order(), ['文字列で追加', 'A'])

    def test_17_non_list_payload_returns_400(self):
        for bad in ('あいうえお', 42, {'id': 1}):
            with self.subTest(bad=bad):
                res = self._patch({'set_checklist_items': bad})
                self.assertEqual(res.status_code, 400, res.data)
                self.assertEqual(
                    res.data['error']['code'], 'habit_update_checklist_items_invalid',
                )
        self.assertEqual(self._texts_in_order(), ['A', 'B', 'C'])

    def test_18_non_int_id_returns_400(self):
        res = self._patch({'set_checklist_items': [{'id': 'abc', 'text': 'A'}]})
        self.assertEqual(res.status_code, 400, res.data)
        self.assertEqual(
            res.data['error']['code'], 'habit_update_checklist_items_invalid',
        )

    def test_19_too_long_text_returns_400(self):
        """max_length 超過は 400。Postgres だと DataError = 500 になる経路。"""
        res = self._patch({'set_checklist_items': [{'text': 'あ' * 201}]})
        self.assertEqual(res.status_code, 400, res.data)
        self.assertEqual(
            res.data['error']['code'], 'habit_update_checklist_items_invalid',
        )

    def test_20_set_items_on_count_habit_is_ignored(self):
        """count タイプの習慣に送っても項目は作られない (既存 add_/delete_ と同じ)。"""
        count_habit = Habit.objects.create(
            player=self.player, name='腕立て', category='運動',
            frequency='daily', reset_cycle='daily', habit_type='count',
        )
        res = self.client.patch(
            f'/api/habits/{count_habit.id}/',
            {'set_checklist_items': [{'text': 'x'}]}, format='json',
        )
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(count_habit.checklist_items.count(), 0)

    # ── 5. 🔴 後方互換 (Pre-mortem #2) ───────────────────────────────────
    #
    # v1.0.5 が公開中、`1.1.0+6` が審査中。どちらも `add_checklist_items` /
    # `delete_checklist_items` を送る。**この 4 テストが落ちたら、
    # ストアに出ている版のチェックリスト編集が壊れている。**

    def test_21_legacy_add_still_appends_to_the_end(self):
        res = self._patch({'add_checklist_items': [{'text': 'D'}, {'text': 'E'}]})
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(self._texts_in_order(), ['A', 'B', 'C', 'D', 'E'])

    def test_22_legacy_delete_still_removes_items(self):
        res = self._patch({'delete_checklist_items': [self.b.id]})
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(self._texts_in_order(), ['A', 'C'])

    def test_23_legacy_add_and_delete_together_still_work(self):
        """旧クライアントは 1 回の保存で add と delete を同時に送る。"""
        res = self._patch({
            'delete_checklist_items': [self.a.id],
            'add_checklist_items': [{'text': 'D'}],
        })
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(self._texts_in_order(), ['B', 'C', 'D'])

    def test_24_legacy_add_ignores_blank_text(self):
        res = self._patch({'add_checklist_items': [{'text': '  '}, {'text': 'D'}]})
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(self._texts_in_order(), ['A', 'B', 'C', 'D'])

    def test_25_legacy_only_payload_is_not_a_conflict(self):
        """旧クライアントの body 単体では競合 400 にしない (これが壊れると全滅する)。"""
        res = self._patch({
            'name': '朝の支度 2',
            'add_checklist_items': [{'text': 'D'}],
            'delete_checklist_items': [self.c.id],
        })
        self.assertEqual(res.status_code, 200, res.data)
        self.habit.refresh_from_db()
        self.assertEqual(self.habit.name, '朝の支度 2')
        self.assertEqual(self._texts_in_order(), ['A', 'B', 'D'])

    # ── 6. 構造縛り (Pre-mortem #5 / #1 の再発防止) ──────────────────────
    def test_26_lock_order_is_pk_ascending(self):
        """2 端末同時保存の直列化: pk 昇順 `select_for_update` を構造で縛る。

        SQLite では実際の行ロックが効かず並行実行を再現できないので、
        `HabitOrderView` と同じレンデブー順序になっていることをソースで確認する
        (CLAUDE.md「select_for_update のレンデブー順序統一」)。
        """
        source = inspect.getsource(
            habits_view.HabitDetailView._apply_set_checklist_items,
        )
        self.assertIn('select_for_update()', source)
        self.assertIn("order_by('pk')", source)
        self.assertLess(
            source.index('select_for_update()'),
            source.index('.delete()'),
            'ロックを取る前に削除してはいけない',
        )

    def test_27_existing_items_are_not_recreated(self):
        """🔴 id あり項目に `delete` + `create` を使っていないことを構造で縛る。

        `test_6` が挙動で縛っているが、「entries に id があるのに create している」
        実装は将来のリファクタで再び混入しうる。`bulk_update` の存在を明示的に縛り、
        `done_date` を落とす実装への逆戻りを検出する。
        """
        source = inspect.getsource(
            habits_view.HabitDetailView._apply_set_checklist_items,
        )
        self.assertIn("bulk_update(to_update, ['text', 'order'])", source)

    def test_28_legacy_fields_are_still_handled(self):
        """旧 2 フィールドの受け口が view に残っていることを構造で縛る。

        「`set_` に一本化したので旧経路を消す」変更を CI で止める。
        撤去は旧バージョンが十分に入れ替わってから別 FEAT で行う。
        """
        source = inspect.getsource(habits_view.HabitDetailView)
        self.assertIn("data.get('delete_checklist_items'", source)
        self.assertIn("data.get('add_checklist_items'", source)
