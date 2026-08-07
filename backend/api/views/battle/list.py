"""【FEAT-486 (2026-07-08)】バトルログ一覧 + Enemy 一覧 View。

旧 `views/battle.py` の line 877-1001 (BattleLogListView + EnemyListView) を
独立 module 化。他の battle module に依存しない (weapon_drop / start / finish のいずれからも import されない)。
"""
from rest_framework import status
from rest_framework.authentication import TokenAuthentication
from rest_framework.response import Response
from rest_framework.views import APIView

from ...authentication import GuestTokenAuthentication  # 【BUG-77 (2026-05-31)】ゲスト対応
from ...models import Battle, BattleLog, Enemy
from ...permissions import IsAuthenticatedOrGuest  # 【BUG-77 (2026-05-31)】ゲスト対応
from ...serializers import get_i18n_field
from ..mixins import PlayerMixin


class BattleLogListView(PlayerMixin, APIView):
    """`GET /api/battle/logs/?limit=10`

    プレイヤーの戦闘履歴（最新 N 件）を返す。MVP では「直前の 1 戦」表示のみだが、
    UI 拡張時に複数件取得できるよう先に list を実装しておく。
    """
    # 【BUG-77 (2026-05-31)】FEAT-188 真実値「クエストはゲストでも実データで完全動作」
    # の対応漏れ修正。バトル系 4 View (BattleStartView / BattleFinishView /
    # BattleLogListView / EnemyListView) を IsAuthenticated → IsAuthenticatedOrGuest に。
    # PlayerMixin.get_player() は既にゲスト対応済 (request.auth.player_profile 経路)。
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        player = self.get_player(request)
        try:
            limit = int(request.query_params.get('limit', '10'))
        except (TypeError, ValueError):
            limit = 10
        limit = max(1, min(limit, 50))

        logs = (
            BattleLog.objects
            .filter(battle__player=player)
            .select_related('battle', 'battle__enemy')
            .order_by('-created_at')[:limit]
        )

        return Response({
            'logs': [
                {
                    'battle_id':          log.battle_id,
                    'enemy_name':         log.battle.enemy.name,
                    'result':             log.battle.result,
                    'summary_text':       log.summary_text,
                    'rounds':             log.rounds,
                    'rewards_coins':      log.rewards_coins,
                    'rewards_exp':        log.rewards_exp,
                    'total_damage_dealt': log.total_damage_dealt,
                    'total_damage_taken': log.total_damage_taken,
                    'created_at':         log.created_at.isoformat(),
                    # 【FEAT-305】リリアの victory_just_now / defeat_just_now 判定で
                    # 「直近 5 分以内の勝敗」判定に使用。BattleLog.created_at と
                    # ほぼ同等だが、Battle.finished_at が真実値 (BattleFinishView で書き込み)。
                    'finished_at':        log.battle.finished_at.isoformat()
                                          if log.battle.finished_at else None,
                }
                for log in logs
            ],
        })


# ─────────────────────────────────────────────────────────────────────
# 【FEAT-296 Phase 2-2】EnemyListView
# ─────────────────────────────────────────────────────────────────────

class EnemyListView(PlayerMixin, APIView):
    """`GET /api/battle/enemies/`

    クエリパラメータ（optional）:
      - `tier=zako` or `tier=boss` で filter

    レスポンス: `{ enemies: [{key, name, sprite_key, base_hp, base_atk, reward_coins, reward_exp, tier, defeated}, ...] }`

    【FEAT-439 (2026-06-17)】レスポンスに `defeated: bool` を追加。プレイヤーが
    その敵に一度でも `result='win'` で勝利したかを示す。Mobile 側ギルド画面で
    弱点/耐性表示の判定に使用 (未勝利時は非表示、勝利後に表示)。
    定数キャッシュ (5 分) は撤去 — `defeated` がプレイヤー固有になるため、全ユーザー
    共通キャッシュが破綻する。代わりにクエリは:
      - Enemy 一覧 (24 件、軽量): 1 クエリ
      - 勝利済 enemy_id 集合: 1 クエリ (values_list + distinct + set 化)
    合計 2 クエリ + 1 認証クエリで計 3 クエリ程度、5 分キャッシュ撤去のコストは限定的。
    """
    # 【BUG-77 (2026-05-31)】FEAT-188 真実値「クエストはゲストでも実データで完全動作」
    # の対応漏れ修正。バトル系 4 View (BattleStartView / BattleFinishView /
    # BattleLogListView / EnemyListView) を IsAuthenticated → IsAuthenticatedOrGuest に。
    # PlayerMixin.get_player() は既にゲスト対応済 (request.auth.player_profile 経路)。
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        # 【FEAT-302】unlock_level 昇順 → base_hp 昇順で段階解放感の見通しを良くする。
        # 旧 (tier, base_hp) 順は zako→boss→mid_boss→hidden_boss と混在しやすかった。
        qs = Enemy.objects.all().order_by('unlock_level', 'base_hp', 'id')
        tier = request.query_params.get('tier')
        # 【FEAT-302】tier choices 拡張 (mid_boss / hidden_boss) に対応。
        if tier in ('zako', 'mid_boss', 'boss', 'hidden_boss'):
            qs = qs.filter(tier=tier)

        # 【FEAT-439 (2026-06-17)】プレイヤーが win 履歴を持つ enemy_id 集合。
        # values_list + distinct で 1 クエリ、set 化でメモリ内 O(1) 判定。
        player = self.get_player(request)
        defeated_enemy_ids = set(
            Battle.objects.filter(player=player, result='win')
            .values_list('enemy_id', flat=True).distinct()
        )

        locale = getattr(request, 'locale', 'ja')
        return Response({
            'enemies': [
                {
                    'key':           e.key,
                    'name':          get_i18n_field(e, 'name', locale),
                    'sprite_key':    e.sprite_key,
                    'base_hp':       e.base_hp,
                    'base_atk':      e.base_atk,
                    'base_spd':      e.base_spd,
                    'level_scaling': e.level_scaling,
                    'reward_coins':  e.reward_coins,
                    # 【FEAT-495 (2026-07-25)】旧 int(reward_exp * BATTLE_EXP_MULTIPLIER)
                    # は撤廃。migration 0187 で reward_exp に × 0.3 実効値を bake-in 済
                    # のため、DB 値を直接返却 = 表示値 = finish.py 実獲得値 の 3 者一致。
                    'reward_exp':    e.reward_exp,
                    'tier':          e.tier,
                    # 【FEAT-302】弱点/耐性 + 解禁レベル。Flutter 側は default 値で安全に読む。
                    'physical_resistance': e.physical_resistance,
                    'magical_resistance':  e.magical_resistance,
                    'weak_ult_cost':       e.weak_ult_cost,
                    'unlock_level':        e.unlock_level,
                    # 【FEAT-381 (2026-05-29)】戦闘画面背景画像 (tier 別汎用)。
                    # ギルド画面では未使用、battle_page.dart の Stack 最下層で参照。
                    'background_image_path': e.background_image_path,
                    # 【FEAT-439 (2026-06-17)】win 履歴あり = true。Mobile はこれで
                    # 弱点表示の可否を制御 (未勝利時は隠す、勝利後に表示)。
                    'defeated': e.id in defeated_enemy_ids,
                }
                for e in qs
            ],
        })
