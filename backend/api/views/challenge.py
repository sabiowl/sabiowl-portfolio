"""【FEAT-465→FEAT-466 (2026-06-24)】月次カテゴリチャレンジ一覧 + lazy 報酬配布 View。"""
from rest_framework.response import Response
from rest_framework.views import APIView

from django.utils import timezone

from ..models import Challenge, ChallengeParticipation
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..services.challenge_reward_service import grant_pending_rewards
from .mixins import PlayerMixin

# 【FEAT-466 (2026-06-24)】1 日 1 回ガード説明 (R1)。Sabi 口調 + 🪶 マーカー必須。
# server-side 定数化により、将来の i18n 対応 / 文言修正が backend deploy のみで
# 完結する (指示書 §3-3 設計判断)。
#
# 【2026-08-03】locale 対応。FEAT-489 Phase 4 は「`_en` field を持つ master data」
# を対象にしたため、**view にハードコードされた定数**は census から漏れていた。
# 英語 UI でもここだけ日本語で出ていた (実機 QA で検出)。
#
# 英訳は native reviewer のチェック対象に含めること
# (doc/design/i18n_reviewer_brief_en.md、ARB export には乗らないため手渡しになる)。
_INFO_TEXT = {
    'ja': (
        '貢献回数は 1 日 1 人 1 回までカウントされます。'
        '焦らずとも、続けることが力になりますよ 🪶'
    ),
    'en': (
        'Contributions are counted once per person, per day. '
        'There is no need to hurry; continuing is what becomes your strength. 🪶'
    ),
}


def _info_text(locale: str) -> str:
    """locale に対応する説明文を返す。未対応 locale は ja に落とす。"""
    return _INFO_TEXT.get(locale, _INFO_TEXT['ja'])


class ChallengeListView(PlayerMixin, APIView):
    """稼働中チャレンジ一覧 + 自分の participation 情報 + lazy 報酬配布。

    GET /api/challenges/

    Response:
        {
          "info_text": "...",
          "active": [{id, title, description, category, is_tiered,
                       current_count, progress_rate, my_contribution_count,
                       remaining_days, tiers: {bronze?, silver?, gold},
                       start_date, end_date}, ...],
          "pending_rewards": [{challenge_id, challenge_title, granted_tiers,
                                 total_reward_exp, achieved_any,
                                 contribution_count}, ...]
        }

    `tiers` は `is_tiered=True` のとき bronze/silver/gold の 3 キー、
    `is_tiered=False` のときは gold のみを含む (Pre-mortem S6、Mobile 側は
    キーの有無で表示分岐する)。`pending_rewards` は `grant_pending_rewards()`
    の戻り値。Mobile はこのレスポンスを受け取った直後に `achieved_any=True`
    の分のみ Sabi 口調 SnackBar を発火する (未達は無音、Sabi「焦らずとも
    構いません」精神)。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        today = timezone.localdate()

        # lazy 報酬配布 (終了済 + 未完全配布の participation を集約)
        pending_rewards = grant_pending_rewards(player)

        active_challenges = Challenge.objects.filter(
            is_active=True,
            start_date__lte=today,
            end_date__gte=today,
        ).order_by('pk')

        participations = {
            p.challenge_id: p
            for p in ChallengeParticipation.objects.filter(
                player=player, challenge__in=active_challenges,
            )
        }

        active = []
        for challenge in active_challenges:
            participation = participations.get(challenge.id)
            my_contribution_count = participation.contribution_count if participation else 0

            # 【Pre-mortem S7】超過時の UI 崩れ防止: progress_rate は表示用に 100 でクランプ
            # (internal current_count は超過したままレスポンスに含める)。ゴールド目標を
            # 全体の進捗バーの基準とする (累積開放方式の最終境界線)。
            progress_rate = min(
                100,
                round(challenge.current_count / challenge.target_count_gold * 100)
                if challenge.target_count_gold > 0 else 0,
            )

            active.append({
                'id': challenge.id,
                'title': challenge.title,
                'description': challenge.description,
                'category': challenge.category,
                'is_tiered': challenge.is_tiered,
                'current_count': challenge.current_count,
                'progress_rate': progress_rate,
                'my_contribution_count': my_contribution_count,
                'remaining_days': max(0, (challenge.end_date - today).days),
                'tiers': _build_tiers(challenge),
                'start_date': challenge.start_date.isoformat(),
                'end_date': challenge.end_date.isoformat(),
            })

        return Response({
            'info_text': _info_text(getattr(request, 'locale', 'ja')),
            'active': active,
            'pending_rewards': pending_rewards,
            # 【2026-08-03】`title` / `description` は Challenge model に `_en` field が
            # 無いため **英語 locale でも日本語のまま返る**。同じ状態の model が
            # 他に 7 つある (FEAT-516)。ここだけ小手先で直すと画面内の整合が崩れる
            # ので、migration を伴う横断対応として別途扱う。
        })


def _build_tiers(challenge: Challenge) -> dict:
    """Challenge から tiers dict を構築する。

    `is_tiered=False` のときは gold のみを含む (bronze/silver キー自体を
    省略、Mobile 側でキーの有無により表示分岐する、Pre-mortem S6 対応)。
    """
    tiers = {}
    if challenge.is_tiered:
        if challenge.target_count_bronze:
            tiers['bronze'] = _tier_entry(
                challenge.current_count, challenge.target_count_bronze,
                challenge.reward_exp_bronze or 0,
            )
        if challenge.target_count_silver:
            tiers['silver'] = _tier_entry(
                challenge.current_count, challenge.target_count_silver,
                challenge.reward_exp_silver or 0,
            )
    tiers['gold'] = _tier_entry(
        challenge.current_count, challenge.target_count_gold, challenge.reward_exp_gold,
    )
    return tiers


def _tier_entry(current_count: int, target: int, reward_exp: int) -> dict:
    return {
        'target': target,
        'reward_exp': reward_exp,
        'achieved': current_count >= target,
        'remaining_count': max(0, target - current_count),
    }
