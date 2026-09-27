"""【FEAT-479 Phase 1 Step 2 (2026-07-06)】ジグソーパズル世界システムの service 層。

指示書: `doc/instructions/FEAT-479_puzzle_world_ver1.md` §3.2

## 主要関数

- `try_grant_task_piece(player, today)` — その日初回の習慣達成 → grey ピース 1 枚付与
- `try_grant_quest_piece(player, today)` — その日初回のバトル勝利 → grey piece 1 枚を color 化
- `select_active_scene(player, scene)` — アクティブシーン切替 (無料・無制限)
- `select_displayed_scene(player, scene | None)` — ワールドフレーム表示シーン切替

## 冪等性の設計

- 日次フラグ (`last_task_piece_date` / `last_quest_piece_date`) は **プレイヤー単位** で管理
- シーン切替による日次上限リセットの悪用を構造的に防ぐ (指示書 §3.2)
- 呼出側 (habit_count_service._apply_plus / TimelineCompleteView / BattleFinishView) が
  `transaction.atomic + player.select_for_update` 保護下で呼ぶ前提
"""
import random as _random
from datetime import date

from django.utils import timezone as _tz

from ..constants import GameBalance
from ..models import (
    PlayerProfile,
    PlayerPuzzleSceneProgress,
    PlayerPuzzleWorld,
    PlayerPuzzleWorldHistory,
    PuzzleWorldScene,
)
from .posthog_capture import capture_for_player  # 【FEAT-479 Phase 5 (2026-07-06)】


# ─────────────────────────────────────────────────────────────────────────────
# 内部ヘルパー
# ─────────────────────────────────────────────────────────────────────────────


def _get_or_init_world(player: PlayerProfile) -> PlayerPuzzleWorld:
    """PlayerPuzzleWorld を返す。初回アクセスは active/displayed 未選択の空状態で作成。

    Note: onboarding 未完了 = active_scene_id が None、Mobile 側で選択画面へ誘導する。
    """
    obj, _ = PlayerPuzzleWorld.objects.get_or_create(player=player)
    return obj


# 【FEAT-479 hotfix (2026-07-06 → 2026-07-07 更新 → 同日 pivot)】silent
# auto-activation の default シーン key。指示書仕様 ⑧「Onboarding skip → 自動
# active (黙って)」をピース付与時にも lazy 適用するために追加 (SceneSelectionPage
# を触らず習慣達成した既存ユーザーへの safety net)。
#
# 2026-07-07 pivot: 一時的に 'first_light' (別チュートリアルシーン) に切替
# したが、PM 判断で「別シーンを増やさず morning_grassland 自体を piece_count=3
# に変更してスタート景色にする」方針に転換。「新規ユーザーの 3 日以内成功体験」
# の目的は maintained、シーン数を増やさない simpler UX。
_DEFAULT_SCENE_KEY = 'morning_grassland'


def _ensure_active_scene_silently(player: PlayerProfile) -> PlayerPuzzleWorld:
    """active_scene 未設定なら morning_grassland (3 ピース、目覚めの山頂) を
    silent auto-activate。

    指示書仕様 ⑧ の適用範囲を拡張:
    - Onboarding 完了ユーザー: 既に active_scene 設定済 → no-op
    - Onboarding 未完了 / SceneSelectionPage 未訪問ユーザー: 最初のタスク /
      バトル完了で morning_grassland に自動 active 化 (黙って、SnackBar なし)

    これにより「タスク達成しても piece がもらえない」問題を構造的に解消 +
    3 日以内成功体験 (3 ピース完成) を提供 (piece_count は migration 0178 で
    30 → 3 に変更)。
    """
    world = _get_or_init_world(player)
    if world.active_scene_id is not None:
        return world

    default_scene = PuzzleWorldScene.objects.filter(
        key=_DEFAULT_SCENE_KEY, is_active=True,
    ).first()
    if default_scene is None:
        return world  # seed 未反映 → silent no-op で当該日のみスキップ

    world.active_scene = default_scene
    world.save(update_fields=['active_scene', 'updated_at'])
    # 【Phase 5】PostHog: silent auto-activate も onboarding trigger として計測
    capture_for_player(player, 'puzzle_scene_activated', {
        'scene_key':          default_scene.key,
        'previous_scene_key': None,
        'trigger':            'onboarding_silent',
    })
    return world


def _get_or_init_progress(
    player: PlayerProfile, scene: PuzzleWorldScene,
) -> PlayerPuzzleSceneProgress:
    """指定シーンの進捗を取得。初回アクセスは全 state=0 で作成。

    【FEAT-479 v1 hotfix (2026-07-07)】piece_count 変更 lazy 追従。
    既存 progress の piece_states 長さが scene.piece_count と一致しない場合
    (morning_grassland を 30 → 3 に変更した後、旧 30 長の record を触る等)、
    自動調整する:
      - completed_at IS NOT NULL: 完成扱いを維持、`[2] * piece_count` に truncate
      - completed_at IS NULL: 未完成として `[0] * piece_count` にリセット
    「破壊的データマイグレーション禁止」原則遵守のため migration ではなく
    service 層で lazy 実施 (触られない record は変更されない)。
    """
    obj, _ = PlayerPuzzleSceneProgress.objects.get_or_create(
        player=player,
        scene=scene,
        defaults={'piece_states': [0] * scene.piece_count},
    )
    if len(obj.piece_states) != scene.piece_count:
        if obj.completed_at is not None:
            obj.piece_states = [2] * scene.piece_count
        else:
            obj.piece_states = [0] * scene.piece_count
        obj.save(update_fields=['piece_states', 'updated_at'])
    return obj


def _pick_next_scene_hint(player: PlayerProfile, current_scene_id: int) -> dict | None:
    """完成後の「次に救う世界」候補を 1 件返す (未着手の is_active シーンから)。

    Returns:
        {'scene_key', 'name', 'tagline'} — 未着手シーンが 1 件以上あれば
        None — 全 3 シーン完成 or 全て着手中の場合 (エンドコンテンツ扱い)

    指示書 S5 対策: 完成モーダルから次シーン選択画面への誘導動線を担保。
    """
    started_scene_ids = set(
        PlayerPuzzleSceneProgress.objects.filter(player=player)
        .values_list('scene_id', flat=True)
    )
    # 現アクティブは既に完成した扱いなので候補から除外 (started に含まれる)。
    # 【FEAT-479 v1 (2026-07-07)】is_tutorial=True (first_light 等) は次シーン候補
    # から除外 = 「本編シーン」のみを提案。tutorial 完成後は morning_grassland
    # 等の通常シーンに自然に導かれる。
    candidate = (
        PuzzleWorldScene.objects.filter(is_active=True, is_tutorial=False)
        .exclude(id__in=started_scene_ids)
        .order_by('display_order', 'id')
        .first()
    )
    if candidate is None:
        return None
    return {
        'scene_key': candidate.key,
        'name':      candidate.name,
        'tagline':   candidate.tagline,
    }


# ─────────────────────────────────────────────────────────────────────────────
# ピース付与ロジック (呼出側 = habit_count_service / timeline / battle)
# ─────────────────────────────────────────────────────────────────────────────


def try_grant_task_piece(player: PlayerProfile, today: date) -> dict | None:
    """【FEAT-479】その日初回の習慣達成でグレーピース 1 枚付与 (アクティブシーン)。

    呼出側が transaction.atomic + player.select_for_update 保護下で呼ぶ前提。
    `daily_task_count == 1` (increment 直後) のときのみ呼ばれる想定 (呼出側でガード)。

    Returns:
        None: 発火せず (下記いずれか)
              - PuzzleWorldScene seed 未反映 (migration 0175 未適用)
              - 同日既取得 (streak.last_task_piece_date == today)
              - active シーンの未取得ピース (state=0) が 0 個 = 全ピース取得済
        dict: {piece_index, new_state=1, scene_key} 発火時

    【FEAT-479 hotfix (2026-07-06)】active_scene 未設定でも silent auto-activate
    (morning_grassland) で必ずピース付与を試みる (指示書仕様 ⑧ の適用範囲拡張)。
    """
    world = _ensure_active_scene_silently(player)
    if world.active_scene_id is None:
        return None  # seed 未反映時のみここに到達

    streak = player.streak
    if streak.last_task_piece_date == today:
        return None

    progress = _get_or_init_progress(player, world.active_scene)
    unowned = [i for i, s in enumerate(progress.piece_states) if s == 0]
    if not unowned:
        return None

    idx = _random.choice(unowned)
    progress.piece_states[idx] = 1
    progress.save(update_fields=['piece_states', 'updated_at'])

    streak.last_task_piece_date = today
    streak.save(update_fields=['last_task_piece_date'])

    # 【FEAT-479 Phase 5】PostHog: task piece 付与を計測
    piece_count_after = sum(1 for s in progress.piece_states if s >= 1)
    capture_for_player(player, 'puzzle_piece_acquired', {
        'piece_index':       idx,
        'piece_count_after': piece_count_after,
        'scene_key':         world.active_scene.key,
    })

    return {
        'piece_index': idx,
        'new_state':   1,
        'scene_key':   world.active_scene.key,
    }


def try_grant_quest_piece(player: PlayerProfile, today: date) -> dict | None:
    """【FEAT-479】その日初回のバトル勝利でグレーピースをカラー化 (state 1 → 2)。

    呼出側 (BattleFinishView) が transaction.atomic + player.select_for_update 保護下
    で呼ぶ前提。`daily_battle_count == 1` かつ result == 'win' のときのみ呼ばれる想定。

    Returns:
        None: 発火せず (下記いずれか)
              - PuzzleWorldScene seed 未反映
              - 同日既取得 (streak.last_quest_piece_date == today)
              - active シーンのグレーピース (state=1) が 0 個
        dict: 発火時、最低限 {piece_index, new_state=2, scene_key, scene_completed}
              完成時 (scene_completed=True) は追加で:
                {reward_exp, reward_diamonds, next_scene_hint}
              完成報酬 (EXP + ダイヤ) は本関数内で PlayerBattleState / PlayerEconomyState
              に即時反映される (呼出側 transaction.atomic 内)。

    【FEAT-479 hotfix (2026-07-06)】active_scene 未設定でも silent auto-activate
    (morning_grassland) で必ず piece 化を試みる。
    """
    world = _ensure_active_scene_silently(player)
    if world.active_scene_id is None:
        return None

    streak = player.streak
    if streak.last_quest_piece_date == today:
        return None

    progress = _get_or_init_progress(player, world.active_scene)
    grey = [i for i, s in enumerate(progress.piece_states) if s == 1]
    if not grey:
        return None

    idx = _random.choice(grey)
    progress.piece_states[idx] = 2

    is_completed = all(s == 2 for s in progress.piece_states)
    save_fields = ['piece_states', 'updated_at']
    if is_completed:
        progress.completed_at = _tz.now()
        save_fields.append('completed_at')
    progress.save(update_fields=save_fields)

    streak.last_quest_piece_date = today
    streak.save(update_fields=['last_quest_piece_date'])

    result: dict = {
        'piece_index':     idx,
        'new_state':       2,
        'scene_key':       world.active_scene.key,
        'scene_completed': is_completed,
    }

    # 【FEAT-479 Phase 5】PostHog: quest piece color 化を計測
    colored_count_after = sum(1 for s in progress.piece_states if s == 2)
    capture_for_player(player, 'puzzle_piece_colored', {
        'piece_index':         idx,
        'colored_count_after': colored_count_after,
        'scene_key':           world.active_scene.key,
    })

    if is_completed:
        scene = world.active_scene
        eco = player.economy
        battle_state = player.battle

        # 完成報酬 (ダイヤ + EXP + レベルアップ)
        eco.diamonds       += scene.reward_diamonds
        eco.diamonds_total += scene.reward_diamonds
        battle_state.current_exp += scene.reward_exp

        # レベルアップ処理 (habit_count_service と同ロジック)
        # 【FEAT-537】旧リテラル 3。経路差は撤回し全経路で共通定数を使う。
        while battle_state.current_exp >= battle_state.max_exp:
            battle_state.current_exp -= battle_state.max_exp
            battle_state.level += 1
            battle_state.allocatable_points += GameBalance.ALLOCATABLE_POINTS_PER_LEVEL
            battle_state.max_exp = GameBalance.level_to_max_exp(battle_state.level)

        eco.save(update_fields=['diamonds', 'diamonds_total'])
        battle_state.save()

        # 完成履歴
        PlayerPuzzleWorldHistory.objects.create(
            player=player,
            scene=scene,
            reward_exp_gained=scene.reward_exp,
            reward_diamonds_gained=scene.reward_diamonds,
        )

        # 【FEAT-479 v1 (2026-07-08)】完成シーンを displayed_scene に自動セット。
        #
        # 目的: ユーザーが次の active_scene を選んで新しい作業を始めた後も、
        # 直近完成したシーンがワールドフレームでアニメ表示され続けるようにする。
        # 完成前は _resolveSceneRender (Mobile) の branch (A) が active 未完成を
        # 最優先で静止画表示するため、displayed が完成 scene を指していれば
        # 「active=次シーン (静止) を選ぶまでは完成 scene のアニメが見える」→
        # 「active=次シーン (未完成) 化後は静止画 + piece overlay に切替」→
        # user は SceneSelectionPage の「ホームに表示」ボタンで完成 scene を
        # displayed に再指定できるが、それを **完成直後に自動で行う** ことで
        # 「せっかく完成させたのに動く景色が見えない」体験を防ぐ。
        #
        # 上書き方針: **常に上書き** (直近完成が最新の体験の対象)。
        # user が明示的に別 scene を「ホームに表示」に設定していても、より新しい
        # 完成が起きたらそちらを優先する。user 側で戻したければ SceneSelectionPage
        # で 3 秒で再設定可能なので、コントロールは保たれる。
        #
        # 冪等性: 既に world.displayed_scene_id == scene.id でも副作用は無害 (idempotent)。
        # 排他制御: caller (BattleFinishView) が transaction.atomic() で保護済。
        # 同一 user の並列書込経路 (select_active_scene / select_displayed_scene) は
        # 別 API endpoint = ユーザー UI 上並列発火しない。
        world.displayed_scene = scene
        world.save(update_fields=['displayed_scene', 'updated_at'])

        # 【FEAT-479 Phase 5】PostHog: シーン完成を計測
        # days_from_first_piece: 初 task piece 付与日 (progress.started_at) から
        # 完成日までの日数差 (継続日数体感の指標、Ver1 の設計目標値 30-45 日)
        days_from_first = max(
            0, (progress.completed_at.date() - progress.started_at.date()).days,
        )
        capture_for_player(player, 'puzzle_scene_completed', {
            'scene_key':             scene.key,
            'days_from_first_piece': days_from_first,
        })

        # 【FEAT-479 Phase 5】全 3 シーン完成 (エンドコンテンツ体験) を計測。
        # 【FEAT-479 v1 (2026-07-07)】チュートリアル (first_light) は「本編完成」判定
        # 対象外 (既存ユーザーは first_light を触らないまま本編を完成させるパターンが
        # あるため、is_tutorial=True を含めると event が永久に発火しなくなる)。
        # is_active=True かつ is_tutorial=False の全シーンについて判定。
        active_scene_ids = set(
            PuzzleWorldScene.objects.filter(
                is_active=True, is_tutorial=False,
            ).values_list('id', flat=True)
        )
        completed_scene_ids = set(
            PlayerPuzzleWorldHistory.objects.filter(player=player)
            .values_list('scene_id', flat=True)
        )
        if active_scene_ids and active_scene_ids <= completed_scene_ids:
            # 初完成日 (履歴の最古 completed_at) からの日数
            first_history = (
                PlayerPuzzleWorldHistory.objects.filter(player=player)
                .order_by('completed_at').first()
            )
            total_days = 0
            if first_history is not None:
                total_days = max(
                    0, (progress.completed_at.date() - first_history.completed_at.date()).days,
                )
            capture_for_player(player, 'puzzle_all_scenes_completed', {
                'total_days_from_first_piece': total_days,
            })

        result['reward_exp']       = scene.reward_exp
        result['reward_diamonds']  = scene.reward_diamonds
        result['next_scene_hint']  = _pick_next_scene_hint(player, scene.id)

    return result


# ─────────────────────────────────────────────────────────────────────────────
# シーン切替 API (view から直呼び)
# ─────────────────────────────────────────────────────────────────────────────


def select_active_scene(player: PlayerProfile, scene: PuzzleWorldScene) -> None:
    """【FEAT-479 S5 対策】アクティブシーンを切替。無料・無制限 (Sabi「聖域」原則)。

    Raises:
        ValueError: scene が is_active=False の場合、または完成済 (再 active 化不可) の場合

    設計:
    - 前アクティブシーンの progress は保持 (piece_states は維持、再開可能)
    - 切替対象は is_active=True かつ未完成シーンのみ
      (完成シーンを再度 active に = 概念矛盾を防ぐ)
    """
    if not scene.is_active:
        raise ValueError('scene_not_active')

    # 完成済シーンは active に戻せない (「もう救い終わった世界を再度救う」概念矛盾)
    is_completed = PlayerPuzzleSceneProgress.objects.filter(
        player=player, scene=scene, completed_at__isnull=False,
    ).exists()
    if is_completed:
        raise ValueError('scene_already_completed')

    world = _get_or_init_world(player)
    previous_scene_key = (
        world.active_scene.key if world.active_scene_id else None
    )
    previous_active_id = world.active_scene_id
    world.active_scene = scene

    update_fields = ['active_scene', 'updated_at']
    # 【FEAT-479 hotfix (2026-07-06)】displayed_scene が旧 active と同じだった
    # 場合、new active に自動同期する。UX 期待の一致 (「今取り組んでいる景色
    # =ホーム表示」が自然)。旧 active と displayed が異なる場合 (例: 完成済
    # シーンを displayed に固定していた等) は user 意思なので保持。
    if world.displayed_scene_id == previous_active_id and previous_active_id is not None:
        world.displayed_scene = scene
        update_fields.append('displayed_scene')

    world.save(update_fields=update_fields)

    # 【FEAT-479 Phase 5】PostHog: シーン切替を計測
    # trigger = 'onboarding' (初回、previous=null) or 'manual' (以降)
    capture_for_player(player, 'puzzle_scene_activated', {
        'scene_key':          scene.key,
        'previous_scene_key': previous_scene_key,
        'trigger':            'onboarding' if previous_scene_key is None else 'manual',
    })


def select_displayed_scene(
    player: PlayerProfile, scene: PuzzleWorldScene | None,
) -> None:
    """【FEAT-479 S5 対策】ワールドフレーム表示シーンを切替。

    Args:
        scene: None なら auto fallback (active → 静止画) を有効化。
               PuzzleWorldScene 指定なら該当シーンで固定 (アクティブ or 完成済のみ)。

    Raises:
        ValueError: 未着手シーンを displayed に指定した場合 ('scene_not_available')

    設計:
    - ディスプレイド `= None` を許容 = 自動 fallback (active_scene があればそれ、
      なければ既存 world_background_service の時間帯連動)
    - 明示指定は「アクティブシーン」または「完成済シーン」のみ (未着手は不可)
    """
    world = _get_or_init_world(player)

    if scene is not None:
        is_active = (world.active_scene_id == scene.id)
        is_completed = PlayerPuzzleSceneProgress.objects.filter(
            player=player, scene=scene, completed_at__isnull=False,
        ).exists()
        if not (is_active or is_completed):
            raise ValueError('scene_not_available')

    previous_scene_key = (
        world.displayed_scene.key if world.displayed_scene_id else None
    )
    world.displayed_scene = scene
    world.save(update_fields=['displayed_scene', 'updated_at'])

    # 【FEAT-479 Phase 5】PostHog: 額縁表示シーン切替を計測
    # scene=None は自動 fallback (指示書 §3.6)、event property では 'auto_fallback' で識別
    capture_for_player(player, 'puzzle_scene_displayed_changed', {
        'scene_key':          scene.key if scene else 'auto_fallback',
        'previous_scene_key': previous_scene_key,
    })
