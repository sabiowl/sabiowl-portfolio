"""【FEAT-486 (2026-07-08)】バトル終了 View。

旧 `views/battle.py` の line 514-876 (BattleFinishView) を独立 module 化。

エンドポイント: `POST /api/battle/finish/`

【FEAT-295 Phase 1e】結果検証 + 報酬反映 + BattleLog 保存。
**Pre-mortem #2** 対応: 「物理的にあり得ない結果」のみ reject。

【2026-07-26 gameplay-review 20260725 §8-3 対応】400 rejection 3 経路
(`already_finished` / `token_expired` / `damage_unreasonable`) に
`_logger.warning` を追加。

背景: BUG-142 の廃棄調査で「これらの 400 応答は log 出力がゼロのため、
Render Dashboard の検索 0 件は『未発生』ではなく『観測不能』が真因」と判明した。
一方 BUG-139 (🟠 P1、track B backend 根本原因) の解決方針は「次発生時にログで
特定」であり、ログが無いままでは調査計画そのものが実行できない状態だった。
本ログはその前提条件を満たすためのもので、次に「勝ったのに報酬 0」が起きた際に
どの経路で reject されたかを prod log から特定できるようにする。
"""
import logging

from django.db import transaction
from django.utils import timezone
from rest_framework import status
from ...authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.response import Response
from rest_framework.views import APIView

from ...authentication import GuestTokenAuthentication  # 【BUG-77 (2026-05-31)】ゲスト対応
from ...constants import GameBalance  # 【FEAT-319】
from ...models import (
    Battle, BattleLog, PlayerProfile,
)
from ...permissions import IsAuthenticatedOrGuest  # 【BUG-77 (2026-05-31)】ゲスト対応
from ...services.diamond_service import award_diamond_for_battle_win  # 【FEAT-314】
from ...services.exp_service import apply_xp_boost_if_active  # 【FEAT-318 (2026-06-13 再活性化)】
from ...services.battle_finish_service import (  # 【2026-08-05】ロジックを移譲
    BattleFinishError,
    award_job_mastery,
    consume_potions,
)
from ..mixins import PlayerMixin
from ._serializers import BattleFinishSerializer  # 【2026-08-05】入力検証を移譲
from .start import (  # 共通定数を start.py から import
    _CHARGES_PER_BATTLE,
    _MAX_DAMAGE_MULTIPLIER,
    # 【2026-08-05】ポーションの item_id と上限値は
    # services/battle_finish_service.py と _serializers.py へ移動したため
    # 本ファイルからは import しない
    # (_ATTACK_POTION_ITEM_ID / _DEFENSE_POTION_ITEM_ID /
    #  _RECOVERY_POTION_ITEM_ID / _RECOVERY_POTION_PLUS_ITEM_ID /
    #  _MAX_POTIONS_PER_BATTLE / _MAX_NEW_POTIONS_PER_BATTLE)。
    # 【2026-07-09】_MIN_BATTLE_DURATION_SEC 完全撤去:
    #   1. client trust の duration_sec は容易に偽装可能 = 真の anti-cheat 効果なし
    #   2. 速度倍率 (FEAT-416)・ジョブ速度・SSR 武器高 atk・ultimate 即発動の
    #      組合せで legitimate 1 撃キル ≤ 1 秒が発生する現状 game balance
    #   3. 将来の高速化 (FEAT-379 結晶装着による atk 更なる上昇 / 新ジョブ) で
    #      閾値 1 秒でも再発する構造的リスク
    #   4. 経済リスクは低 (課金経路少、bot が奪える資産少) + damage cap
    #      (× 20) + daily_battle_count (10/日) の 2 層で bot 対策十分
    #   → CLAUDE.md「物理的にあり得ない結果のみ reject」の哲学に沿い、
    #     effective でない check は削除 (2026-07-09、user 要望)
    _TOKEN_EXPIRY_MINUTES,
)
from .weapon_drop import _try_drop_weapon  # 【FEAT-443】バトル勝利時武器ドロップ
from .._error_helpers import error_response  # 【FEAT-515】

_logger = logging.getLogger(__name__)


class BattleFinishView(PlayerMixin, APIView):
    """`POST /api/battle/finish/`

    リクエストボディ:
      ```
      {
        "token": "...",
        "result": "win" | "lose" | "abandon",
        "duration_sec": 42,
        "damage_dealt": 120,
        "damage_taken": 45,
        "rounds": 7,
        "summary_text": "サビ 通常攻撃 → ..."
      }
      ```

    レスポンス:
      ```
      {
        "coins_gained": 10, "exp_gained": 20,
        "leveled_up": false, "new_level": null,
        "new_coins": 50, "new_exp": 120,
        "battle_charges": 0
      }
      ```

    不正検出（Pre-mortem #2、すべて 400 で reject）:
      - `damage_dealt > enemy_hp_init * 20` → ダメージ値が物理的にあり得ない (2026-07-05: 5→20)
      - 30 分超過 token → セッション期限切れ
      - 二重 finish（`finished_at IS NOT NULL`）→ already finished
      - (旧) `duration_sec < N` → 【2026-07-09 撤去】client 偽装可 = effective でない +
        legitimate 1 撃キルの誤検知副作用大のため削除。詳細は import 部コメント参照。
    """
    # 【BUG-77 (2026-05-31)】FEAT-188 真実値「クエストはゲストでも実データで完全動作」
    # の対応漏れ修正。バトル系 4 View (BattleStartView / BattleFinishView /
    # BattleLogListView / EnemyListView) を IsAuthenticated → IsAuthenticatedOrGuest に。
    # PlayerMixin.get_player() は既にゲスト対応済 (request.auth.player_profile 経路)。
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        player = self.get_player(request)

        # ── 入力バリデーション ──────────────────────────────────────
        # 【2026-08-05】手動パース 78 行 (`data.get()` × 9 + `_parse_used`
        # クロージャ) を DRF Serializer に移譲した。エラーコード / 文言 /
        # 検証順序 / int coerce の非対称性はすべて現行のまま維持している
        # (`_serializers.py` の docstring と
        #  `tests/test_battle_finish_validation_contract.py` を参照)。
        serializer = BattleFinishSerializer(data=request.data or {})
        if not serializer.is_valid():
            code, message = serializer.first_error()
            return error_response(
                code=code,
                message=message,
                status=status.HTTP_400_BAD_REQUEST,
            )

        v = serializer.data_with_defaults()
        token              = v['token']
        result             = v['result']
        duration_sec       = v['duration_sec']
        damage_dealt       = v['damage_dealt']
        damage_taken       = v['damage_taken']
        rounds             = v['rounds']
        summary_text       = v['summary_text']
        potions_used       = v['potions_used']
        recovery_plus_used = v['recovery_potion_plus_used']
        attack_potion_used = v['attack_potion_used']
        defense_potion_used = v['defense_potion_used']

        with transaction.atomic():
            # 【FEAT-229 レンデブー順序】PlayerProfile → Battle 昇順
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            battle = (
                Battle.objects
                .select_for_update()
                .filter(token=token, player=player)
                .first()
            )
            if battle is None:
                return error_response(
                           code='battle_not_found',
                           message='対象の戦闘が見つかりませんでした 🪶',
                           status=status.HTTP_404_NOT_FOUND,
                       )

            # 二重 finish 防止
            if battle.finished_at is not None:
                # 【BUG-139 track B】通信 retry / double-tap での二重 finish 候補。
                # 前回 finish からの経過秒を出すことで「retry (数秒以内) か
                # 別要因 (数分後) か」を log だけで切り分けられるようにする。
                _logger.warning(
                    '[battle] finish rejected: reason=already_finished '
                    'player=%s battle=%s enemy=%s finished_at=%s '
                    'since_finish_sec=%.1f result=%s',
                    player.pk, battle.pk, battle.enemy_id,
                    battle.finished_at.isoformat(),
                    (timezone.now() - battle.finished_at).total_seconds(),
                    result,
                )
                return error_response(
                           code='already_finished',
                           message='この戦闘は既に終了しています',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            # 【Pre-mortem #2】token 30 分期限切れ
            elapsed = timezone.now() - battle.started_at
            if elapsed.total_seconds() > _TOKEN_EXPIRY_MINUTES * 60:
                battle.finished_at = timezone.now()
                battle.result      = 'abandon'
                battle.save(update_fields=['finished_at', 'result'])
                # 【BUG-139 track B】elapsed を出すことで「30 分をわずかに超えた
                # (連戦中の習慣操作で嵩んだ) のか、桁違いに放置されたのか」を判別可能に。
                _logger.warning(
                    '[battle] finish rejected: reason=token_expired '
                    'player=%s battle=%s enemy=%s elapsed_sec=%.1f limit_sec=%d',
                    player.pk, battle.pk, battle.enemy_id,
                    elapsed.total_seconds(), _TOKEN_EXPIRY_MINUTES * 60,
                )
                return error_response(
                           code='token_expired',
                           message='セッションが期限切れです',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            # 【Pre-mortem #2】物理的不可能性チェック
            # 【2026-07-09】duration_sec check 完全撤去 (import 部詳細コメント参照)。
            #   client 偽装可 = effective でない上に、legitimate 1 撃キルを誤検知して
            #   「+0 coins / +0 EXP」を返す副作用があった (user 報告 2026-07-05 /
            #   2026-07-09)。damage cap (× 20) + daily_battle_count (10/日) の 2 層で
            #   bot 対策十分と判断、check 撤去。
            if damage_dealt > battle.enemy_hp_init * _MAX_DAMAGE_MULTIPLIER:
                # 【BUG-139 track B】cap は 2026-07-05 に 5 → 20 へ緩和済 (start.py:55-67)。
                # それでも超えるケースが出たら「正当な高火力構成の誤検知」か「実際の
                # 不正」かを判断する必要があるため、実測比 (ratio) まで出す。
                # ratio が 20 台前半なら cap の再緩和検討、桁違いなら不正を疑う。
                _logger.warning(
                    '[battle] finish rejected: reason=damage_unreasonable '
                    'player=%s battle=%s enemy=%s damage=%s enemy_hp_init=%s '
                    'cap=%s ratio=%.1f',
                    player.pk, battle.pk, battle.enemy_id,
                    damage_dealt, battle.enemy_hp_init,
                    battle.enemy_hp_init * _MAX_DAMAGE_MULTIPLIER,
                    damage_dealt / battle.enemy_hp_init if battle.enemy_hp_init else -1,
                )
                return error_response(
                           code='damage_unreasonable',
                           message='ダメージ値が不正です',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            # 【FEAT-298 Pre-mortem #5 + FEAT-376 + FEAT-432】potions_used 合計が事前申告 potions_planned 超え不可
            total_potions_used = (
                potions_used + recovery_plus_used
                + attack_potion_used + defense_potion_used
            )
            if total_potions_used > battle.potions_planned:
                return error_response(
                           code='potions_used_exceeds_planned',
                           message='使用予定数を超えてポーションを使用しています 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                           extra={'planned': battle.potions_planned, 'used': total_potions_used},
                       )

            # 【FEAT-298 / 376 / 432】PlayerItem から実消費分を decrement。
            # 【2026-08-05】ほぼ同一の 4 ブロック (77 行) を service に集約した。
            # ロック順序は PlayerProfile → Battle → PlayerItem 昇順を維持
            # (service 側 docstring 参照)。
            try:
                consume_potions(player, {
                    'potions_used':              potions_used,
                    'recovery_potion_plus_used': recovery_plus_used,
                    'attack_potion_used':        attack_potion_used,
                    'defense_potion_used':       defense_potion_used,
                })
            except BattleFinishError as exc:
                return error_response(
                    code=exc.code,
                    message=exc.message,
                    status=status.HTTP_400_BAD_REQUEST,
                    extra=exc.extra,
                )

            # ── 報酬付与(win のみ)────────────────────────────────────
            eco          = player.economy   # 【FEAT-478 Phase 2b】
            battle_state = player.battle    # 【FEAT-478 Phase 2b】
            coins_gained = 0
            exp_gained   = 0
            leveled_up   = False
            new_level    = None
            old_level    = battle_state.level

            if result == 'win':
                coins_gained = battle.enemy.reward_coins
                # 【FEAT-495 (2026-07-25)】旧 int(reward_exp * BATTLE_EXP_MULTIPLIER)
                # は撤廃。FEAT-406 の × 0.3 削減は migration 0187 で reward_exp に
                # bake-in 済のため、DB 値を直接使用 = 表示値 = 実獲得値 の 3 者一致。
                # バトル coin は変更なし (経済の主役を維持、ガチャ・ショップ動機保持)。
                exp_gained   = battle.enemy.reward_exp
                # 【FEAT-318 (2026-06-13 再活性化)】XP ブースト有効時 ×1.5。
                exp_gained   = apply_xp_boost_if_active(player, exp_gained)

                # coins は bonus_coins を流用（既存 Sabiowl の coin 計算式と整合させるため）
                eco.bonus_coins += coins_gained
                eco.save(update_fields=['bonus_coins'])

                battle_state.current_exp += exp_gained
                while battle_state.current_exp >= battle_state.max_exp:
                    battle_state.current_exp        -= battle_state.max_exp
                    battle_state.level              += 1
                    # 【FEAT-537】旧リテラル 3。経路差は撤回し全経路で共通定数を使う。
                    battle_state.allocatable_points += GameBalance.ALLOCATABLE_POINTS_PER_LEVEL
                    # 【FEAT-319】level_to_max_exp で単一真実値化、直書き禁止。
                    battle_state.max_exp             = GameBalance.level_to_max_exp(battle_state.level)
                leveled_up = battle_state.level > old_level
                if leveled_up:
                    new_level = battle_state.level

            # チケット消費(勝敗問わず -_CHARGES_PER_BATTLE、abandon でも消費)
            # 【FEAT-406】1 戦消費 = -3 (3 達成 = 1 戦の思想復活、_CHARGES_PER_BATTLE 経由で自動追従)
            battle_state.battle_charges = max(0, battle_state.battle_charges - _CHARGES_PER_BATTLE)
            if result == 'win':
                battle_state.save(update_fields=[
                    'current_exp', 'level', 'allocatable_points', 'max_exp', 'battle_charges',
                ])
            else:
                battle_state.save(update_fields=['battle_charges'])

            # 【FEAT-314】その日初のバトル勝利で +5 ダイヤ。
            # `award_diamond_for_battle_win` は内部で `select_for_update` 取得 +
            # `last_battle_diamond_at == today` の冪等チェック。
            # Pre-mortem #3: `timezone.localdate()` で JST 統一 (既存
            # `award_diamond_if_first_today` と同パターン)。
            battle_diamond_earned = False
            weapon_dropped = None  # 【FEAT-443】木製武器 10% ドロップ
            puzzle_piece_colored = None  # 【FEAT-479】バトル勝利 → grey piece の color 化
            if result == 'win':
                today_local = timezone.localdate()
                battle_diamond_earned = award_diamond_for_battle_win(
                    player, today_local,
                )
                # 【FEAT-443 (2026-06-20) → FEAT-444 (2026-06-20)】2 段ドロップ:
                # Rare 10% (12 種) を先に roll → 不発時 Normal 15% (12 種) を roll。
                # 各 tier 内では未所持のみ抽選 (UniqueConstraint 違反防止)。
                # 既に player は select_for_update 済、トランザクション内で実行。
                weapon_dropped = _try_drop_weapon(player)

                # 【FEAT-479 (2026-07-06)】その日初回のバトル勝利で grey ピース 1 枚を color 化。
                # `try_grant_quest_piece` の内部で `last_quest_piece_date` で日次ガード、
                # active_scene 未設定 or 同日既取得 or grey ピース 0 個なら None。
                # 完成時は追加で {reward_exp, reward_diamonds, next_scene_hint}。
                from ...services.puzzle_world_service import try_grant_quest_piece
                puzzle_piece_colored = try_grant_quest_piece(player, today_local)

            # ── 【FEAT-511 Phase A】ジョブ熟練度 EXP 加算 ────────────────
            # 【2026-08-05】49 行を service に移譲。レスポンス用 dict まで
            # service が組んで返す (view は受け取って載せるだけ)。
            job_mastery_data = award_job_mastery(player, battle, result)

            # ── Battle 終了 + BattleLog 保存 ────────────────────────
            battle.result       = result
            battle.finished_at  = timezone.now()
            battle.potions_used = potions_used  # 【FEAT-298】履歴用
            battle.save(update_fields=['result', 'finished_at', 'potions_used'])

            BattleLog.objects.create(
                battle=battle,
                summary_text=summary_text,
                total_damage_dealt=damage_dealt,
                total_damage_taken=damage_taken,
                rounds=rounds,
                rewards_coins=coins_gained,
                rewards_exp=exp_gained,
            )

        return Response({
            'coins_gained':   coins_gained,
            'exp_gained':     exp_gained,
            'leveled_up':     leveled_up,
            'new_level':      new_level,
            'new_coins':      eco.bonus_coins - eco.coins_spent,  # 既存 Sabiowl 計算式
            'new_exp':        battle_state.current_exp,
            'battle_charges': battle_state.battle_charges,
            # 【FEAT-314】その日初のバトル勝利時のみ true、Flutter 側でサビトースト発火条件。
            'battle_first_diamond': battle_diamond_earned,
            # 【FEAT-443 (2026-06-20)】木製武器ドロップ (null = ドロップなし、
            # dict = {weapon_key, weapon_name, atk_bonus})、Flutter 側で SnackBar 発火。
            'weapon_dropped': weapon_dropped,
            # 【FEAT-479 (2026-07-06)】その日初回のバトル勝利で grey ピース color 化。
            # non-null なら Mobile が Quest piece 演出モーダルを表示、
            # scene_completed=True なら完成モーダル + WorldAnimatedLayers 起動。
            'puzzle_piece_colored': puzzle_piece_colored,
            # 【FEAT-511 Phase A】ジョブ熟練度 (null = active_character.job なし)
            'job_mastery': job_mastery_data,
        }, status=status.HTTP_200_OK)
