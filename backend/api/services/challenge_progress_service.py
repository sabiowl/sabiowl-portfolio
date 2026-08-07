"""【FEAT-465 (2026-06-24)】月次カテゴリチャレンジの進捗加算サービス。

`habit_count_service._apply_plus` (HabitCountView / ChecklistItemToggleView の
共通エントリポイント) から呼ばれる。ToDo (`habit_type='todo'`) は呼び出し元で
ガードするため本関数は対象外判定を行わない。

設計判断 (詳細は `doc/instructions/FEAT-465_challenge_system_v1.md` §7 Pre-mortem):
    - S1 (並列 race): `Challenge.current_count` は `F()` 式で atomic increment
      する。`ChallengeParticipation` は `select_for_update().get_or_create()` で
      per-user ロックを取得する。
    - レンデブー順序: 呼び出し元で PlayerProfile → Habit → HabitLog の順に
      ロック取得済の前提。本関数内では Challenge → ChallengeParticipation の
      順 (各 pk 昇順) で追加ロックを取得し、CLAUDE.md「select_for_update の
      レンデブー順序統一」を遵守する。
    - S2 (例外による進捗消失): 本関数は呼び出し元の `transaction.atomic()` 内で
      実行され、想定外例外を握りつぶす try/except は書かない (best-effort 設計
      禁止、強整合性優先)。
    - S6 (FEAT-194/398 EXP スロットルとの相互作用): チャレンジ進捗は EXP スロットル
      の対象外。1 日 1 回ガードが既に上限を担保しているため、二重削減は過剰。
"""
from datetime import date as date_t

from django.db.models import F

from ..models import Challenge, ChallengeParticipation, PlayerProfile
from .posthog_capture import capture_for_player


def increment_challenge_progress(
    player: PlayerProfile,
    habit_category: str,
    today: date_t,
) -> None:
    """対象カテゴリの稼働中チャレンジに +1 加算する (1 ユーザー 1 日 1 回ガード)。

    Args:
        player: ロック取得済み (呼び出し元で select_for_update 済み前提)
        habit_category: `Habit.category` (CATEGORY_CHOICES 11 値のいずれか)
        today: `timezone.localdate()` で呼び出し元が 1 回取得した日付
    """
    challenges = Challenge.objects.select_for_update().filter(
        category=habit_category,
        start_date__lte=today,
        end_date__gte=today,
        is_active=True,
    ).order_by('pk')  # ★ レンデブー順序統一 (CLAUDE.md 既存規範)

    for challenge in challenges:
        participation, _created = ChallengeParticipation.objects.select_for_update().get_or_create(
            player=player, challenge=challenge,
            defaults={'contribution_count': 0, 'last_contribution_date': None},
        )
        # 【Q2 ガード】同日多重加算防止
        if participation.last_contribution_date == today:
            continue

        participation.contribution_count += 1
        participation.last_contribution_date = today
        participation.save(update_fields=['contribution_count', 'last_contribution_date'])

        # global counter は F 式で原子的 atomic increment
        Challenge.objects.filter(pk=challenge.pk).update(current_count=F('current_count') + 1)

        capture_for_player(player, 'challenge_progress_incremented', {
            'challenge_id': challenge.id,
            'challenge_category': challenge.category,
            'contribution_count': participation.contribution_count,
        })
