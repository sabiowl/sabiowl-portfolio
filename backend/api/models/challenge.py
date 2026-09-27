"""【FEAT-465→FEAT-466 (2026-06-24)】月次カテゴリチャレンジ (全ユーザー横断)。

Gemini Ver1.1 要件 (`doc/instructions_from_gemini/challenge_system_2.md`) を PM 確定設計
(Q1-Q7 全推奨案採択) に基づき実装。`Challenge` は admin が管理する master data、
`ChallengeParticipation` は per-user の進捗 + tier 別報酬配布冪等性を保持する。

【FEAT-466 (2026-06-24) schema 置換】
FEAT-465 (Ver1.0) の単一目標方式 (`target_count` / `reward_exp`) を、3 段階
Bronze/Silver/Gold 累積開放方式に置換した。FEAT-465 commit 後、Render の
Challenge テーブルは admin から一切 seed されていない (empty) ことが前提
(`doc/instructions/FEAT-466_challenge_tier_system_v1_1.md` §9 Pre-mortem S3)。

設計判断 (詳細は指示書 §2-1 / §3-1):
    - Counter 方式 (pre-aggregated): `Challenge.current_count` を `F()` 式で
      atomic increment し、全ユーザー貢献の集計クエリを回避する (Ver1.0 から継承)。
    - 既存 `Habit.category` (CATEGORY_CHOICES 11 値) をそのまま流用、タグ field
      追加なし (Ver1.0 から継承)。
    - `is_tiered=True` (累積開放方式、リリース時デフォルト): bronze/silver/gold
      の 3 段階目標 + 報酬を設定。ゴールド達成 = 全 3 段階の報酬を獲得。
    - `is_tiered=False` (単一目標、Ver1.0 相当): `target_count_gold` /
      `reward_exp_gold` のみ使用、bronze/silver は null。
    - 報酬は lazy 配布 (`bronze_granted` / `silver_granted` / `gold_granted` の
      tier 別フラグ) + `unique_together` で 1 ユーザー 1 チャレンジにつき
      1 レコードに正規化 (Ver1.0 から継承)。
"""
from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models

from ..constants import GameBalance
from .habits import Habit


class Challenge(models.Model):
    """月次カテゴリチャレンジ (master data、Django admin で管理)。"""

    title = models.CharField(max_length=80, verbose_name='タイトル')

    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする

    # (`get_i18n_field`)。投入は `translate_master_data` 経由。

    title_en = models.CharField(

        max_length=80,

        blank=True,

        default='',

        verbose_name='タイトル(英語版)',

    )
    description = models.TextField(verbose_name='説明文')
    # 【FEAT-516 (2026-08-04)】英語版。空欄なら ja にフォールバックする
    # (`get_i18n_field`)。投入は `translate_master_data` 経由。
    description_en = models.TextField(
        blank=True,
        default='',
        verbose_name='説明文(英語版)',
    )
    category = models.CharField(
        max_length=20,
        choices=Habit.CATEGORY_CHOICES,
        verbose_name='対象カテゴリ',
    )

    # 【FEAT-466】3 段階累積開放方式の切替フラグ。
    is_tiered = models.BooleanField(
        default=True,
        verbose_name='累積開放方式',
        help_text='True: Bronze/Silver/Gold の 3 段階目標 (ゴールド達成で全段階'
                   '報酬を獲得)。False: ゴールド目標のみの単一目標 (Ver1.0 相当)。',
    )

    # 【FEAT-466】3 段階目標。is_tiered=False では bronze/silver は null 維持。
    target_count_bronze = models.IntegerField(
        null=True, blank=True, verbose_name='ブロンズ目標',
        help_text='is_tiered=True のときのみ必須 (bronze < silver < gold)。',
    )
    target_count_silver = models.IntegerField(
        null=True, blank=True, verbose_name='シルバー目標',
        help_text='is_tiered=True のときのみ必須 (bronze < silver < gold)。',
    )
    target_count_gold = models.IntegerField(
        verbose_name='ゴールド目標',
        help_text='累積開放方式の最終目標、または単一目標方式の主目標 (必須)。',
    )

    # 【FEAT-466】3 段階報酬 EXP。default は GameBalance の差し替えポイント定数を参照。
    reward_exp_bronze = models.IntegerField(
        null=True, blank=True,
        default=GameBalance.CHALLENGE_REWARD_EXP_BRONZE_DEFAULT,
        verbose_name='ブロンズ報酬 EXP',
    )
    reward_exp_silver = models.IntegerField(
        null=True, blank=True,
        default=GameBalance.CHALLENGE_REWARD_EXP_SILVER_DEFAULT,
        verbose_name='シルバー報酬 EXP',
    )
    reward_exp_gold = models.IntegerField(
        default=GameBalance.CHALLENGE_REWARD_EXP_GOLD_DEFAULT,
        verbose_name='ゴールド報酬 EXP',
    )

    current_count = models.IntegerField(
        default=0,
        verbose_name='全ユーザー貢献累計',
        help_text='denormalized counter。F() 式で atomic increment するため'
                   '直接編集は推奨しない。',
    )
    start_date = models.DateField(verbose_name='開始日')
    end_date = models.DateField(verbose_name='終了日')
    is_active = models.BooleanField(default=True, verbose_name='有効')
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='作成日時')

    class Meta:
        indexes = [
            models.Index(
                fields=['is_active', 'start_date', 'end_date'],
                name='idx_challenge_active_period',
            ),
            models.Index(
                fields=['category', 'start_date', 'end_date'],
                name='idx_challenge_category_period',
            ),
        ]

    def __str__(self):
        return self.title

    def clean(self):
        """整合性 validation (admin form 経由で `ModelAdmin.save_model` が呼ぶ)。

        【Pre-mortem S2】is_tiered=True で bronze/silver が未入力のまま保存
        されると、lazy 配布側の `target_count_bronze and total >= ...` 判定が
        None 比較で TypeError を起こす前に、admin 入力時点でブロックする。
        """
        if self.is_tiered:
            if not (self.target_count_bronze and self.target_count_silver and self.target_count_gold):
                raise ValidationError('累積開放方式では bronze/silver/gold 全ての目標を設定してください')
            if not (self.target_count_bronze < self.target_count_silver < self.target_count_gold):
                raise ValidationError('目標は bronze < silver < gold の順で設定してください')


class ChallengeParticipation(models.Model):
    """per-user のチャレンジ進捗 + tier 別報酬配布冪等性。"""

    player = models.ForeignKey(
        'api.PlayerProfile',
        on_delete=models.CASCADE,
        related_name='challenge_participations',
        verbose_name='プレイヤー',
    )
    challenge = models.ForeignKey(
        Challenge,
        on_delete=models.CASCADE,
        related_name='participations',
        verbose_name='チャレンジ',
    )
    contribution_count = models.IntegerField(default=0, verbose_name='貢献回数')
    last_contribution_date = models.DateField(
        null=True, blank=True,
        verbose_name='最終貢献日',
        help_text='1 ユーザー 1 日 1 回ガード用 (この日付と同じ日は加算しない)',
    )

    # 【FEAT-466】tier 別報酬配布冪等性。期間終了済の lazy 配布判定後は
    # 達成/未達に関わらず True 化する (再判定スキップ、§3-2 参照)。
    bronze_granted = models.BooleanField(default=False, verbose_name='ブロンズ配布済')
    silver_granted = models.BooleanField(default=False, verbose_name='シルバー配布済')
    gold_granted = models.BooleanField(default=False, verbose_name='ゴールド配布済')
    bronze_granted_at = models.DateTimeField(
        null=True, blank=True, verbose_name='ブロンズ配布日時',
        help_text='実際に EXP が配布された tier のみ記録 (未達 tier は null 維持)。',
    )
    silver_granted_at = models.DateTimeField(null=True, blank=True, verbose_name='シルバー配布日時')
    gold_granted_at = models.DateTimeField(null=True, blank=True, verbose_name='ゴールド配布日時')

    created_at = models.DateTimeField(auto_now_add=True, verbose_name='初回貢献日時')

    class Meta:
        # 【BUG-153 (2026-09-06)】model の verbose_name が無かったため、
        # admin の削除確認画面に **`challenge participation`** と英語で出ていた。
        # field には全部付いているのに model だけ抜けていた形である。
        verbose_name        = '月次チャレンジ参加'
        verbose_name_plural = '月次チャレンジ参加'
        constraints = [
            models.UniqueConstraint(
                fields=['player', 'challenge'],
                name='unique_player_challenge_participation',
            ),
        ]
        indexes = [
            # 【FEAT-466】lazy 配布クエリ用。gold_granted=False = 最終 tier が
            # 未配布 = 何らかの tier が未処理の可能性あり、を起点に絞り込む。
            models.Index(
                fields=['player', 'gold_granted', 'challenge'],
                name='idx_chpart_gold_pending',
            ),
        ]

    def __str__(self):
        return f'{self.player_id} x {self.challenge_id}'
