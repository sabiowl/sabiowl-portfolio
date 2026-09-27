from django.db import models

from .player import PlayerProfile


class Habit(models.Model):
    """習慣"""

    # 【FEAT-213】11 値表示に戻す（内部は 6 ステータスへ分散マッピング、CATEGORY_STAT_MAP 参照）。
    # 全 11 カテゴリが必ず 1 つ以上のステータスに紐づくため、FEAT-201 が解消した
    # 「努力 → 成長のコアプロミスをサイレントに半分破る」バグは再発しない。
    # FEAT-171 で予約された創造力・貢献力もカテゴリ経由で増分するようになる。
    # 既存データのバックフィルはマイグレーション 0066 で `'メンタル' → '精神'` のみ実施。
    CATEGORY_CHOICES = [
        ('運動',   '運動'),
        ('学習',   '学習'),
        ('仕事',   '仕事'),
        ('体力',   '体力'),
        ('美容',   '美容'),
        ('健康',   '健康'),
        ('精神',   '精神'),
        ('創造',   '創造'),
        ('社交',   '社交'),
        ('休息',   '休息'),
        ('その他', 'その他'),
    ]

    FREQUENCY_CHOICES = [
        ('daily',   '毎日'),
        ('weekly',  '毎週'),
        ('monthly', '毎月'),
    ]

    RESET_CYCLE_CHOICES = [
        ('daily',   '毎日'),
        ('weekly',  '毎週'),
        ('monthly', '毎月'),
        ('yearly',  '毎年'),
    ]

    HABIT_TYPE_CHOICES = [
        ('count',     'カウント'),
        ('checklist', 'チェックリスト'),
        ('todo',      'ToDo'),
    ]

    DIFFICULTY_CHOICES = [
        ('easy',      'Easy'),
        ('normal',    'Normal'),
        ('hard',      'Hard'),
        ('legendary', 'Legendary'),
    ]

    PRIORITY_CHOICES = [
        ('high',   '高'),
        ('medium', '中'),
        ('low',    '低'),
    ]

    # 難易度ごとの報酬倍率（gold / exp 共通）— constants.GameBalance とも同期
    # 【FEAT-334 (2026-05-27)】legendary 3.0 → 5.0 (constants.GameBalance と同期、二重定義)
    DIFFICULTY_MULTIPLIER = {
        'easy':      1.0,
        'normal':    1.5,
        'hard':      2.0,
        'legendary': 5.0,
    }

    # 【FEAT-334 (2026-05-27)】LEGENDARY_UNLOCK_LEVEL = 20 撤廃。詳細は constants.py 参照。
    # スロット制 (case_legendary_slots() in services/habit_slot_service.py) が新ゲート。

    # frequency に対して許可される reset_cycle の組合せ
    # CLAUDE.md 仕様: frequency 以上のサイクルのみ選択可能
    #   daily   → daily / weekly / monthly / yearly
    #   weekly  → weekly / monthly / yearly
    #   monthly → monthly / yearly
    ALLOWED_RESET_CYCLES = {
        'daily':   {'daily', 'weekly', 'monthly', 'yearly'},
        'weekly':  {'weekly', 'monthly', 'yearly'},
        'monthly': {'monthly', 'yearly'},
    }

    player = models.ForeignKey(
        PlayerProfile,
        on_delete=models.CASCADE,
        related_name='habits',
        verbose_name='プレイヤー',
    )
    name        = models.CharField(max_length=100, verbose_name='習慣名')
    # 【FEAT-213】choices を明示し、11 値以外を保存できないようバリデーションを効かせる。
    category    = models.CharField(
        max_length=20, choices=CATEGORY_CHOICES, default='運動', verbose_name='カテゴリ',
    )
    frequency   = models.CharField(max_length=10, choices=FREQUENCY_CHOICES, default='daily', verbose_name='頻度')
    reset_cycle = models.CharField(max_length=10, choices=RESET_CYCLE_CHOICES, default='daily', verbose_name='リセットサイクル')
    habit_type  = models.CharField(max_length=20, choices=HABIT_TYPE_CHOICES, default='count', verbose_name='タイプ')
    difficulty  = models.CharField(max_length=10, choices=DIFFICULTY_CHOICES, default='normal', verbose_name='難易度')
    order       = models.IntegerField(default=0, verbose_name='表示順')
    memo        = models.TextField(blank=True, default='', verbose_name='メモ')
    is_public   = models.BooleanField(default=True, verbose_name='フレンドに公開')
    shield_date = models.DateField(null=True, blank=True, verbose_name='ストリーク保護日')
    streak      = models.IntegerField(default=0, verbose_name='現在の連続日数')
    best_streak = models.IntegerField(default=0, verbose_name='最長連続日数')
    total_count = models.IntegerField(default=0, verbose_name='累計カウント')
    total_exp   = models.IntegerField(default=0, verbose_name='累計EXP')
    created_at  = models.DateField(auto_now_add=True, verbose_name='作成日')
    is_active   = models.BooleanField(default=True, verbose_name='有効')
    deleted_at  = models.DateTimeField(null=True, blank=True, verbose_name='削除日時')
    priority    = models.CharField(max_length=10, choices=PRIORITY_CHOICES, default='medium', verbose_name='優先度')
    due_date    = models.DateField(null=True, blank=True, verbose_name='期限日')
    # 【FEAT-205】`Habit.due_time` は UI に time picker が存在せず、通知発火経路でも未参照の
    # 死パイプラインだったため削除（Backend データ層のみ整備されていた未完成機能の遺物）。
    # 将来「タスク通知時刻」機能を本実装する場合は TimelineEvent の通知時刻拡張として
    # 設計する（Habit と Timeline の責務分離）。

    class Meta:
        app_label        = 'api'
        verbose_name     = '習慣'
        verbose_name_plural = '習慣'
        ordering         = ['order', 'id']
        # P1-06: 同名のアクティブな習慣を同一プレイヤーが複数持てないようにする。
        # アーカイブ済み（is_active=False）は除外（trash 復元時の名前衝突を許容）。
        #
        # 【ユーザー要望 2026-06-22】ToDo (`habit_type='todo'`) は ID で個別管理される
        # 1 回限りタスクであり、同じ名前を複数登録できるべき (例: 「買い物」を
        # 複数日に登録するケース)。本制約からは ToDo を除外し、習慣 (count /
        # checklist) のみ同名禁止のままとする。
        # migration: 0155_habit_unique_constraint_exclude_todo
        constraints = [
            models.UniqueConstraint(
                fields=['player', 'name'],
                condition=models.Q(is_active=True) & ~models.Q(habit_type='todo'),
                name='unique_active_habit_name_per_player',
            ),
        ]

    def __str__(self):
        return f'{self.name} ({self.player.name})'


class HabitLog(models.Model):
    """習慣の日別記録"""

    habit      = models.ForeignKey(Habit, on_delete=models.CASCADE, related_name='logs', verbose_name='習慣')
    date       = models.DateField(verbose_name='日付')
    count      = models.IntegerField(default=0, verbose_name='カウント数')
    exp_gained = models.IntegerField(default=0, verbose_name='獲得EXP')
    # 【FEAT-398 (2026-05-31)】取り消し対称化 (案 B フラグ管理) のための加算記録フラグ。
    # - True:  この HabitLog で battle_charges +1 が実際に加算された (charges < 9 だった)
    # - False: 加算されなかった (charges == 9 で上限 or 取り消し済み)
    # 取り消し時: フラグ True なら charges -1 + フラグ False へ変更 (対称デクリメント保証)
    # 既存 HabitLog (migration apply 前) は全て False (default) → 取り消し時は無処理 (清浄スタート)
    battle_charges_awarded = models.BooleanField(
        default=False,
        help_text='FEAT-398: 該当 HabitLog で battle_charges +1 が実加算されたか (取り消し時 -1 判定用)',
    )

    class Meta:
        app_label        = 'api'
        verbose_name     = '習慣ログ'
        verbose_name_plural = '習慣ログ'
        unique_together  = ('habit', 'date')
        ordering         = ['-date']

    def __str__(self):
        return f'{self.habit.name} - {self.date} ({self.count}回)'


class HabitRewardLog(models.Model):
    """
    習慣の報酬変動履歴ログ。

    - 不正な繰り返し操作の検知に使用する
    - 「いつ・どの習慣で・いくら変動したか」を記録する
    - HabitLog は日次集計値のため、こちらは個別トランザクション単位
    """
    ACTION_PLUS  = 'plus'
    ACTION_MINUS = 'minus'
    ACTION_CHOICES = [
        (ACTION_PLUS,  '達成'),
        (ACTION_MINUS, '取り消し'),
    ]

    player = models.ForeignKey(
        'PlayerProfile', on_delete=models.CASCADE,
        related_name='reward_logs',
        verbose_name='プレイヤー',
    )
    habit = models.ForeignKey(
        'Habit', on_delete=models.CASCADE,
        related_name='reward_logs',
        verbose_name='習慣',
    )
    action = models.CharField(
        max_length=8,
        choices=ACTION_CHOICES,
        verbose_name='操作種別',
    )
    exp_delta = models.IntegerField(
        verbose_name='EXP 変動量',
        help_text='plus 時は正値、minus 時は負値',
    )
    diamond_delta = models.IntegerField(
        default=0,
        verbose_name='ダイヤ変動量',
    )
    created_at = models.DateTimeField(
        auto_now_add=True,
        verbose_name='記録日時',
    )

    class Meta:
        app_label           = 'api'
        ordering            = ['-created_at']
        indexes             = [
            models.Index(fields=['player', 'created_at']),
            models.Index(fields=['habit',  'created_at']),
        ]
        verbose_name        = '報酬変動ログ'
        verbose_name_plural = '報酬変動ログ'

    def __str__(self) -> str:
        return (
            f'{self.player} | {self.habit.name} | '
            f'{self.action} | EXP:{self.exp_delta:+d} | '
            f'{self.created_at:%Y-%m-%d %H:%M}'
        )


class ChecklistItem(models.Model):
    """チェックリスト習慣の個別項目"""

    habit     = models.ForeignKey(Habit, on_delete=models.CASCADE, related_name='checklist_items', verbose_name='習慣')
    text      = models.CharField(max_length=200, verbose_name='項目テキスト')
    order     = models.IntegerField(default=0, verbose_name='表示順')
    done_date = models.DateField(null=True, blank=True, verbose_name='完了日')

    class Meta:
        app_label        = 'api'
        verbose_name     = 'チェックリスト項目'
        verbose_name_plural = 'チェックリスト項目'
        ordering         = ['order', 'id']

    def __str__(self):
        return f'{self.habit.name} - {self.text}'


# 【SEC-10】Quest / QuestCompletion モデルは FEAT-207 のリブランディング後追い清掃で
# 完全削除（マイグレーション 0067_drop_quest_models）。
# 【FEAT-284】Notification choices `('quest', 'クエスト')` も migration 0080 で削除済。
# 【FEAT-285】constants.NotifType.QUEST も削除済。残置参照なし。


class Achievement(models.Model):
    # 【新規 (2026-06-26)】 13 件 → 30 件への拡張に伴い、新規 3 種の condition を
    # 追加。「習慣化を助ける」観点で行動の質を評価する指標を導入:
    #   - perfect_day_count: 全 active 習慣を達成した日数 (= 完璧な一日)
    #   - active_habits:     現在アクティブな習慣数 (= 多彩さ)
    #   - total_exp_earned:  累計獲得 EXP (= 積み上げの総量)
    CONDITION_CHOICES = [
        ('total_logs',        '累計ログ回数'),
        ('best_streak',       '最長ストリーク'),
        ('level_reached',     '到達レベル'),
        ('gacha_pulls',       'ガチャ回数'),
        ('friends_count',     'フレンド数'),
        ('perfect_day_count', '完璧な達成日数'),
        ('active_habits',     '同時アクティブ習慣数'),
        ('total_exp_earned',  '累計獲得EXP'),
    ]

    key             = models.CharField(max_length=64, unique=True)
    name            = models.CharField(max_length=64)
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    name_en = models.CharField(
        max_length=64,
        blank=True,
        default='',
        verbose_name='実績名(英語版)',
    )
    description     = models.CharField(max_length=256)
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    description_en = models.CharField(
        max_length=256,
        blank=True,
        default='',
        verbose_name='実績説明(英語版)',
    )
    icon            = models.CharField(max_length=8)
    condition_type  = models.CharField(max_length=32, choices=CONDITION_CHOICES)
    condition_value = models.IntegerField()
    reward_diamonds = models.IntegerField(default=0)
    order           = models.IntegerField(default=0)

    class Meta:
        app_label = 'api'
        ordering  = ['order', 'id']

    def __str__(self):
        return f'{self.icon} {self.name}'


class PlayerAchievement(models.Model):
    player      = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='achievements')
    achievement = models.ForeignKey(Achievement,   on_delete=models.CASCADE, related_name='player_achievements')
    unlocked_at = models.DateTimeField(auto_now_add=True)
    is_claimed  = models.BooleanField(default=False)
    # 【FEAT-314】「称号獲得時 +20 ダイヤ」(unlock 時の祝福ボーナス) の冪等担保。
    # 既存 `is_claimed` は AchievementClaimView でユーザーが任意の `reward_diamonds`
    # を受け取る別経路。本フィールドは `check_achievements` で unlock 確定時に
    # 自動付与する +20 ダイヤ祝福が一度だけ走ることを保証する。
    # migration では既存 unlock 済 PlayerAchievement を全て True で backfill する
    # ことで「過去遡及付与」を回避（Pre-mortem #2、ダイヤインフレ抑止）。
    diamond_awarded = models.BooleanField(
        default=False,
        verbose_name='称号獲得 +20 ダイヤ付与済',
        help_text='FEAT-314: unlock 時の祝福 +20 ダイヤ付与済フラグ (claim 経路とは別軸)',
    )

    class Meta:
        app_label       = 'api'
        unique_together = ('player', 'achievement')

    def __str__(self):
        return f'{self.player} - {self.achievement}'


class RestDay(models.Model):
    """休息日（ストリーク保護）"""
    player     = models.ForeignKey(PlayerProfile, on_delete=models.CASCADE, related_name='rest_days')
    date       = models.DateField()
    used_fruit = models.BooleanField(default=False, verbose_name='果実を使用して作成')  # FEAT-132
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        app_label       = 'api'
        unique_together = ('player', 'date')
        ordering        = ['-date']

    def __str__(self):
        return f'{self.player} - {self.date}'


class DailyAchievement(models.Model):
    """【FEAT-539 (2026-09-05)】その日タスクを達成した事実を 1 日 1 行で記録する。

    🔴 **連続日数 / 累計日数の真実値はこの行である。**
    `PlayerStreakState.login_streak_days` / `best_task_streak_days` は
    読み取りを速くするためのキャッシュにすぎず、
    `check_daily_achievement_consistency` が両者の一致を検証する。

    ## なぜカウンタ 2 本ではなく行なのか (指示書 §4)

    カウンタは黙ってズレ、**ズレたことを検出する手段が無い**。
    行が残っていれば `COUNT(*)` が常に真実値で、キャッシュ側が壊れても
    照合して直せる。`login_streak_days` が §2 で「誰も更新しない field」に
    なっていたのを検出できなかったのは、まさに検証手段が無かったためである。

    ## 書き込み口は 1 箇所だけ

    `services/daily_achievement.py:record_daily_achievement()` からのみ書く。
    それは `award_daily_first_task_bonus` の `transaction.atomic()` +
    `select_for_update()` のロック内で呼ばれる ——
    **その日の初回タスク達成でちょうど 1 回だけ通る場所**である。
    習慣 / ToDo / チェックリスト / タイムラインの 4 経路すべてがここを通るので、
    経路によらず 1 日 1 行になる。

    ⚠️ `date` は必ず JST (`timezone.localdate()`) の日付。UTC の `.date()` を
    渡さないこと (BUG-130 の前例)。
    """

    player = models.ForeignKey(
        PlayerProfile, on_delete=models.CASCADE,
        related_name='daily_achievements', verbose_name='プレイヤー',
    )
    date       = models.DateField(verbose_name='達成日')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        app_label   = 'api'
        verbose_name = '日次達成記録'
        verbose_name_plural = '日次達成記録'
        ordering    = ['-date']
        constraints = [
            models.UniqueConstraint(
                fields=['player', 'date'],
                name='unique_player_daily_achievement',
            ),
        ]
        indexes = [models.Index(fields=['player', '-date'])]

    def __str__(self):
        return f'{self.player} - {self.date}'
