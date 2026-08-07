import random
import string

from django.conf import settings
from django.db import models

# 【FEAT-478 Phase 2 最終 (2026-07-06)】4 State モデルは player_state.py に切出済、
# @property proxy accessor から参照するため import が必要。
# player_state.py は PlayerProfile を string ref ('PlayerProfile') で参照するため循環せず。
from .player_state import (  # noqa: F401  (re-export for backward-compat)
    PlayerEconomyState,
    PlayerBattleState,
    PlayerStreakState,
    PlayerSettings,
)


class PlayerProfile(models.Model):
    """プレイヤー情報 (基本 identity + 参照系のみ、State は 4 分割モデルに移動済)。

    【FEAT-478 Phase 2 最終 (2026-07-06)】以下 4 State モデルへ分割済:
      - PlayerEconomyState:  diamonds / coins / character_exchange_tickets 等
      - PlayerBattleState:   level / exp / battle_charges 等
      - PlayerStreakState:   streak / login / daily counters
      - PlayerSettings:      privacy / notifications / week/month reset 等

    アクセスは `player.economy.diamonds` / `player.battle.level` / `player.streak.login_streak_days`
    / `player.settings.week_start_day` の @property proxy 経由。
    """

    # 【FEAT-233】3 値化（男性 / 女性 / 回答しない）。
    # キー: 'm' = 男性, 'f' = 女性, 'n' = 回答しない（noanswer）。
    # default='f' は維持（既存ユーザーへの影響を最小化）、新規ユーザーの onboarding は
    # OnboardingPage 側で 'n' を default として PATCH する設計。
    GENDER_CHOICES = [
        ('m', '男性'),
        ('f', '女性'),
        ('n', '回答しない'),
    ]

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name='player_profile',
        verbose_name='ユーザー',
    )
    name = models.CharField(max_length=50, default='勇者', verbose_name='プレイヤー名')
    gender = models.CharField(
        max_length=1,
        choices=GENDER_CHOICES,
        default='f',
        verbose_name='性別',
    )
    # 【FEAT-423 (2026-06-10)】8 桁数字に変更 (旧: XXXX-XXXX 9 文字)。
    # 【2026-07-02】8 → 12 桁に拡張。表示は Mobile 側で 4-4-4 (「0000-0000-0000」)
    # に区切って表示、検索・コピーは `-` なしの raw 数字で。max_length=12 に緩めた
    # ため、旧 8 桁 friend_id もそのまま検索・保存可能 (後方互換維持)。
    friend_id = models.CharField(max_length=12, unique=True, blank=True, verbose_name='フレンドID')
    active_character = models.ForeignKey(
        'Character',          # string ref → gamification.py で定義、同 app 内なので解決される
        on_delete=models.SET_NULL,
        null=True, blank=True,
        related_name='+',
        verbose_name='使用中キャラクター',
    )
    # 【FEAT-304、v1.0 で deactivate (FEAT-430, 2026-06-12)】
    # v1.0: 「キャラ = ジョブ」固定化のため、BattleStartView はこの field を参照しない
    # (唯一の真実値は `active_character.job`)。field 自体は削除せず維持 — v1.1+ 熟練度
    # システム (doc/design/job_mastery_v1_1.md) で「熟練度 Max ジョブをお好きなキャラに
    # 付け替え」用に再活性化する予定。
    # SET_NULL: Job 削除時もプレイヤーは残る (Job マスタは migration 0086 で seed 済、削除想定外)。
    active_job = models.ForeignKey(
        'api.Job',          # string ref → battle.py で定義、循環 import 回避
        on_delete=models.SET_NULL,
        null=True, blank=True,
        related_name='players_using',
        verbose_name='アクティブジョブ',
        help_text='FEAT-430 で v1.0 deactivate (battle.py 未参照)。v1.1+ 熟練度システムで再活用予定。',
    )
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')

    # ── State 系以外の残置 field (交換ピース / 果実配布日 / 6 stat 結晶) ──

    exchange_pieces         = models.IntegerField(default=0, verbose_name='交換ピース')
    last_fruit_distribution = models.DateField(            # FEAT-139
        null=True, blank=True,
        verbose_name='最終果実配布日',
    )

    # 【FEAT-379 (2026-05-29)】ステータス結晶 累積カウンター (6 軸)。
    # 各ステータス Lv UP 時に自動インクリメント。v1.0 は累積表示のみ、装着効果は v1.1+。
    # 命名は CATEGORY_STAT_MAP 英語キーと完全整合 (Gemini 3 軸案不採用)。
    exercise_crystal_count     = models.IntegerField(default=0, verbose_name='運動の結晶')
    learning_crystal_count     = models.IntegerField(default=0, verbose_name='学習の結晶')
    health_crystal_count       = models.IntegerField(default=0, verbose_name='健康の結晶')
    mental_crystal_count       = models.IntegerField(default=0, verbose_name='精神の結晶')
    creation_crystal_count     = models.IntegerField(default=0, verbose_name='創造の結晶')
    contribution_crystal_count = models.IntegerField(default=0, verbose_name='貢献の結晶')

    # 【FEAT-493 (2026-07-25)】フリーメモ機能 有効/無効 flag。
    # 【方針変更 (2026-07-25 hotfix)】旧 default=False (opt-in β) から default=True へ変更。
    # 理由: 「気付かれない可能性が高い」との判断で、新規ユーザーは即座に機能を認知できる
    # ようにする。既存ユーザーの取扱は migration 0186 で backfill=True 一括更新。
    # トグル自体は Settings に残置、user は明示的に無効化することができる。
    free_memo_enabled = models.BooleanField(
        default=True,
        help_text='FEAT-493 フリーメモ機能の有効/無効 flag、default ON',
        verbose_name='フリーメモ有効',
    )

    class Meta:
        app_label        = 'api'
        verbose_name     = 'プレイヤー'
        verbose_name_plural = 'プレイヤー'

    # ── 【FEAT-478 Phase 2 移行期 shim (2026-07-06)】旧 field ↔ State model map ──
    # 目的: gradual な test / caller 書換を許容する後方互換レイヤー。旧経路
    # (`PlayerProfile.objects.create(diamonds=X)` / `player.diamonds`) を受けたら
    # 対応する State モデル (economy / battle / streak / settings) に diverting する。
    # 全 caller が `player.economy.diamonds` 経由に書き換わったら本 shim (`_OLD_FIELD_TO_STATE`
    # + `__init__` + `save` + `__getattr__`) を削除して完全分離を達成。
    _OLD_FIELD_TO_STATE = {
        # Economy 系 11 field → PlayerEconomyState
        'diamonds':                       'economy',
        'diamonds_total':                 'economy',
        'bonus_coins':                    'economy',
        'coins_spent':                    'economy',
        'diamond_bonus_date':             'economy',
        'character_exchange_tickets':     'economy',
        'streak_protection_count':        'economy',
        'streak_protection_auto_enabled': 'economy',
        'streak_protection_pending':      'economy',
        'last_streak_protection_used_at': 'economy',
        'xp_boost_active_until':          'economy',
        # Battle 系 12 field → PlayerBattleState
        'level':                             'battle',
        'current_exp':                       'battle',
        'max_exp':                           'battle',
        'allocatable_points':                'battle',
        'battle_charges':                    'battle',
        'battle_charges_date':               'battle',
        'daily_exp_count':                   'battle',
        'daily_exp_count_date':              'battle',
        'daily_battle_count':                'battle',
        'daily_battle_count_date':           'battle',
        'daily_battle_limit_bonus':          'battle',
        'daily_battle_limit_purchase_count': 'battle',
        # Streak 系 8 field → PlayerStreakState
        'last_battle_diamond_at':      'streak',
        'last_streak_diamond_day':     'streak',
        'last_login_diamond_at':       'streak',
        'login_streak_days':           'streak',
        'daily_task_count':            'streak',
        'daily_task_count_date':       'streak',
        'last_friend_gift_popup_date': 'streak',
        'last_achievement_check_at':   'streak',
        # Settings 系 9 field → PlayerSettings
        'all_private':                           'settings',
        'week_start_day':                        'settings',
        'month_reset_day':                       'settings',
        'fcm_token':                             'settings',
        'reminder_enabled':                      'settings',
        'reminder_time':                         'settings',
        'mode':                                  'settings',
        'gcal_push_enabled':                     'settings',
        'timeline_uncompleted_reminder_enabled': 'settings',
        'preferred_language':                    'settings',   # 【FEAT-489 Phase 4】
    }

    # 【FEAT-478 Phase 2 移行期 shim】旧 field 名が dead field (FEAT-424/434 で機能廃止済)
    # の場合は accept-and-drop 扱い (存在しない実 field への set を silently 無視)。
    _DEAD_FIELDS = frozenset({
        'rest_fruits',                    # FEAT-424 廃止
        'legendary_slots_bonus',          # FEAT-434 廃止
        'legendary_slots_purchase_count', # FEAT-434 廃止
    })

    def __init__(self, *args, **kwargs):
        # 【FEAT-478 Phase 2 移行期 shim】旧 field kwargs を extract、save 後に State に diverting。
        pending: dict[str, dict[str, object]] = {}
        for old_name in list(kwargs.keys()):
            state_attr = self._OLD_FIELD_TO_STATE.get(old_name)
            if state_attr:
                pending.setdefault(state_attr, {})[old_name] = kwargs.pop(old_name)
            elif old_name in self._DEAD_FIELDS:
                # accept-and-drop (旧 test の legacy kwargs)
                kwargs.pop(old_name)
        super().__init__(*args, **kwargs)
        # __dict__ に直接書く (super().__init__ 後、__setattr__ フック回避)
        self.__dict__['_pending_state_kwargs'] = pending

    def save(self, *args, **kwargs):
        # 【FEAT-478 Phase 2 移行期 shim】save(update_fields=[old]) を State に diverting。
        # update_fields に旧 field が混入している場合、対応 State の update_fields に書き換え。
        update_fields = kwargs.get('update_fields')
        state_updates: dict[str, list[str]] = {}
        if update_fields is not None:
            update_fields = list(update_fields)
            new_pp_fields = []
            for name in update_fields:
                state_attr = self._OLD_FIELD_TO_STATE.get(name)
                if state_attr:
                    state_updates.setdefault(state_attr, []).append(name)
                elif name in self._DEAD_FIELDS:
                    # dead field は accept-and-drop
                    pass
                else:
                    new_pp_fields.append(name)
            if new_pp_fields:
                kwargs['update_fields'] = new_pp_fields
            else:
                # 全 update_fields が旧 field → PlayerProfile 側は save 不要
                kwargs.pop('update_fields', None)
                # 「PP save スキップ」フラグ (friend_id 生成もスキップして良い)
                self.__dict__['_skip_pp_save'] = True

        # 【2026-07-02】新規プレイヤーの friend_id を 12 桁数字で自動生成
        if not self.friend_id:
            for _ in range(100):
                fid = ''.join(random.choices(string.digits, k=12))
                if not self.__class__.objects.filter(friend_id=fid).exists():
                    self.friend_id = fid
                    break

        if not self.__dict__.pop('_skip_pp_save', False):
            super().save(*args, **kwargs)

        # 【FEAT-478 Phase 2 移行期 shim】__init__ で貯めた State 用 kwargs を今 diverting。
        pending = self.__dict__.pop('_pending_state_kwargs', None)
        if pending:
            for state_attr, kw in pending.items():
                state = getattr(self, state_attr)  # @property → get_or_create
                for k, v in kw.items():
                    setattr(state, k, v)
                state.save()

        # 【FEAT-478 Phase 2 移行期 shim】update_fields=[old] 経路の State を save。
        # 事前に caller が `p.old_field = X` を実行済み (__setattr__ shim で State に反映)。
        for state_attr, names in state_updates.items():
            state = getattr(self, state_attr)
            state.save(update_fields=names)

        # 【FEAT-478 Phase 2 移行期 shim】__setattr__ で dirty マークされた State を save。
        # `p.diamonds = X; p.save()` (update_fields 指定なし) 経路をカバー。
        dirty = self.__dict__.pop('_dirty_states', set())
        # state_updates で既に save 済のものは重複避け
        for state_attr in dirty - set(state_updates.keys()):
            state = getattr(self, state_attr)
            state.save()

    def __setattr__(self, name, value):
        # 【FEAT-478 Phase 2 移行期 shim】p.diamonds = X 経路のリダイレクト。
        # State モデルに forward、dirty マーク → 次の save() で永続化される。
        # dead field は accept-and-drop (silently 無視)。
        cls = type(self)
        old_map = cls.__dict__.get('_OLD_FIELD_TO_STATE', {})
        state_attr = old_map.get(name)
        if state_attr and getattr(self, 'pk', None):
            # save 済 = State 行が存在 → State instance に set + dirty マーク
            state = getattr(self, state_attr)  # @property (キャッシュ or get_or_create)
            object.__setattr__(state, name, value)
            # save() 時に State を保存するため dirty set に登録
            dirty = self.__dict__.setdefault('_dirty_states', set())
            dirty.add(state_attr)
            return
        elif state_attr:
            # unsaved (pk None) = __init__ 経路 → pending にプール
            pending = self.__dict__.setdefault('_pending_state_kwargs', {})
            pending.setdefault(state_attr, {})[name] = value
            return
        elif name in cls.__dict__.get('_DEAD_FIELDS', frozenset()):
            # dead field は無視 (silently drop)
            return
        super().__setattr__(name, value)

    def __getattr__(self, name):
        # 【FEAT-478 Phase 2 移行期 shim】p.diamonds / p.level 等の getter fallback。
        # __getattr__ は通常経路 (real field / @property) が失敗した時のみ呼ばれる。
        # 実 State モデル経由に translated (p.diamonds → p.economy.diamonds)。
        old_map = type(self).__dict__.get('_OLD_FIELD_TO_STATE', {})
        state_attr = old_map.get(name)
        if state_attr:
            state = super().__getattribute__(state_attr)  # @property 直呼び (再帰回避)
            return getattr(state, name)
        if name in type(self).__dict__.get('_DEAD_FIELDS', frozenset()):
            return None  # dead field は None 返却 (無かったことにする)
        raise AttributeError(name)

    # 【FEAT-478 Phase 2 移行期 shim】State cache invalidation on refresh_from_db.
    # 目的: `player.refresh_from_db()` 後に `player.diamonds` を読んだら DB の最新値を
    # 返す (旧 PP field 時代と等価な挙動)。cache を残していると 100+ tests が古い state
    # を掴んで false negative になる (P2 review 20260725 §1-c で網羅特定)。
    # habits.py 内の 2 箇所 (line 595/810) の refresh_from_db 呼び出しも同時に恩恵を
    # 受ける (view 側の hidden staleness 予防)。
    _STATE_CACHE_KEYS = (
        '_economy_state_cache',
        '_battle_state_cache',
        '_streak_state_cache',
        '_settings_state_cache',
    )

    def refresh_from_db(self, *args, **kwargs):
        for key in self._STATE_CACHE_KEYS:
            self.__dict__.pop(key, None)
        return super().refresh_from_db(*args, **kwargs)

    def __str__(self):
        return f'{self.name}'

    # ── 【FEAT-478 Phase 2c 実行完了後 (2026-07-06)】新モデルへの proxy accessor ─
    # Phase 2c (`migrate_player_profile_v2 --confirm`) で全 player に State 行を
    # 作成済のため、単純な OneToOne 参照に変更。State 行が無い環境 (test env /
    # fresh setup) では自動作成、defaults は空で OK (旧 PlayerProfile field は
    # Phase 2d の Migration 0170-0173 で削除済 = self.diamonds 等は AttributeError)。
    #
    # 各 view/service は `player.economy.diamonds` / `player.battle.level` /
    # `player.streak.login_streak_days` / `player.settings.week_start_day` 経由で
    # State モデルにアクセス。
    #
    # 【2026-08-07】`migrate_player_profile_v2` command は削除済。実行完了 +
    # 上記の自動作成があるため不要になった (git log --diff-filter=D で復元可)。
    @property
    def economy(self) -> 'PlayerEconomyState':
        # Cache: 同じ PlayerProfile instance 内で同一 State instance を返す。
        # __setattr__ shim で `state.field = value` を set したものが save() まで保持される。
        cached = self.__dict__.get('_economy_state_cache')
        if cached is not None:
            return cached
        cached, _ = PlayerEconomyState.objects.get_or_create(player=self)
        self.__dict__['_economy_state_cache'] = cached
        return cached

    @property
    def battle(self) -> 'PlayerBattleState':
        cached = self.__dict__.get('_battle_state_cache')
        if cached is not None:
            return cached
        cached, _ = PlayerBattleState.objects.get_or_create(player=self)
        self.__dict__['_battle_state_cache'] = cached
        return cached

    @property
    def streak(self) -> 'PlayerStreakState':
        cached = self.__dict__.get('_streak_state_cache')
        if cached is not None:
            return cached
        cached, _ = PlayerStreakState.objects.get_or_create(player=self)
        self.__dict__['_streak_state_cache'] = cached
        return cached

    @property
    def settings(self) -> 'PlayerSettings':
        cached = self.__dict__.get('_settings_state_cache')
        if cached is not None:
            return cached
        cached, _ = PlayerSettings.objects.get_or_create(player=self)
        self.__dict__['_settings_state_cache'] = cached
        return cached


class CharacterStat(models.Model):
    """キャラクターステータス"""

    STAT_CHOICES = [
        ('運動力', '運動力'),
        ('学習力', '学習力'),
        ('精神力', '精神力'),
        ('健康力', '健康力'),
        ('創造力', '創造力'),   # FEAT-171: DEX — アウトプット・創造行動
        ('貢献力', '貢献力'),   # FEAT-171: CHA — 利他・貢献行動
    ]

    player = models.ForeignKey(
        PlayerProfile,
        on_delete=models.CASCADE,
        related_name='stats',
        verbose_name='プレイヤー',
    )
    name = models.CharField(
        max_length=20,
        choices=STAT_CHOICES,
        verbose_name='ステータス名',
    )
    level = models.IntegerField(default=1, verbose_name='レベル')
    current_exp = models.IntegerField(default=0, verbose_name='現在EXP')
    max_exp = models.IntegerField(default=100, verbose_name='最大EXP')

    class Meta:
        app_label        = 'api'
        # 【2026-07-09】admin 側の表示名変更。
        # 従来「キャラクターステータス」は概念混同 (キャラ = Character = Sabi 等 8 種)
        # が起きやすかったため「ステータス個別編集」に変更。行別編集 (support 補償対応で
        # 1 stat をピンポイント修正) の導線として位置付ける。cross-player 比較 / 一覧は
        # 新規 PlayerStatsMatrix (proxy) 経由の pivot admin で提供。
        verbose_name     = 'ステータス個別編集'
        verbose_name_plural = 'ステータス個別編集'
        unique_together  = ('player', 'name')

    def __str__(self):
        return f'{self.player.name} - {self.name} Lv.{self.level}'


# 【2026-07-09】プレイヤーステータス pivot 用 proxy model。
#
# 従来の CharacterStat admin (`/admin/api/characterstat/`) は long-format
# (1 行 = 1 プレイヤー × 1 ステータス) で、プレイヤー数 × 6 行に膨張して
# cross-player 比較が困難だった。本 proxy は PlayerProfile を「プレイヤー
# ステータス概観」として登録し、admin 側で pivot table (1 行 = 1 プレイヤー、
# 6 ステータス列 + 合計列) を提供する。
#
# proxy=True: DB スキーマ変更ゼロ、Migration は AlterModelOptions のみ (no-op)。
# 個別 stat の CRUD は既存 CharacterStatAdmin (「ステータス個別編集」) 経由。
class PlayerStatsMatrix(PlayerProfile):
    class Meta:
        proxy = True
        app_label = 'api'
        verbose_name = 'プレイヤーステータス'
        verbose_name_plural = 'プレイヤーステータス'


# ── アカウント削除フィードバック ──────────────────────────────
DELETION_REASON_CHOICES = [
    ('too_difficult',    '使い方がわからなかった'),
    ('hard_to_continue', '続けるのが難しかった'),
    ('not_my_style',     'サビやゲーム要素が合わなかった'),
    ('switched_app',     '他のアプリに乗り換えた'),
    ('bored',            '飽きてしまった'),
    ('privacy_concern',  'データを残したくない'),
    ('other',            'その他'),
]


class AccountDeletionFeedback(models.Model):
    """アカウント削除理由フィードバック（削除後も残す）"""
    player_id    = models.IntegerField()
    player_level = models.IntegerField(default=1)
    reason       = models.CharField(max_length=30, choices=DELETION_REASON_CHOICES)
    reason_text  = models.TextField(blank=True, default='')
    app_version  = models.CharField(max_length=20, blank=True)
    created_at   = models.DateTimeField(auto_now_add=True)

    class Meta:
        app_label = 'api'
        ordering  = ['-created_at']

    def __str__(self):
        return f'Deletion({self.player_id}) - {self.reason}'


# 【FEAT-478 Phase 2 最終 (2026-07-06)】4 State モデル (PlayerEconomyState /
# PlayerBattleState / PlayerStreakState / PlayerSettings) は player_state.py に
# 切出済 (models/__init__.py + 本ファイル冒頭で re-export)。
