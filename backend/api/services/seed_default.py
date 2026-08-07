"""新規ユーザー作成時に付与するデフォルトデータ（FEAT-179）

新規 PlayerProfile が作られた直後に呼び出される。
Google / Apple サインインの新規登録時に同一セットを付与する。

既存ユーザーへの遡及適用はしない（PlayerProfile 作成時のみ、かつ
Habit が空のときのみ実行する冪等チェック付き）。

実モデルに合わせた仕様:
- ToDo は `Habit(habit_type='todo')` として保存する（`is_todo` フィールドは存在しない）
- `Habit` モデルに `target_count` フィールドは存在しない
- `ChecklistItem` のテキスト列名は `text`、完了状態は `done_date` で表現する

【FEAT-196】タイムラインのデフォルト 4 件は本サービスでは作成しない。
Flutter 側の `kDefaultTemplates` + `timelineAutoCreateProvider` がアプリ起動時に
初日分も含めて自動展開する設計に一本化したため。旧 `_DEFAULT_TIMELINE_EVENTS`
ロジックは「サーバー seed 4 件 + Flutter テンプレート展開 2 件 = 同日 6 件重複」の
温床になっていた。`TimelineEvent` の import も不要になったので削除。
"""

from datetime import date, timedelta

# SEC-09 / M-03-new: 旧実装は `@transaction.atomic` デコレータで本サービス全体を
# ラップしていたが、呼出側（SocialAuthView.post, GuestInitView.post）が既に
# `@transaction.atomic` 配下で本関数を呼ぶため savepoint がネストしていた。
# 本関数の atomic を撤廃し、呼出側 atomic に統合する方針へ変更したため、
# `from django.db import transaction` の import も不要になり削除。
# 新規呼出元を追加する場合は呼出側で必ず `@transaction.atomic` を付ける運用。

from ..models import ChecklistItem, Habit, PlayerGachaStatus


# ── デフォルト習慣定義（3 件） ────────────────────────────────
_DEFAULT_HABITS = [
    {
        'name':       '新しい習慣を登録',
        'habit_type': 'count',
        'category':   '学習',
        'frequency':  'daily',
        'difficulty': 'easy',
        'memo': (
            'あなたの「続けたいこと」を、一つ書いてみましょう。'
            '形にすることで、それは始まります。'
        ),
        'order': 0,
    },
    {
        'name':       'Sabiowl の各画面を表示',
        'habit_type': 'checklist',
        'category':   '学習',
        'frequency':  'daily',
        'difficulty': 'easy',
        'memo':       'まずは私の住まいを、ゆっくり巡ってみてください。',
        'order':      1,
        # チェックリスト項目は habit 作成後に別途生成する
        '_checklist_items': [
            'ホーム画面を見る',
            'カレンダー画面を見る',
            'ガチャ画面を見る',
            'フレンド画面を見る',
            '設定画面を見る',
        ],
    },
    {
        'name':       'キャラクターと出会う',
        'habit_type': 'count',
        'category':   '創造',
        'frequency':  'daily',
        'difficulty': 'easy',
        'memo': (
            '新しい出会いは、いつも小さなときめきから。'
            'ガチャを一度、引いてみましょう。'
        ),
        'order': 2,
    },
]

# ── デフォルト ToDo 定義（2 件） ───────────────────────────────
# ToDo は Habit(habit_type='todo') として保存する。
_DEFAULT_TODOS = [
    {
        'name':       'アカウント連携',
        'habit_type': 'todo',
        'category':   '学習',
        'frequency':  'daily',
        'difficulty': 'easy',
        'memo': (
            'あなたの積み上げを守るために、'
            'Google または Apple との連携をお願いします。'
        ),
        'order': 3,
    },
    {
        'name':       'プロフィールを編集する',
        'habit_type': 'todo',
        'category':   '学習',
        'frequency':  'daily',
        'difficulty': 'easy',
        'memo': (
            'あなたのお名前を教えてください。'
            'サビは、あなたの隣でずっと見守ります。'
        ),
        'order': 4,
    },
]


def seed_new_user_defaults(player):
    """新規 PlayerProfile に対しデフォルトデータを付与する。

    **重要（SEC-09 / M-03-new）**: 本関数は **呼出側で `@transaction.atomic` ブロック内
    で呼ばれる前提** で設計されている。旧実装は本関数自体に `@transaction.atomic` を
    付けていたが、呼出側（SocialAuthView.post / GuestInitView.post）も atomic ブロックで
    囲んでいるため savepoint がネストし、内側 savepoint だけがロールバックされると
    User + PlayerProfile が残り Habit が消える整合性破壊の理論的経路が残っていた
    （現状は次回ログイン時の冪等チェックで復旧可能なため実害は低かったが、整合性を
    厳格にするため atomic を呼出側に統合した）。

    現在の呼出元（2 箇所）はいずれも `@transaction.atomic` 配下:
      - backend/api/views/auth/social.py (`SocialAuthView.post` 内)
      - backend/api/views/auth/guest.py  (`GuestInitView.post` 内)

    新規呼出元を追加する場合は、必ず呼出側で `@transaction.atomic` を付けること。
    管理コマンドや単発スクリプトから呼ぶ場合も同様。

    冪等性: 既に Habit が存在する場合は何もしない（既存ユーザーへの遡及適用や
    ゲスト移行で既にデータが入っているケースを守る）。

    【FEAT-196】TimelineEvent の seed は廃止。
    Flutter の kDefaultTemplates + timelineAutoCreateProvider がタイムライン画面
    起動時に自動展開するため、本関数では作成しない。旧 TimelineEvent ベースの
    冪等チェックも不要になったため削除。
    """
    if Habit.objects.filter(player=player).exists():
        return

    today    = date.today()
    due_date = today + timedelta(days=7)

    # ── 習慣 3 件を作成 ────────────────────────────────────────
    for habit_def in _DEFAULT_HABITS:
        # checklist の項目だけ別バッグに退避して Habit 作成に渡さない
        spec = dict(habit_def)
        checklist_items = spec.pop('_checklist_items', None)
        habit = Habit.objects.create(player=player, **spec)
        if checklist_items:
            for idx, item_text in enumerate(checklist_items):
                ChecklistItem.objects.create(
                    habit=habit,
                    text=item_text,
                    order=idx,
                )

    # ── ToDo 2 件を作成（habit_type='todo' + due_date=今日+7日） ─
    for todo_def in _DEFAULT_TODOS:
        Habit.objects.create(player=player, due_date=due_date, **todo_def)

    # ── 【FEAT-196】タイムライン作成は Flutter テンプレートに委譲 ──
    # 旧コード:
    #   for event_def in _DEFAULT_TIMELINE_EVENTS:
    #       TimelineEvent.objects.create(player=player, date=today, **event_def)
    # → 削除（kDefaultTemplates が初日も含めて自動展開する）

    # ── 【BUG-122 (2026-06-14)】新規ユーザー初日 seed は全 0 に。──
    # 旧 BUG-120: 登録時に diamonds=500 + weekly_tickets=3 を seed
    # 新 BUG-122: 初日のタスク達成時 (diamond_service.award_daily_first_task_bonus)
    #   に 500 ダイヤ + 3 デイリー + 3 ウィークリーを付与する設計に変更。
    #   登録時は PlayerGachaStatus 行のみ作成 (チケット枚数は全 0)。
    # 「タスク達成で報酬」のコアループを最初のセッションから体験させる狙い。
    PlayerGachaStatus.objects.get_or_create(
        player=player,
        defaults={
            'daily_tickets':   0,
            'weekly_tickets':  0,
            'monthly_tickets': 0,
        },
    )
