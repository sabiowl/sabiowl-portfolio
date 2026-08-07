from django.db import models

from .player import PlayerProfile
from .habits import Habit


# 【FEAT-213】Habit.CATEGORY_CHOICES と完全同一の 11 値に再統一。
# FEAT-208 で習慣カテゴリ 4 値に揃えた方針を覆し、`CATEGORY_STAT_MAP`（constants.py）
# で 6 ステータスへ分散マッピングするため、サイレント喪失バグは再発しない。
# 旧 'メンタル' 値はマイグレーション 0066 で '精神' に変換済み。
TIMELINE_CATEGORY_CHOICES = [
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

TIMELINE_ICON_CHOICES = [
    ('wb_sunny',         '朝・起床'),
    ('restaurant',       '食事'),
    ('directions_run',   '運動'),
    ('menu_book',        '学習'),
    ('self_improvement', '瞑想・休憩'),
    ('groups',           '社交'),
    ('work',             '作業'),
    ('bedtime',          '就寝'),
    ('event',            'その他'),
]


class TimelineEvent(models.Model):
    # ── イベント発生源（BUG-17: 外部カレンダー対応） ─────────────────
    SOURCE_LOCAL  = 'local'
    SOURCE_GOOGLE = 'google'
    SOURCE_APPLE  = 'apple'
    SOURCE_CHOICES = [
        (SOURCE_LOCAL,  'ローカル'),
        (SOURCE_GOOGLE, 'Google カレンダー'),
        (SOURCE_APPLE,  'Apple カレンダー'),
    ]

    player = models.ForeignKey(
        PlayerProfile, on_delete=models.CASCADE,
        related_name='timeline_events', verbose_name='プレイヤー',
    )
    title      = models.CharField(max_length=100, verbose_name='タイトル')
    date       = models.DateField(verbose_name='日付')
    start_time = models.TimeField(null=True, blank=True, verbose_name='開始時刻')
    end_time   = models.TimeField(null=True, blank=True, verbose_name='終了時刻')
    category   = models.CharField(
        max_length=20, choices=TIMELINE_CATEGORY_CHOICES,
        default='その他', verbose_name='カテゴリ',  # 【FEAT-213】11 値へ再拡張、未指定時の安全側 default として「その他」（6 stat 均等分散）
    )
    icon_key = models.CharField(
        max_length=50, choices=TIMELINE_ICON_CHOICES,
        default='event', verbose_name='アイコンキー',
    )
    habit = models.ForeignKey(
        Habit, on_delete=models.SET_NULL,
        null=True, blank=True, related_name='timeline_events',
        verbose_name='紐付け習慣',
    )
    memo         = models.TextField(blank=True, default='', verbose_name='メモ')
    is_completed = models.BooleanField(default=False, verbose_name='完了')
    # 【FEAT-398 (2026-05-31)】取り消し対称化 (案 B フラグ管理) のための加算記録フラグ。
    # - True:  この TimelineEvent 完了で battle_charges +1 が実際に加算された
    # - False: 加算されなかった (charges == 9 で上限 or 取り消し済み or migration 前)
    # 取り消し (TimelineUncompleteView) 時: フラグ True なら charges -1 + False 化
    battle_charges_awarded = models.BooleanField(
        default=False,
        help_text='FEAT-398: 該当 TimelineEvent 完了で battle_charges +1 が実加算されたか (取り消し時 -1 判定用)',
    )
    # 【FEAT-419 (2026-06-10)】予定時刻 ±15 分以内に完了 → コイン +5 ボーナス受領フラグ。
    # 取り消し時 (is_completed False 化) に True なら coins -= 5 で対称化 (FEAT-398 同パターン)。
    # default=False で過去データは bonus 履歴なし扱い (migration バックフィル不要)。
    on_time_bonus_awarded = models.BooleanField(
        default=False,
        verbose_name='予定時刻ボーナス受領済',
    )

    # ── 外部カレンダー対応（BUG-17） ─────────────────────────────────
    source = models.CharField(
        max_length=20,
        choices=SOURCE_CHOICES,
        default=SOURCE_LOCAL,
        verbose_name='発生源',
    )
    external_id = models.CharField(
        max_length=500,  # Google の iCalUID は長い場合がある
        blank=True,
        default='',
        verbose_name='外部イベントID',
        help_text='外部カレンダーのイベント ID（重複インポート防止）',
    )

    # 【FEAT-244】Sabiowl → Google push 時に Google 側の event ID を保存。
    # 編集 / 削除時に Google 側を追随更新するために必須。
    # NULL = まだ Google に push されていない（手動同期で一括 push 対象）。
    # `external_id` は Google → Sabiowl 取り込み時に Google の ID を保存する列で
    # 役割が逆方向。重複防止のため `ExternalCalendarImportView` は import 時に
    # `google_event_id == external_id` の行を skip する。
    google_event_id = models.CharField(
        max_length=128,
        null=True,
        blank=True,
        db_index=True,
        verbose_name='Google Event ID',
        help_text='Sabiowl → Google push 時の Google 側イベント ID（双方向追随用）',
    )

    # 【FEAT-255】Sabiowl 側の最終更新時刻（auto_now）。
    # 取り込み時の「新しい方が勝つ」判定で `last_synced_at` の補完として使う
    # （`last_synced_at` が None の旧データに対するフォールバック）。
    updated_at = models.DateTimeField(
        auto_now=True,
        help_text='FEAT-255: Sabiowl 側の最終更新時刻。'
                  'Google 取り込み時の timestamp 比較に使う。',
    )

    # 【FEAT-255】Google との最終同期時刻。
    # push 成功 / Google→Sabiowl 取り込み更新時に明示書き込み。
    # `google_updated > last_synced_at + 1s` のときのみ取り込み更新する判定キー。
    last_synced_at = models.DateTimeField(
        null=True,
        blank=True,
        db_index=True,
        help_text='FEAT-255: Google との最終同期時刻。'
                  'Google updated > last_synced_at のときに取り込み更新する。',
    )

    # 【FEAT-256】Google への push が未完了か。
    # default=True: 新規作成時は push 対象（連携なしユーザーでも True だが、
    # `TimelineListView.post` で連携状態を見て False に補正する設計）。
    # push 成功時に `TimelineGoogleLinkView.post` で False に書き換わる。
    pending_google_push = models.BooleanField(
        default=True,
        db_index=True,
        help_text='FEAT-256: Google への push が未完了かどうか。'
                  '新規作成時 True、push 成功で False。',
    )

    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering     = ['date', 'start_time']
        verbose_name = 'タイムラインイベント'
        constraints  = [
            # 同一プレイヤーの同一外部イベントを重複登録しない（external_id 空は除外）
            models.UniqueConstraint(
                fields=['player', 'source', 'external_id'],
                condition=~models.Q(external_id=''),
                name='unique_external_calendar_event',
            ),
            # 【FEAT-370 (2026-05-28)】BUG-70 構造解消: 同一プレイヤー × 同日 ×
            # 同タイトル × 同開始時刻の重複登録を DB レベルで遮断する。
            # offline → online 復帰時の二重 POST、SWR キャッシュ重畳、Backend race
            # 全てに対する終局的防衛線。
            #
            # Django 4.2 では `nulls_distinct=False` が未サポート (Django 5.0+)、かつ
            # Postgres は default で NULL を区別する (= 多重 NULL 行は通る) ため、
            # start_time あり / なしを 2 つの部分 UniqueConstraint に分割:
            #   1. start_time IS NOT NULL  → (player, date, title, start_time) で unique
            #   2. start_time IS NULL      → (player, date, title)            で unique
            # こうすることで、
            #   - 09:00 + 09:00      → ブロック（同値）
            #   - 09:00 + 21:00      → 許容（異値）
            #   - NULL + NULL        → ブロック（時刻なし予定の二重作成も検出）
            #   - NULL + 09:00       → 許容（時刻付与は新規予定扱い）
            # の 4 ケースが想定通り動く。
            # 【BUG-76 (2026-05-30) + SEC-14 (2026-05-30)】source 軸追加で cross-source 共存許可。
            # BUG-76 (migration 0113) で UniqueConstraint に source を追加し、
            # Sabiowl 既存予定 + Google Calendar 同名予定の cross-source 衝突 (IntegrityError)
            # を解消した。本 models.py はその migration と整合させて source 軸を追記。
            # (BUG-76 hotfix 時に models.py 更新が漏れていたため SEC-14 で同期)
            models.UniqueConstraint(
                fields=['player', 'source', 'date', 'title', 'start_time'],
                condition=models.Q(start_time__isnull=False),
                name='unique_timeline_event_with_starttime',
            ),
            models.UniqueConstraint(
                fields=['player', 'source', 'date', 'title'],
                condition=models.Q(start_time__isnull=True),
                name='unique_timeline_event_no_starttime',
            ),
        ]

    def __str__(self):
        return f'{self.date} {self.start_time} {self.title}'


class GoogleEventCompletion(models.Model):
    """【FEAT-426 (2026-06-11)】Google カレンダー予定の完了状態を Backend で保持。

    プライバシー保護のため、Google 予定の本文 (title/start_time/memo) は Mobile
    ローカル DB のみに保存。Backend は完了状態と Multi-device 同期に必要な
    最小限のメタデータのみを保持する設計。
    """
    player = models.ForeignKey(
        PlayerProfile, on_delete=models.CASCADE,
        related_name='google_event_completions',
    )
    google_event_id = models.CharField(max_length=255)
    event_date = models.DateField(
        help_text='cleanup 判定用 (本 model も 30 日経過で削除可能)',
    )
    is_completed = models.BooleanField(default=False)
    on_time_bonus_awarded = models.BooleanField(default=False)  # FEAT-419
    completed_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ('player', 'google_event_id')
        indexes = [
            models.Index(fields=['player', 'event_date']),
        ]

    def __str__(self):
        return f'{self.player_id}:{self.google_event_id} completed={self.is_completed}'
