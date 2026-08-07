"""【FEAT-486 (2026-07-08)】バトル開始 View。

旧 `views/battle.py` の line 1-88 (import + 定数) + line 186-513
(_serialize_job + BattleStartView) を独立 module 化。

エンドポイント: `POST /api/battle/start/`

【FEAT-295 Phase 1e / FEAT-296 Phase 2-2】バトル Backend API。
設計ノート (`doc/design/battle_system.md`) §3.1 / §6 / §10 を真実値とする。

**Pre-mortem #2** 対応: Sabiowl 流中間案でチート対策（厳密シミュレーションなし、
「物理的にあり得ない結果」のみ reject）。

共通定数 (finish.py からも import される):
  - _MAX_DAMAGE_MULTIPLIER
  - _TOKEN_EXPIRY_MINUTES
  - _CHARGES_PER_BATTLE
  - _RECOVERY_POTION_ITEM_ID / _MAX_POTIONS_PER_BATTLE
  - _RECOVERY_POTION_PLUS_ITEM_ID / _ATTACK_POTION_ITEM_ID / _DEFENSE_POTION_ITEM_ID
  - _MAX_NEW_POTIONS_PER_BATTLE
  - _FALLBACK_JOB_ID

【2026-07-09 撤去済 定数】
  - _MIN_BATTLE_DURATION_SEC: client trust の duration_sec 検証は client 偽装可で
    effective でない上、legitimate 1 撃キル (SSR 武器 + ATB 高速化) を誤検知して
    「+0 coins / +0 EXP」を返す副作用があったため撤去。damage cap (× 20) +
    daily_battle_count (10/日) の 2 層で bot 対策十分。
"""
import logging
import secrets

from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.authentication import TokenAuthentication
from rest_framework.response import Response
from rest_framework.views import APIView

from ...authentication import GuestTokenAuthentication  # 【BUG-77 (2026-05-31)】ゲスト対応
from ...models import (
    Battle, Enemy, Job, PlayerItem, PlayerProfile,
)
from ...permissions import IsAuthenticatedOrGuest  # 【BUG-77 (2026-05-31)】ゲスト対応
from ...serializers import get_i18n_field  # 【FEAT-489 Phase 2F-a】job_name の locale 解決
from ...services.daily_throttle_service import (  # 【FEAT-398 / FEAT-406】
    check_daily_battle_limit,
    increment_daily_battle_count,
    reset_battle_charges_if_new_day,
)
from ...services.posthog_capture import capture_for_player  # 【FEAT-408】バトル上限計測
from ..mixins import PlayerMixin
from .._error_helpers import error_response  # 【FEAT-515】

_logger = logging.getLogger(__name__)


# 不正検出の閾値（Flutter `BattleConstants` と整合、設計ノート §3.1）
# 【2026-07-09】_MIN_BATTLE_DURATION_SEC は完全撤去 (module docstring 詳細参照)。
# 短時間戦闘 anti-cheat の client trust 実装は effective でない (client 偽装可) +
# legitimate 1 撃キル (SSR 武器 + ATB 高速化) を誤検知する副作用が大のため削除。
# damage cap (× 20) + daily_battle_count (10/日) の 2 層で bot 対策十分と判断。
# 【2026-07-05】5 → 20 に緩和。旧値では dragon_slayer(+50) 装備 + FEAT-333 crit
# + 攻撃の薬 + 弱点 の乗算で `damage_dealt > enemy_hp_init * 5` を頻発しており、
# 正当な戦闘勝利が 400 (damage_unreasonable) で reject されて報酬 0 になる
# バグが発生していた (2026-07-05 報告)。Mobile 側の overkill 除外修正と併用
# するが、旧 build 対応の defense-in-depth として backend も緩和。20 でも
# 1 hit 9999 cap × 数ターンでは相当な HP 想定でしか超えないため anti-cheat
# 意義は維持できる。
_MAX_DAMAGE_MULTIPLIER = 20
_TOKEN_EXPIRY_MINUTES = 30
_CHARGES_PER_BATTLE = 3  # 【FEAT-406 (2026-06-01)】1 → 3: 3 達成で 1 戦参加可能 (旧 FEAT-295 思想復活)

# 【FEAT-298】回復薬関連定数（Flutter `RecoveryPotion` と整合）。
_RECOVERY_POTION_ITEM_ID = 'recovery_potion'
_MAX_POTIONS_PER_BATTLE = 3

# 【FEAT-376】上位ポーション定数（Flutter `RecoveryPotionPlus` / `AttackPotion` と整合）。
_RECOVERY_POTION_PLUS_ITEM_ID = 'recovery_potion_plus'
_ATTACK_POTION_ITEM_ID        = 'attack_potion'
# 【FEAT-432 (2026-06-13)】防御の薬 (1 ターン被ダメージ ÷1.5)。攻撃の薬と完全対称設計。
_DEFENSE_POTION_ITEM_ID       = 'defense_potion'
_MAX_NEW_POTIONS_PER_BATTLE   = 3  # 各新ポーション種別の上限（recovery_potion と同じ）

# 【FEAT-299】Player.active_character.job が null だった場合の安全側フォールバック。
# 指示書 Pre-mortem #4 対応: 「ジョブ未割当て = 例外」ではなく既存挙動同等の warrior。
_FALLBACK_JOB_ID = 'warrior'


# 【FEAT-489 Phase 2F-a】job=None フォールバック時の表示名 (locale 別)。
# DB を引かずに返す経路なので、ここだけは定数表を持つ。
# `Job.job_name_en` の warrior 行 (migration 0198) と同値に保つこと。
_FALLBACK_JOB_NAME = {'ja': '戦士', 'en': 'Warrior'}


def _serialize_job(job, locale='ja'):
    """Job インスタンス（or None）→ レスポンス用 dict。

    None の場合は「modifier 全て 1.0 / on_hit_effect=none / ult_cost=3」の
    既存挙動互換 dict を返す（Pre-mortem #1 退行回避）。

    【FEAT-489 Phase 2F-a】`job_name` のみ locale 依存。`job_id` は Mobile 側の
    switch key なので **絶対に locale 依存にしない**。
    `locale` は default 'ja' なので既存呼び出し (引数なし) は挙動不変。
    """
    if job is None:
        return {
            'job_id':                _FALLBACK_JOB_ID,
            'job_name':              _FALLBACK_JOB_NAME.get(locale, _FALLBACK_JOB_NAME['ja']),
            'atb_speed_modifier':    1.0,
            'attack_power_modifier': 1.0,
            'on_hit_effect':         'none',
            'ult_cost':              3,
        }
    return {
        'job_id':                job.job_id,
        'job_name':              get_i18n_field(job, 'job_name', locale),
        'atb_speed_modifier':    job.atb_speed_modifier,
        'attack_power_modifier': job.attack_power_modifier,
        'on_hit_effect':         job.on_hit_effect,
        'ult_cost':              job.ult_cost,
    }


class BattleStartView(PlayerMixin, APIView):
    """`POST /api/battle/start/`

    リクエストボディ（optional）:
      `{ "enemy_key": "goblin" | "giant_slime" | "goblin_king" | ... }`

      - 未指定 / null: ゴブリン継続（FEAT-295 後方互換、Pre-mortem #3 対応）
      - 指定: 対応する Enemy をマスタから取得して戦闘開始

    レスポンス: `{ token, enemy: {key, name, sprite_key, hp, atk, spd} }`

    エラー:
      - 400 `not_enough_charges` — `player.battle_charges < 3`
      - 400 `enemy_not_found`    — 指定 `enemy_key` が DB に存在しない
      - 404 `enemy_not_found`    — default 'goblin' すら無い（migration 0082 未適用）
    """
    # 【BUG-77 (2026-05-31)】FEAT-188 真実値「クエストはゲストでも実データで完全動作」
    # の対応漏れ修正。バトル系 4 View (BattleStartView / BattleFinishView /
    # BattleLogListView / EnemyListView) を IsAuthenticated → IsAuthenticatedOrGuest に。
    # PlayerMixin.get_player() は既にゲスト対応済 (request.auth.player_profile 経路)。
    authentication_classes = [TokenAuthentication, GuestTokenAuthentication]
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        player = self.get_player(request)
        body = request.data or {}
        # 【FEAT-296】enemy_key パラメータ（optional）。
        # 未指定なら 'goblin' で後方互換維持（Pre-mortem #3）。
        # 不正値（int / None 等）も str に正規化、空文字は default 扱い。
        raw_key = body.get('enemy_key')
        enemy_key = (raw_key or 'goblin') if isinstance(raw_key, str) and raw_key else 'goblin'

        # 【FEAT-298】回復薬使用予定数（optional, default=0, 0-3 範囲）。
        raw_potions = body.get('potions_to_use', 0)
        try:
            potions_to_use = int(raw_potions) if raw_potions is not None else 0
        except (TypeError, ValueError):
            return error_response(
                       code='invalid_potions_to_use',
                       message='回復薬の使用数が不正です 🪶',
                       status=status.HTTP_400_BAD_REQUEST,
                   )
        if potions_to_use < 0 or potions_to_use > _MAX_POTIONS_PER_BATTLE:
            return error_response(
                       code='potions_to_use_out_of_range',
                       message=f'回復薬は 0〜{_MAX_POTIONS_PER_BATTLE} 個まで設定できますよ 🪶',
                       status=status.HTTP_400_BAD_REQUEST,
                   )

        # 【FEAT-376】上位回復薬・攻撃の薬の使用予定数（optional, default=0, 0-3 範囲）。
        def _parse_potion_count(field_name: str, label: str):
            raw = body.get(field_name, 0)
            try:
                val = int(raw) if raw is not None else 0
            except (TypeError, ValueError):
                return None, error_response(
                                 code=f'invalid_{field_name}',
                                 message=f'{label}の使用数が不正です 🪶',
                                 status=status.HTTP_400_BAD_REQUEST,
                             )
            if val < 0 or val > _MAX_NEW_POTIONS_PER_BATTLE:
                return None, error_response(
                                 code=f'{field_name}_out_of_range',
                                 message=f'{label}は 0〜{_MAX_NEW_POTIONS_PER_BATTLE} 個まで設定できますよ 🪶',
                                 status=status.HTTP_400_BAD_REQUEST,
                             )
            return val, None

        recovery_plus_to_use, err = _parse_potion_count(
            'recovery_potion_plus_to_use', '上位回復薬',
        )
        if err:
            return err
        attack_potion_to_use, err = _parse_potion_count(
            'attack_potion_to_use', '攻撃の薬',
        )
        if err:
            return err
        # 【FEAT-432】防御の薬、攻撃の薬と完全対称
        defense_potion_to_use, err = _parse_potion_count(
            'defense_potion_to_use', '防御の薬',
        )
        if err:
            return err

        with transaction.atomic():
            # 【FEAT-229 レンデブー順序】PlayerProfile → Battle の昇順ロック
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)

            # 【FEAT-398】1 日 N 回出陣上限チェック (Pre-mortem #8: select_for_update 内で実施)
            # 【FEAT-429】N = DAILY_BATTLE_LIMIT + player.daily_battle_limit_bonus (動的)
            can_battle_daily, current_daily_count, dynamic_battle_limit = check_daily_battle_limit(player)
            if not can_battle_daily:
                # 【FEAT-408】バトル日次上限到達を PostHog に記録 (best-effort)
                # Pre-mortem S2: capture_for_player は try/except 包みで best-effort 化済み
                capture_for_player(player, 'daily_battle_limit_reached', {
                    'daily_battle_count': current_daily_count,
                    'player_lv':          player.battle.level,
                })
                return error_response(
                           code='daily_battle_limit_reached',
                           message='本日は十分に挑まれましたね。羽を休めることも、'
                                   '長く飛び続けるためには必要な工程です。'
                                   '明日また、新たな冒険を始めましょう 🪶',
                           status=status.HTTP_403_FORBIDDEN,
                           extra={'current_count': current_daily_count, 'limit': dynamic_battle_limit},
                       )

            # 【FEAT-406 (2026-06-01)】Pre-mortem S1 対応: charges 消費前に日次リセットを確認。
            # 「23:59 達成 → 0:01 バトル試行」で charges が前日のまま残るシナリオを解消。
            # reset が発生した場合、charges=0 になるため直後の not_enough_charges チェックで弾かれる。
            charges_reset = reset_battle_charges_if_new_day(player)
            _battle_state = player.battle  # 【FEAT-478 Phase 2b】日次リセット後の最新 DB 状態を取得

            if _battle_state.battle_charges < _CHARGES_PER_BATTLE:
                return error_response(
                           code='not_enough_charges',
                           message='チケットが足りないようですね 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                           extra={'charges': _battle_state.battle_charges, 'required': _CHARGES_PER_BATTLE},
                       )

            # 【FEAT-298 Pre-mortem #5】回復薬所持数を select_for_update で確認。
            # `potions_to_use` が所持数を超えていたら 400（コイン無駄遣い防止と同思想）。
            if potions_to_use > 0:
                potion_item = (
                    PlayerItem.objects
                    .select_for_update()
                    .filter(player=player, item_id=_RECOVERY_POTION_ITEM_ID)
                    .first()
                )
                potion_qty = potion_item.quantity if potion_item else 0
                if potions_to_use > potion_qty:
                    return error_response(
                               code='not_enough_potions',
                               message='回復薬の所持数を超えています 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                               extra={'owned': potion_qty, 'requested': potions_to_use},
                           )

            # 【FEAT-376】上位回復薬の所持数確認
            if recovery_plus_to_use > 0:
                plus_item = (
                    PlayerItem.objects
                    .select_for_update()
                    .filter(player=player, item_id=_RECOVERY_POTION_PLUS_ITEM_ID)
                    .first()
                )
                plus_qty = plus_item.quantity if plus_item else 0
                if recovery_plus_to_use > plus_qty:
                    return error_response(
                               code='not_enough_recovery_potion_plus',
                               message='上位回復薬の所持数を超えています 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                               extra={'owned': plus_qty, 'requested': recovery_plus_to_use},
                           )

            # 【FEAT-376】攻撃の薬の所持数確認
            if attack_potion_to_use > 0:
                atk_item = (
                    PlayerItem.objects
                    .select_for_update()
                    .filter(player=player, item_id=_ATTACK_POTION_ITEM_ID)
                    .first()
                )
                atk_qty = atk_item.quantity if atk_item else 0
                if attack_potion_to_use > atk_qty:
                    return error_response(
                               code='not_enough_attack_potion',
                               message='攻撃の薬の所持数を超えています 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                               extra={'owned': atk_qty, 'requested': attack_potion_to_use},
                           )

            # 【FEAT-432】防御の薬の所持数確認（攻撃の薬と完全対称）
            if defense_potion_to_use > 0:
                def_item = (
                    PlayerItem.objects
                    .select_for_update()
                    .filter(player=player, item_id=_DEFENSE_POTION_ITEM_ID)
                    .first()
                )
                def_qty = def_item.quantity if def_item else 0
                if defense_potion_to_use > def_qty:
                    return error_response(
                               code='not_enough_defense_potion',
                               message='防御の薬の所持数を超えています 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                               extra={'owned': def_qty, 'requested': defense_potion_to_use},
                           )

            # 【FEAT-296】指定された enemy_key の Enemy を取得。
            # default 'goblin' でも存在しなければ seed 未適用なので 404。
            try:
                enemy = Enemy.objects.get(key=enemy_key)
            except Enemy.DoesNotExist:
                # default ゴブリンが無い = seed 未適用なので 404、
                # それ以外(ユーザー指定が不正)は 400。
                if enemy_key == 'goblin':
                    _logger.error(
                        'BattleStartView: goblin enemy not found, '
                        'migration 0082 未適用?',
                    )
                    return error_response(
                               code='enemy_not_found',
                               message='敵データが見つかりませんでした 🪶',
                               status=status.HTTP_404_NOT_FOUND,
                           )
                return error_response(
                           code='enemy_not_found',
                           message='指定された敵が見つからないようです 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            # 敵パラメータを player.level に応じてスケール
            #
            # 【FEAT-400 v3 (2026-05-31)】HP は base_hp 固定、Player 成長で撃数自然減。
            # 旧式 (base_hp * scaling * level) は Lv 上昇で撃数増える傾向があり、
            # ユーザー要望「解禁直後は挑戦的、+N Lv で倒せる」と矛盾していた。
            #
            # 【FEAT-522 (2026-08-07)】ATK も Lv 連動をやめ、**設定値 = 1 発のダメージ**にする。
            #
            # 旧式 `base_atk * level_scaling * level` は FEAT-295 (バトル MVP 初版) の
            # ままで、設計判断ではなかった。admin に 12 と入れた ice_witch が Lv 25 で
            # 150、Lv 48 では設定値の 24 倍を与えており、**admin の数字から実ダメージが
            # 読めない**状態だった。FEAT-400 v3 が「Lv 連動で緊張感維持」として据え置いた
            # 際の worked example (Player HP 280) は 2026-06-13 の HP 2 倍化前の値で、
            # 現在は 560。効果として主張された緊張感の上げ幅は Lv 18→50 で 4 ポイントしかない。
            # 一方 HP を固定した根拠は「Player 成長で撃数自然減」であり、ATK 側と方向が
            # 逆を向いていた。unlock_level で 24 体を段階解放する構造では固定の方が一貫する。
            #
            # `level_scaling` は式から外さない (外すと死にフィールドになり、削除のための
            # 別 FEAT が必要になる)。**unlock_level を基点**にすることで意味を持たせ直す:
            #   0     = 固定 (全 24 体の既定、本 FEAT の要件)
            #   0 超  = その敵だけ unlock_level 以降に緩やかに追随
            # どちらでも「解禁時のダメージ = 設定値」は常に成立する。
            scaled_hp  = enemy.base_hp
            scaled_atk = int(enemy.base_atk * (
                1 + enemy.level_scaling
                * max(0, _battle_state.level - enemy.unlock_level)
            ))

            token = secrets.token_urlsafe(24)  # 32 文字程度

            # 【FEAT-376 + FEAT-432】potions_planned は全ポーション種別の合計を記録
            # (recovery_potion + recovery_potion_plus + attack_potion + defense_potion)。
            total_potions_planned = (
                potions_to_use + recovery_plus_to_use
                + attack_potion_to_use + defense_potion_to_use
            )
            Battle.objects.create(
                player=player,
                enemy=enemy,
                enemy_hp_init=scaled_hp,
                enemy_atk_init=scaled_atk,
                token=token,
                potions_planned=total_potions_planned,  # 【FEAT-298 + FEAT-376】全種別合計を記録
            )

            # 【FEAT-398】出陣成功確定 → 日次バトルカウント +1 (Pre-mortem #8: lock 内で実施)
            increment_daily_battle_count(player)
            # 【FEAT-478 Phase 2b】increment_daily_battle_count が battle state を内部で保存。
            # charges は reset_battle_charges_if_new_day が内部で保存済み。player.save() 不要。

            # 【FEAT-430 (2026-06-12)】ジョブ解決を「キャラ = ジョブ」固定化に簡素化:
            #   1. `active_character.job` (Character 初期ジョブ、唯一の真実値)
            #   2. `_serialize_job(None)` で warrior フォールバック (FEAT-299 Pre-mortem #4)
            #
            # 旧 (FEAT-299/304/393): `player.active_job` (PartyEditDialog 上書き) を最優先で
            # 読んでいたが、v1.0 で「キャラ = ジョブ」固定化のため当 field は参照しない
            # (PlayerProfile.active_job field 自体は v1.1+ 熟練度システムで再活用するため維持)。
            #
            # in_bulk() は 1 query のまま維持 (v1.1+ で複数 Job 参照が再度必要になる想定、
            # FEAT-393 P2-1 / Pre-mortem #3 整合)。
            all_jobs_by_pk = Job.objects.in_bulk()  # 1 query で全 8 ジョブを dict 取得

            player_job_obj = None
            active_char = player.active_character
            if active_char is not None and active_char.job_id is not None:
                player_job_obj = all_jobs_by_pk.get(active_char.job_id)
                if player_job_obj is None:
                    # Pre-mortem #4: migration 未適用等の異常状態でも継続。
                    _logger.warning(
                        'BattleStartView: Character.job_id=%s not found in Job table (in_bulk)',
                        active_char.job_id,
                    )

        return Response({
            'token': token,
            'enemy': {
                'key':        enemy.key,
                'name':       enemy.name,
                'sprite_key': enemy.sprite_key,
                'hp':         scaled_hp,
                'atk':        scaled_atk,
                'spd':        enemy.base_spd,
                # 【FEAT-302】弱点 / 耐性 を Flutter Combatant.* に反映する。
                # ジョブ駆動の jobName から physical / magical 判定（_handlePlayerTurn）。
                'physical_resistance': enemy.physical_resistance,
                'magical_resistance':  enemy.magical_resistance,
                'weak_ult_cost':       enemy.weak_ult_cost,
                # 【FEAT-381 (2026-05-29)】戦闘画面背景画像 (tier 別汎用 or Enemy 個別 override)。
                # Flutter battle_page.dart の Stack 最下層で参照、空文字 = 単色フォールバック。
                'background_image_path': enemy.background_image_path,
            },
            # 【FEAT-299】Flutter Combatant.modifier に反映される。
            # null フォールバック時も既存挙動互換 (modifier=1.0 / ult_cost=3)。
            'player_job': _serialize_job(player_job_obj, getattr(request, 'locale', 'ja')),
            # 【FEAT-398】Flutter 側で 10/10 盾バッジ 🔒 表示用
            'daily_battle_count': player.battle.daily_battle_count,
        }, status=status.HTTP_200_OK)
