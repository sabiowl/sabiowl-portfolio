"""【FEAT-465→FEAT-466 (2026-06-24)】月次カテゴリチャレンジの報酬 lazy 配布サービス。

`ChallengeListView.get` から best-effort で呼ばれる。終了済チャレンジ +
1 回以上貢献 + 未完全配布の participation を集約し、tier (Bronze/Silver/Gold)
別の達成判定 + 累積開放方式での EXP 配布を行う。

【FEAT-466 (2026-06-24) tier 別冪等性化】
FEAT-465 (Ver1.0) の単一 `reward_granted` フラグを `bronze_granted` /
`silver_granted` / `gold_granted` の 3 フラグに分割した。`is_tiered=True` の
チャレンジでは 3 段階を独立判定 + 累積配布 (ゴールド到達 = 全段階の報酬を獲得)、
`is_tiered=False` では gold のみ判定する (Ver1.0 相当の単一目標)。

設計判断 (詳細は §9 Pre-mortem):
    - S1 (二重発火): `select_for_update()` で per-participation ロックを取得し、
      ロック後に各 tier flag を再判定する (Get-Modify-Save パターン)。先行
      リクエストが flag を True にして commit すれば、後続リクエストのロック
      取得時点でフィルタ条件 (`gold_granted=False`) に合致しなくなるため
      二重配布されない (R11 契約テストで縛る)。
    - S2 (bronze/silver が null の race): lazy 配布ロジックの判定式は
      `ch.target_count_bronze and total >= ch.target_count_bronze` の二段
      guard で null 安全性を確保 (Challenge.clean() の admin form validation
      と二重防御)。
    - S6 (FEAT-194/398 EXP スロットル): チャレンジ報酬の EXP 配布は対象外
      (バッチ報酬は throttle に乗せない設計判断、Ver1.0 から継承)。
    - 既存 `add_exp` 経路とは分離した専用経路 (`_award_challenge_exp`)。
    - レンデブー順序: CLAUDE.md「select_for_update のレンデブー順序統一」遵守。
      `increment_challenge_progress` (PlayerProfile → Challenge →
      ChallengeParticipation) と整合させ、本関数も PlayerProfile を先にロック
      してから ChallengeParticipation をロックする (逆順だと deadlock リスク、
      Ver1.0 指示書の逆順記載から Develop 判断で修正済)。
    - 期間終了済時点で全 tier flag を True 化 (達成 / 未達問わず) — 再判定
      スキップで冪等性確保。配布 timestamp は実際に配布された tier のみ記録
      (未達 tier の `*_granted_at` は null 維持、監査で区別可能)。
"""
from datetime import date as date_t

from django.db import transaction
from django.utils import timezone

from ..constants import GameBalance
from ..models import ChallengeParticipation, PlayerProfile
from ..serializers import get_i18n_field  # 【2026-08-11】challenge_title の locale 解決
from .posthog_capture import capture_for_player


def grant_pending_rewards(player: PlayerProfile, locale: str = 'ja') -> list[dict]:
    """終了済 + 未完全配布の participation を集約し、tier 別に判定 + EXP 配布する。

    Args:
        locale: `challenge_title` の解決に使う。**既定 'ja' で従来挙動と同一**
            なので、渡していない呼び出し元があっても壊れない。
            【2026-08-11】ここが locale を取らず生の `challenge.title` を返して
            いたため、英語 UI の報酬 SnackBar だけ日本語のチャレンジ名が出ていた。

    Returns:
        [{'challenge_id', 'challenge_title', 'granted_tiers', 'total_reward_exp',
          'achieved_any'}, ...]
        `granted_tiers` は常に Bronze→Silver→Gold 順 (Mobile 側 helper が
        `.last` で最高 tier を取得する設計、S4 参照)。
    """
    today: date_t = timezone.localdate()
    results: list[dict] = []

    with transaction.atomic():
        # ★ レンデブー順序: PlayerProfile を先にロックしてから ChallengeParticipation。
        locked_player = PlayerProfile.objects.select_for_update().get(pk=player.pk)

        pending = (
            ChallengeParticipation.objects
            .select_for_update()
            .filter(
                player=locked_player,
                gold_granted=False,  # 最終 tier 未配布のものを起点 (S1 参照)
                contribution_count__gte=1,
                challenge__end_date__lt=today,  # 終了済
            )
            .select_related('challenge')
            .order_by('pk')
        )

        for participation in pending:
            challenge = participation.challenge
            total = challenge.current_count
            granted_tiers: list[str] = []

            if challenge.is_tiered:
                # ── 累積開放方式: 各 tier を順番に判定 + 配布 ──
                if (
                    not participation.bronze_granted
                    and challenge.target_count_bronze
                    and total >= challenge.target_count_bronze
                ):
                    _award_challenge_exp(
                        locked_player, challenge.reward_exp_bronze or 0,
                        challenge=challenge, tier='bronze',
                    )
                    granted_tiers.append('bronze')
                if (
                    not participation.silver_granted
                    and challenge.target_count_silver
                    and total >= challenge.target_count_silver
                ):
                    _award_challenge_exp(
                        locked_player, challenge.reward_exp_silver or 0,
                        challenge=challenge, tier='silver',
                    )
                    granted_tiers.append('silver')
                if not participation.gold_granted and total >= challenge.target_count_gold:
                    _award_challenge_exp(
                        locked_player, challenge.reward_exp_gold,
                        challenge=challenge, tier='gold',
                    )
                    granted_tiers.append('gold')

                # ── 期間終了済なので全 tier フラグを True 化 (未達 tier も再判定スキップ) ──
                now = timezone.now()
                if not participation.bronze_granted:
                    participation.bronze_granted = True
                    participation.bronze_granted_at = now if 'bronze' in granted_tiers else None
                if not participation.silver_granted:
                    participation.silver_granted = True
                    participation.silver_granted_at = now if 'silver' in granted_tiers else None
                if not participation.gold_granted:
                    participation.gold_granted = True
                    participation.gold_granted_at = now if 'gold' in granted_tiers else None
                participation.save(update_fields=[
                    'bronze_granted', 'silver_granted', 'gold_granted',
                    'bronze_granted_at', 'silver_granted_at', 'gold_granted_at',
                ])
            else:
                # ── 累積なし: gold のみ判定 + 配布 ──
                if total >= challenge.target_count_gold:
                    _award_challenge_exp(
                        locked_player, challenge.reward_exp_gold,
                        challenge=challenge, tier='gold',
                    )
                    granted_tiers.append('gold')
                participation.gold_granted = True
                participation.gold_granted_at = timezone.now() if 'gold' in granted_tiers else None
                participation.save(update_fields=['gold_granted', 'gold_granted_at'])

            if not granted_tiers:
                capture_for_player(locked_player, 'challenge_resolved_not_achieved', {
                    'challenge_id': challenge.id,
                    'challenge_category': challenge.category,
                    'current_count': total,
                    'target_count_gold': challenge.target_count_gold,
                })

            total_reward_exp = sum([
                (challenge.reward_exp_bronze or 0) if 'bronze' in granted_tiers else 0,
                (challenge.reward_exp_silver or 0) if 'silver' in granted_tiers else 0,
                challenge.reward_exp_gold if 'gold' in granted_tiers else 0,
            ])
            results.append({
                'challenge_id': challenge.id,
                'challenge_title': get_i18n_field(challenge, 'title', locale),
                'granted_tiers': granted_tiers,
                'total_reward_exp': total_reward_exp,
                'achieved_any': bool(granted_tiers),
                # 【20260729】Mobile SnackBar 文言「N 回の貢献」で参照される。
                # 従来 response に含まれておらず Mobile 側で default 0 に落ちて
                # 「0 回の貢献」と表示されていた subtle 不整合を解消。
                'contribution_count': participation.contribution_count,
            })

    return results


def _award_challenge_exp(
    locked_player: PlayerProfile, exp_amount: int, *, challenge, tier: str,
) -> None:
    """既存 `add_exp` とは分離した専用 EXP 配布経路。

    LV up + allocatable_points 加算は維持。FEAT-194/398 の日次 EXP スロットル
    (25 件/日) は対象外 (バッチ報酬は throttle に乗らない、S6 参照)。

    【FEAT-466】tier ごとに `challenge_reward_granted` PostHog イベントを送信
    (3 段階全達成時は bronze/silver/gold で 3 イベント、tier プロパティで
    分析時に集計可能、Q7 + Pre-mortem S8)。

    Args:
        locked_player: 呼び出し元 (`grant_pending_rewards`) で select_for_update
            済みの PlayerProfile (本関数内で再ロックしない)。
        tier: 'bronze' / 'silver' / 'gold'。
    """
    locked_battle = locked_player.battle
    locked_battle.current_exp += exp_amount
    while locked_battle.current_exp >= locked_battle.max_exp:
        locked_battle.current_exp -= locked_battle.max_exp
        locked_battle.level += 1
        locked_battle.allocatable_points += GameBalance.ALLOCATABLE_POINTS_PER_LEVEL
        locked_battle.max_exp = GameBalance.level_to_max_exp(locked_battle.level)
    locked_battle.save(update_fields=['current_exp', 'level', 'max_exp', 'allocatable_points'])

    capture_for_player(locked_player, 'challenge_reward_granted', {
        'challenge_id': challenge.id,
        'challenge_category': challenge.category,
        'tier': tier,
        'reward_exp': exp_amount,
    })
