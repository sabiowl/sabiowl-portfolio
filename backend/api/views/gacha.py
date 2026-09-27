import logging
import random as _random
from datetime import date, timedelta

from rest_framework import status
from ..authentication import ExpiringTokenAuthentication  # 【BUG-163】DRF 素の ExpiringTokenAuthentication は停止検査も期限も持たない
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from ..authentication import GuestTokenAuthentication  # FEAT-190
from ..constants import GachaBalance, GameBalance  # 【BUG-62】単一ソース化（shop.py と共通参照）/ 【FEAT-285】GACHA_EXP 経路別 pt
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ._error_helpers import error_response  # 【FEAT-475 Phase 3b】新形式統一
from ..serializers import get_i18n_field  # 【BUG-146 Phase 2】master data の _en を読む

from django.db import transaction
from django.db.models import F
from django.utils import timezone

# 【FEAT-374】redo の時間ウィンドウ（24h）
_REDO_WINDOW_HOURS = 24
# 【FEAT-374】redo のダイヤコスト
_REDO_DIAMOND_COST = 50

from ..models import (
    Character, GachaReward, GachaHistory, HabitLog, OwnedCharacter,
    PendingDuplicateReward, PlayerGachaStatus, PlayerItem, PlayerProfile,
    PlayerWeapon, WeaponMaster,  # 【FEAT-326】weapon 排出経路
)
from .mixins import PlayerMixin
from ..services.diamond_service import record_diamond_spent  # 【FEAT-408】ダイヤ消費計測

_logger = logging.getLogger(__name__)

_DAILY_REWARDS = [
    dict(ticket_type='daily', rarity='N',   reward_type='exp',      container='chest', name='経験値ボーナス',  detail='EXP +30',         icon='⭐', weight=35, value=30),
    dict(ticket_type='daily', rarity='N',   reward_type='exp',      container='chest', name='経験値ボーナス',  detail='EXP +60',         icon='🌿', weight=25, value=60),
    dict(ticket_type='daily', rarity='R',   reward_type='exp',      container='chest', name='経験値ボーナス',  detail='EXP +120',        icon='💫', weight=18, value=120),
    # 【BUG-116 (2026-06-14)】効果時間を 24h → 15min/stock に変更 (PM 指示)。
    dict(ticket_type='daily', rarity='R',   reward_type='xp_boost', container='chest', name='XPブースト',     detail='15分 ×1.5倍',     icon='🚀', weight=12, value=1),
    # 【FEAT-326】Daily SR exp 350 の weight を 5 → 1 に再配分し、SR weapon (mythril_sword)
    # を weight=4 で追加 (合計 100 維持、SR pool 内訳 = exp 1 + xp_boost 4 + weapon 4 = 9 で
    # FEAT-326 前と同水準)。Pre-mortem #3 weight 合計の不変式 (Daily 100) を契約テストで縛る。
    dict(ticket_type='daily', rarity='SR',  reward_type='exp',      container='stone', name='大量経験値',      detail='EXP +350',        icon='💎', weight=1,  value=350),
    dict(ticket_type='daily', rarity='SR',  reward_type='xp_boost', container='stone', name='XPブースト×2',   detail='30分 ×1.5倍',     icon='🌟', weight=4,  value=2),
    dict(ticket_type='daily', rarity='SR',  reward_type='weapon',   container='stone', name='ミスリルの剣',    detail='ATK +35',         icon='⚔️', weight=4,  value=0,    weapon_key='mythril_sword'),
    dict(ticket_type='daily', rarity='SSR', reward_type='exp',      container='stone', name='特大経験値',      detail='EXP +1000',       icon='👑', weight=1,  value=1000),
]

_WEEKLY_REWARDS = [
    # 【BUG-131 (2026-06-17)】Weekly SSR character 5.00% → 0.50% へ削減。
    # 全 entry weight を再配分し合計 120 → 200 に拡張、character weight 6 → 1。
    # 配分方針 (Option B): R/SR tier の比率は厳密維持 (R 41.5% / SR 39.0% / SSR 19.5%)、
    # character から解放された 4.5% は SSR 非キャラ枠 (diamond/xp/weapon) が比例吸収。
    # 結果: 共通報酬体感は変えず character のみレア化、SSR 当たり感は微増 (14.17% → 19.0%)。
    # 【FEAT-317 (2026-08-04)】R title (weight=17) を除去し、同 rarity の
    # diamond / xp_boost に **現行 weight 比で按分吸収** (36:30 → +9/+8)。
    # rarity 越境させないのは「取得頻度が下がるほど排出が厚くなる傾斜」
    # (CLAUDE.md ガチャ設計意図) を崩さないため。R 合計 83 は不変。
    dict(ticket_type='weekly', rarity='R',   reward_type='diamond',  container='chest', name='ダイヤ',          detail='× 30',            icon='💎', weight=45, value=30),
    dict(ticket_type='weekly', rarity='R',   reward_type='xp_boost', container='chest', name='XPブースト×2',   detail='30分 ×1.5倍',     icon='🚀', weight=38, value=2),
    # 【FEAT-421 (2026-06-10)】Weekly SR diamond は元 weight 20 → 32 に再配分済み
    # (旧「守護獣 (SR) character weight=12」廃止の振替吸収)。BUG-131 で 32 → 53 に
    # スケールアップ (合計 weight を 120 → 200 に拡張する内訳の一部、R/SR 比率維持)。
    # 【2026-06-14】icon 🌟 → 💎 統一。ユーザー報告「ダイヤなのに星のイラスト」、
    # SR/SSR 全 diamond entry を 💎 に統一 (差別化は rarity バッジ + glow で実施)。
    dict(ticket_type='weekly', rarity='SR',  reward_type='diamond',  container='stone', name='ダイヤ',          detail='× 80',            icon='💎', weight=59, value=80),
    dict(ticket_type='weekly', rarity='SR',  reward_type='xp_boost', container='stone', name='XPブースト×3',   detail='45分 ×1.5倍',     icon='⚡', weight=19, value=3),
    # 【FEAT-317】SR title (weight=8) を除去、diamond / xp_boost に 53:17 で按分 (+6/+2)。SR 合計 78 不変。
    # 【BUG-94 → BUG-98 → BUG-131 (2026-06-17)】Weekly SSR キャラ排出経緯:
    # BUG-94 で Weekly レアキャラ廃止 → BUG-98 で 5.00% (weight=6/120) 復活 →
    # BUG-131 で 0.50% (weight=1/200) に再削減 (ユーザー判断「Weekly のキャラ排出は
    # サプライズ性を強める方向、Monthly 確定 + Shop ダイヤ購入の 2 経路を主とする」)。
    # キャラ入手経路: Monthly 確定 (100%) + Weekly サプライズ (0.5%) + Shop ダイヤ
    # 購入 (6000💎、BUG-131 で 1500 → 6000 に調整) の 3 経路に再収束。
    # 【2026-06-14】icon 🔮 → 💎 統一 (SR と同パターン)。差別化は rarity バッジ + glow。
    dict(ticket_type='weekly', rarity='SSR', reward_type='diamond',  container='stone', name='ダイヤ',          detail='× 200',           icon='💎', weight=18, value=200),
    dict(ticket_type='weekly', rarity='SSR', reward_type='xp_boost', container='stone', name='XPブースト×5',   detail='75分 ×1.5倍',     icon='✨', weight=11, value=5),
    dict(ticket_type='weekly', rarity='SSR', reward_type='weapon',   container='stone', name='竜殺しの剣',      detail='ATK +50',         icon='⚔️', weight=9,  value=0,    weapon_key='dragon_slayer'),
    dict(ticket_type='weekly', rarity='SSR', reward_type='character', container='stone', name='レアキャラ (SSR)', detail='未開放キャラから1体', icon='✨', weight=1,  value=0),
]
# Weekly 合計 weight: R 83 + SR 78 + SSR (diamond 18 + xp_boost 11 + weapon 9 + character 1 = 39) = 200
# キャラ排出確率: 1/200 = 0.50% (BUG-131、ユーザー要望「Weekly SSR 0.5%」と一致)

_MONTHLY_REWARDS = [
    # 【BUG-97 (2026-06-12)】Monthly = キャラ専用ガチャに変更。
    # 旧仕様: SR ダイヤ/XP/称号 (60%) + SSR ダイヤ/XP/称号 (40%) + 天井 10 連目で交換券
    # 新仕様: Monthly チケット 1 枚 = 未所持 SSR キャラ ランダム 1 体 (weight=100、唯一の entry)
    # 排出ロジック: _pick_random_character_id(player, 'SSR') で未所持優先
    # 全 SSR 所持済の場合: 既存 PendingDuplicateReward 経路 (ピース or ステポ交換)
    # 天井廃止: monthly_pity 経路は GachaPullView から削除済 (本 BUG)
    # 旧 SR/SSR 非キャラ報酬は migration 0132 で is_active=False、_ensure_gacha_rewards 経由で
    # 復活しない設計。weight=100 で唯一の active entry。
    dict(ticket_type='monthly', rarity='SSR', reward_type='character',
         container='stone', name='マンスリーキャラ (SSR)',
         detail='未開放キャラから1体', icon='✨',
         weight=100, value=0),
]

# 【BUG-93/97 (2026-06-11/12)】daily/weekly/monthly すべて天井経路廃止のため
# _DAILY_PITY_LIMIT / _WEEKLY_PITY_LIMIT / _MONTHLY_PITY_LIMIT / _PITY_LIMITS は削除。
# 【BUG-62】ticket maxima は GachaBalance に集約済み（shop.py と共通の単一ソース）。
# CLAUDE.md「ゲームバランス定数」契約。プライベート定数は削除。


def _ensure_gacha_rewards():
    """ガチャ報酬マスターを idempotently seed する。

    【FEAT-326】旧実装は「ticket_type が 1 件でも存在すれば全 skip」する
    粗い設計だったため、migration 0090 (FEAT-312 character) / 0095
    (FEAT-326 weapon) で incremental に追加された entry がある状態だと
    残りの seed (Daily/Weekly の N/R/SR/SSR exp/diamond 等) が永久 dead
    code になる問題があった。本関数はモジュールトップの `_DAILY_REWARDS` /
    `_WEEKLY_REWARDS` / `_MONTHLY_REWARDS` を真実値として、各 reward を
    (ticket_type, name, reward_type) の三つ組で `get_or_create` する。

    冪等性: 既存 entry は触らず、欠落分のみ作成。weight 等の差分は
    migration による update_or_create で更新する設計 (本関数は seed のみ)。
    """
    for spec in (*_DAILY_REWARDS, *_WEEKLY_REWARDS, *_MONTHLY_REWARDS):
        # 同 ticket_type 内で「経験値ボーナス (EXP +30)」と「経験値ボーナス (EXP +60)」
        # のように name + reward_type が同じで detail だけ異なる entry があるため、
        # lookup は (ticket_type, name, detail) の三つ組で一意化する。
        # weapon_key を持つ entry は migration 0095 で seed されている可能性が高い。
        lookup = {
            'ticket_type': spec['ticket_type'],
            'name':        spec['name'],
            'detail':      spec['detail'],
        }
        GachaReward.objects.get_or_create(**lookup, defaults=spec)


def _active_reward_pool(ticket_type: str):
    """指定 ticket_type の「実際に抽選対象になる」報酬 pool を返す。

    【FEAT-518 (2026-08-05)】**抽選 (`_pick_reward`) と確率開示 (`GachaOddsView`)
    が参照する唯一の入口**。両者が別々に queryset を組むと、`is_active` の扱いや
    migration による weight 更新のタイミングで「開示した確率と実際の排出が違う」
    状態が発生しうる。これは App Store Guideline 3.1.1 / 景表法の観点で最も重い
    不具合なので、**構造的に乖離しえない形**にしている。

    本関数を迂回して `GachaReward.objects.filter(...)` を直接書かないこと。
    契約テスト `test_gacha_odds.py::test_odds_pool_matches_pick_pool` が
    両者の一致を固定している。
    """
    _ensure_gacha_rewards()
    return list(GachaReward.objects.filter(is_active=True, ticket_type=ticket_type))


def _pick_reward(ticket_type: str, force_sr_plus: bool = False):
    pool = _active_reward_pool(ticket_type)
    if force_sr_plus:
        pool = [r for r in pool if r.rarity in ('SR', 'SSR')]
    if not pool and force_sr_plus:
        # BUG-N: pity 保証（50回目で SR+ 確定など）はユーザーへの契約。
        # SR/SSR が運営都合で全 deactivate されているケースで N/R にフォールバックすると
        # 「天井引いたのにコモンが出た」体感バグになる。
        #
        # BUG-D: ただし他チケット越境の借用（daily 天井で monthly SSR 等）は
        # 「チケット種別契約違反」のため禁止。月次専用キャラクターが daily 経由で
        # 解放されるなどの不整合が発生する。
        # 同 ticket_type 内に is_active=False の SR/SSR があればそれで救済し、
        # それでもなければ ValueError → 呼び出し側で 503 を返してチケットを返却する。
        pool = list(GachaReward.objects.filter(
            ticket_type=ticket_type, rarity__in=['SR', 'SSR'],
        ))
    if not pool:
        raise ValueError("ガチャ報酬が設定されていません。管理者にお問い合わせください。")
    total = sum(r.weight for r in pool)
    # NEW-08: _random.uniform(0, total) は閉区間で total を返し得るため、
    # rand == total の極稀ケースで末尾要素にバイアスがかかる。
    # _random.random() * total に置換し、半開区間 [0, total) にする。
    rand  = _random.random() * total
    for r in pool:
        rand -= r.weight
        if rand < 0:
            return r
    return pool[-1]  # 浮動小数点誤差で rand >= 0 のまま抜けた場合は最後の要素を返す


# 【FEAT-518】確率表示の注記。キャラ報酬は entry 単位の weight では表現しきれない
# (どのキャラが出るかは未所持プールから均等) ため、文言で補う。
_ODDS_NOTES = [
    'キャラクター報酬は、まだ解放していないキャラクターの中から均等に抽選されます。',
    '武器報酬は、対象レアリティの武器の中から抽選されます。',
    '確率は小数第 2 位で四捨五入して表示しています。',
]


def _odds_percent(weight: int, total: int) -> float:
    """weight を百分率に正規化する。

    【Pre-mortem #2】ticket_type ごとに weight 合計が違う
    (Daily 100 / Weekly 200 / Monthly 100) ため、**weight をそのまま % として
    扱ってはならない**。Weekly の weight=45 は 45% ではなく 22.5%。

    小数第 2 位まで丸める (Weekly character の 1/200 = 0.50% を正しく表すため)。
    """
    if total <= 0:
        return 0.0
    return round(weight / total * 100, 2)


def _build_odds_payload(ticket_type: str, pool, label: str, serializer_cls, request):
    """1 つの ticket_type 分の開示ペイロードを組み立てる。

    【Pre-mortem #3】同名報酬 (Daily の「経験値ボーナス」は EXP +30/+60/+120 の
    3 entry) を name で集約すると誤表示になるため、**entry 単位でそのまま列挙**し
    `detail` を必ず併記する。集約するのは rarity 単位のサマリのみ。
    """
    total = sum(r.weight for r in pool)

    rewards = serializer_cls(
        pool, many=True, context={'request': request, 'total_weight': total},
    ).data

    # rarity サマリ (N/R/SR/SSR の順序を固定。pool に無い rarity は出さない)
    rarity_weights = {}
    for r in pool:
        rarity_weights[r.rarity] = rarity_weights.get(r.rarity, 0) + r.weight
    rarity_summary = [
        {'rarity': rarity, 'probability': _odds_percent(rarity_weights[rarity], total)}
        for rarity in ('N', 'R', 'SR', 'SSR')
        if rarity in rarity_weights
    ]

    return {
        'ticket_type':    ticket_type,
        'label':          label,
        'total_weight':   total,
        'rarity_summary': rarity_summary,
        'rewards':        rewards,
    }


def _apply_reward(player: PlayerProfile, reward: GachaReward):
    """報酬を適用する。呼び出し元の transaction.atomic() ブロック内で実行すること。
    character / weapon タイプは重複チェック後に呼び出し元で処理するためここでは何もしない。
    """
    if reward.reward_type == 'character':
        # character 報酬は GachaPullView 側で OwnedCharacter を作成する
        return
    if reward.reward_type == 'weapon':
        # 【FEAT-326】weapon 報酬は GachaPullView 側で PlayerWeapon を作成する
        # (character 経路と同パターン、重複時は PendingDuplicateReward に流す)
        return

    if reward.reward_type == 'exp' and reward.value > 0:
        player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_battle = player.battle
        locked_battle.current_exp += reward.value
        while locked_battle.current_exp >= locked_battle.max_exp:
            locked_battle.current_exp -= locked_battle.max_exp
            locked_battle.level += 1
            # 【FEAT-319】level_to_max_exp で単一真実値化、直書き禁止。
            locked_battle.max_exp = GameBalance.level_to_max_exp(locked_battle.level)
            locked_battle.allocatable_points += GameBalance.ALLOCATABLE_POINTS_PER_LEVEL
        locked_battle.save(update_fields=['current_exp', 'level', 'max_exp', 'allocatable_points'])

    elif reward.reward_type == 'diamond' and reward.value > 0:
        player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_eco = player.economy
        locked_eco.diamonds       += reward.value
        locked_eco.diamonds_total += reward.value
        locked_eco.save(update_fields=['diamonds', 'diamonds_total'])

    elif reward.reward_type == 'character_ticket':
        # 【FEAT-427 (2026-06-11)】マンスリー天井: キャラ交換券を付与。
        # ユーザーが任意のタイミングで好きな SSR キャラと交換できる (期限なし)。
        player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
        locked_eco = player.economy
        locked_eco.character_exchange_tickets += 1
        locked_eco.save(update_fields=['character_exchange_tickets'])

    elif reward.reward_type == 'xp_boost':
        # get_or_create でレコードを確保してからロック＋F()でアトミック更新
        item, created = PlayerItem.objects.get_or_create(
            player=player, item_id='xp_boost_1.5x',
            defaults={'quantity': 0},
        )
        if not created:
            PlayerItem.objects.filter(pk=item.pk).update(quantity=F('quantity') + reward.value)
        else:
            item.quantity = reward.value
            item.save(update_fields=['quantity'])


# 【BUG-108 (2026-06-14)】SSR 判定基準を price >= 3000 → is_starter=False に変更。
# 旧設計: Character.rarity フィールドが schema に無いため price を rarity proxy とし
#   - SR  : 1 <= price <= 2999
#   - SSR : 3000 <= price <= 99999
# 問題: BUG-106/107 で全 non-starter 価格を 1500 に統一した結果、price 基準の rarity
#   proxy が機能しなくなる (SSR 検出 0 件、SR 検出 0 件 → 全候補にフォールバック
#   = starter を含めて Monthly チケットが sol/aria を返す可能性が出る)。
# 新設計: 「全 non-starter キャラ = SSR」「starter = 専用枠で gacha 対象外」と統一。
#   `is_starter=False` を SSR 判定の唯一の真実値とする。Weekly 5% SR キャラ枠
#   (BUG-98 で復活) と Monthly 100% SSR キャラ枠は同じ pool から抽選する仕様。


def _pick_random_character_id(player: PlayerProfile, rarity: str) -> int | None:
    """【BUG-108 (2026-06-14)】Character マスターから non-starter + 未所持優先で
    ランダム選択。

    優先順位:
        1. non-starter + 公開 + プレイヤー未所持 → 最優先 (新鮮さ重視)
        2. non-starter + 公開 + プレイヤー所持済 → 重複扱いで pending_reward 経路へ
        3. non-starter 候補が 0 件 → 全 公開 Character から非所持優先で fallback
        4. 公開 Character 0 件 → None 返却 (呼び出し側で diamond 救済)

    `rarity` 引数は backward compat のため受け取るが、本ロジックでは使わない
    (全 non-starter キャラを SSR-tier として扱う v1.0 設計、BUG-108)。

    【2026-06-27】is_published=True フィルタを追加 (段階公開機能)。
    非公開キャラはガチャから完全除外。starter は元から候補外なので影響なし。
    """
    # 【2026-06-27】is_published=True のみガチャ対象 (段階公開機能)。
    # 運用ミスで全キャラ非公開化された場合は all_chars=[] で None 返却 → diamond 救済経路。
    all_chars = list(
        Character.objects
        .filter(is_published=True)
        .values_list('id', 'is_starter')
    )
    if not all_chars:
        # Pre-mortem #1: 公開キャラ 0 件 → None 返却で呼び出し側 diamond 救済
        return None

    owned_ids = set(
        OwnedCharacter.objects
        .filter(player=player)
        .values_list('character_id', flat=True)
    )

    # 【BUG-108】non-starter のみ候補に。starter (sol/aria) は gacha 対象外。
    candidates = [cid for (cid, is_starter) in all_chars if not is_starter]
    if not candidates:
        # 全 starter (運用ミス) → 全候補にフォールバック (Pre-mortem #1 緩和)
        candidates = [cid for (cid, _is_starter) in all_chars]

    not_owned = [cid for cid in candidates if cid not in owned_ids]
    if not_owned:
        return _random.choice(not_owned)
    # 全所持済 → 任意の 1 体を返し、呼び出し側で重複判定（既存 PendingDuplicateReward）
    return _random.choice(candidates)


class GachaOddsView(PlayerMixin, APIView):
    """【FEAT-518 (2026-08-05)】ガチャ排出確率の開示。

    GET /api/gacha/odds/

    App Store Review Guideline 3.1.1 は、有料で引ける randomized item の
    提供割合を **購入前に** 開示することを求める。Sabiowl は
    「実通貨 → ダイヤ → ウィークリーチケット → 重み付き抽選」の経路が
    成立しているため本 endpoint が必要。

    確率は `_active_reward_pool()` (= 抽選が使う pool) から算出するため、
    表示値と実際の排出は構造的に一致する。

    Response:
        200 {"ticket_types": [...], "notes": [...]}
        503 {"error": {"code": "gacha_odds_unavailable", ...}}
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    # 【Pre-mortem #6】購入前に到達できる必要があるため、チケット未所持でも 200 を返す。
    # プレイヤー固有情報は一切含めない (純粋な master data の開示)。
    _TICKET_LABELS = {
        'daily':   'デイリー',
        'weekly':  'ウィークリー',
        'monthly': 'マンスリー',
    }

    def get(self, request):
        from ..serializers import GachaOddsRewardSerializer

        try:
            ticket_types = []
            for ticket_type in ('daily', 'weekly', 'monthly'):
                pool = _active_reward_pool(ticket_type)
                if not pool:
                    continue
                ticket_types.append(
                    _build_odds_payload(
                        ticket_type,
                        pool,
                        self._TICKET_LABELS.get(ticket_type, ticket_type),
                        GachaOddsRewardSerializer,
                        request,
                    )
                )
        except Exception as exc:
            _logger.error('GachaOddsView: %s', exc, exc_info=True)
            return error_response(
                code='gacha_odds_unavailable',
                message='排出確率の取得に失敗しました。少し時間をおいてお試しください 🪶',
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        return Response({
            'ticket_types': ticket_types,
            'notes': _ODDS_NOTES,
        })


class GachaStatusView(PlayerMixin, APIView):
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        from datetime import timedelta

        player = self.get_player(request)
        today  = timezone.localdate()  # BUG-A2: JST 基準で日付を扱う

        try:
            _ensure_gacha_rewards()
            status_obj, _ = PlayerGachaStatus.objects.get_or_create(player=player)
        except Exception as exc:
            _logger.error('GachaStatusView: %s', exc, exc_info=True)
            return error_response(
                code='gacha_status_unavailable',
                message='ガチャ情報の取得に失敗しました。少し時間をおいてお試しください 🪶',
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        this_monday = today - timedelta(days=today.weekday())
        last_monday = this_monday - timedelta(days=7)
        last_sunday = this_monday - timedelta(days=1)
        first_of_this_month = date(today.year, today.month, 1)

        # チケット付与はアトミックに行う（同時リクエストによる二重付与を防止）
        # 【20260729 user feedback 対応 (案 C)】daily / weekly が「本日の grant で
        # 初めて MAX に到達した」瞬間を検出する just_reached_max フラグを response
        # に含める。Mobile 側で満タン到達 SnackBar (Sabi 口調) の発火 trigger。
        daily_just_reached_max  = False
        weekly_just_reached_max = False
        with transaction.atomic():
            status_obj = PlayerGachaStatus.objects.select_for_update().get(pk=status_obj.pk)
            save_fields = []

            if status_obj.daily_last_granted != today:
                has_completion = HabitLog.objects.filter(
                    habit__player=player, date=today, count__gt=0,
                ).exists()
                if has_completion:
                    prev_daily = status_obj.daily_tickets
                    status_obj.daily_tickets      = min(prev_daily + 1, GachaBalance.DAILY_TICKET_MAX)
                    status_obj.daily_last_granted = today
                    save_fields += ['daily_tickets', 'daily_last_granted']
                    # 案 C: 本日の grant で初めて MAX に到達した瞬間のみ True。
                    # 既に MAX の場合 (prev == MAX) や、未到達の場合 (< MAX-1 → < MAX) は False。
                    if prev_daily == GachaBalance.DAILY_TICKET_MAX - 1 \
                            and status_obj.daily_tickets == GachaBalance.DAILY_TICKET_MAX:
                        daily_just_reached_max = True

            if status_obj.weekly_last_granted_week != this_monday:
                last_week_days = (
                    HabitLog.objects
                    .filter(habit__player=player, date__gte=last_monday, date__lte=last_sunday, count__gt=0)
                    .values('date').distinct().count()
                )
                if last_week_days >= 5:
                    prev_weekly = status_obj.weekly_tickets
                    status_obj.weekly_tickets           = min(prev_weekly + 1, GachaBalance.WEEKLY_TICKET_MAX)
                    status_obj.weekly_last_granted_week = this_monday
                    save_fields += ['weekly_tickets', 'weekly_last_granted_week']
                    # 案 C: weekly も同型の just_reached_max 判定。
                    if prev_weekly == GachaBalance.WEEKLY_TICKET_MAX - 1 \
                            and status_obj.weekly_tickets == GachaBalance.WEEKLY_TICKET_MAX:
                        weekly_just_reached_max = True

            # 【FEAT-433 (2026-06-13)】月初 monthly チケット配布は廃止。
            # 当月 21 日達成 → HabitCountView 内で即時配布に変更
            # (habit_count_service.grant_monthly_ticket_if_21_days_done)。

            if save_fields:
                status_obj.save(update_fields=save_fields)

        week_days_done = (
            HabitLog.objects
            .filter(habit__player=player, date__gte=this_monday, date__lte=today, count__gt=0)
            .values('date').distinct().count()
        )
        days_elapsed_this_week = today.weekday() + 1
        weekly_pct = round(week_days_done / days_elapsed_this_week * 100) if days_elapsed_this_week else 0

        month_days_done = (
            HabitLog.objects
            .filter(habit__player=player, date__gte=first_of_this_month, date__lte=today, count__gt=0)
            .values('date').distinct().count()
        )

        histories = (
            GachaHistory.objects
            .filter(player=player)
            # 【BUG-119 (2026-06-14)】character FK も select_related で N+1 防御。
            .select_related('reward', 'character')
            .order_by('-pulled_at')[:10]
        )

        # 【BUG-102/108 (2026-06-14)】全 SSR キャラ開放済判定。
        # Monthly = SSR 確定ガチャは未所持 SSR キャラがあって初めて価値があるため、
        # 全所持時は Mobile 側で「引く」ボタンを非活性化する (dead currency の
        # exchange_pieces 救済を避ける UX、v1.0 シンプル路線)。
        # 【BUG-108】判定基準を price >= 3000 → is_starter=False に変更
        # (price 1500 統一で price 基準が機能しなくなったため、starter かどうかで判定)。
        # 旧バグ: noir (price=1500) が SSR 検出から漏れ、新 5 キャラ (price=3000) のみで
        # 開放済み判定されていた → noir 未所持なのに all_ssr_unlocked=True 誤判定。
        ssr_char_ids = set(
            Character.objects
            .filter(is_starter=False)
            .values_list('id', flat=True)
        )
        owned_ssr_ids = set(
            OwnedCharacter.objects
            .filter(player=player, character_id__in=ssr_char_ids)
            .values_list('character_id', flat=True)
        )
        # 全 SSR 候補 0 件 (運用ミス) のときは False を返し非活性化を回避 (チケット死蔵リスク排除)。
        all_ssr_unlocked = bool(ssr_char_ids) and ssr_char_ids == owned_ssr_ids

        # 【新規 (2026-06-25)】当月の SSR 確定チケット (FEAT-433、21 日達成配布)
        # を既に受け取っているか。Mobile の SSR 確定ガチャカードに「配布済 / あと N 日」
        # のステータス文言を出すための真実値。判定は monthly_last_granted_month が
        # 当月 1 日付と一致するか (habit_count_service.grant_monthly_ticket_if_21_days_done
        # で配布時に first_of_month を書き込む契約)。
        monthly_ticket_granted_this_month = (
            status_obj.monthly_last_granted_month == first_of_this_month
        )

        # 【新規 (2026-06-25)】当週のウィークリーチケットを既に受け取っているか。
        # ウィークリーチケットは「前週 5 日達成」を条件として「今週月曜以降に初めて
        # GachaStatusView を叩いた時点」で配布される設計のため、配布済か否かは
        # weekly_last_granted_week が this_monday (当週月曜) と一致するかで判定する
        # (上記 try/atomic ブロックで設定済)。
        weekly_ticket_granted_this_week = (
            status_obj.weekly_last_granted_week == this_monday
        )

        # 【BUG-146 Phase 2】locale の解決は view ごとに 1 行だけ。
        # Pre-mortem #4: 各所にコピペすると 1 箇所だけ抜けても無言で ja に落ちる
        # (FEAT-516 で実際に踏んだ罠)。ゲスト経路でも `request.locale` は
        # I18nMiddleware が SimpleLazyObject で必ず載せるので getattr は保険。
        locale = getattr(request, 'locale', 'ja')

        return Response({
            'daily_tickets':   status_obj.daily_tickets,
            'daily_pity':      status_obj.daily_pity,
            'weekly_tickets':  status_obj.weekly_tickets,
            'weekly_pity':     status_obj.weekly_pity,
            'monthly_tickets': status_obj.monthly_tickets,
            # 【BUG-97 (2026-06-12)】monthly_pity は天井経路廃止により未使用。
            # PlayerGachaStatus.monthly_pity field は schema 維持 (CLAUDE.md
            # 「破壊的データマイグレーション禁止」原則準拠) だが API レスポンスからは除外。
            'weekly_pct':          weekly_pct,
            'weekly_days_done':    week_days_done,
            'monthly_days_done':   month_days_done,
            # 【新規 (2026-06-25)】FEAT-433 当月配布済フラグ。Mobile が「配布済 ✓」
            # 表示と「あと N 日」表示を切り替える判定に使う。
            'monthly_ticket_granted_this_month': monthly_ticket_granted_this_month,
            # 【新規 (2026-06-25)】当週のウィークリーチケット配布済フラグ。同様に
            # Mobile が「✓ 取得済み」表示と「N/5 進捗」表示を切り替える判定に使う。
            'weekly_ticket_granted_this_week': weekly_ticket_granted_this_week,
            # 【20260729 user feedback (案 C) 対応】本日の grant で初めて daily / weekly
            # チケットが MAX に到達した瞬間のみ True。Mobile 側で「満タン到達おめでとう」
            # SnackBar (Sabi 口調) の発火 trigger に使う。既に MAX の場合や未到達の場合は
            # False (SnackBar 過剰発火を防止)。
            'daily_ticket_just_reached_max':   daily_just_reached_max,
            'weekly_ticket_just_reached_max':  weekly_just_reached_max,
            # 【BUG-102 (2026-06-14)】Monthly = SSR 確定ガチャの引く可否判定。
            'all_ssr_unlocked':    all_ssr_unlocked,
            'history': [
                {
                    'rarity':      h.reward.rarity,
                    'icon':        h.reward.icon,
                    # 【BUG-119 (2026-06-14)】character 排出時は具体的キャラ名を表示
                    # (例: 「ルーン (SSR)」)、それ以外は reward.name (旧履歴も含む)。
                    # 【BUG-146 Phase 2】どちらの分岐も master data なので _en を読む。
                    'name': (
                        f'{get_i18n_field(h.character, "name", locale)} ({h.reward.rarity})'
                        if h.character is not None
                        else get_i18n_field(h.reward, 'name', locale)
                    ),
                    'detail':      get_i18n_field(h.reward, 'detail', locale),
                    'ticket_type': h.ticket_type,
                    'pulled_at':   h.pulled_at.isoformat(),
                }
                for h in histories
            ],
        })


class GachaPullView(PlayerMixin, APIView):
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    _TICKET_NAMES = {'daily': 'デイリー', 'weekly': 'ウィークリー', 'monthly': 'マンスリー'}

    def post(self, request):
        player      = self.get_player(request)
        ticket_type = request.data.get('ticket_type', 'daily')
        # 【BUG-146 Phase 2】locale の解決は view ごとに 1 行だけ (Pre-mortem #4)。
        # 各所にコピペすると 1 箇所だけ抜けても無言で ja に落ちる。
        locale = getattr(request, 'locale', 'ja')

        if ticket_type not in ('daily', 'weekly', 'monthly'):
            return error_response(
                code='gacha_pull_invalid_ticket_type',
                message='チケット種別が正しくありません 🪶',
                status=400,
            )

        _ensure_gacha_rewards()
        status_obj, _ = PlayerGachaStatus.objects.get_or_create(player=player)

        ticket_field = f'{ticket_type}_tickets'
        pity_field   = f'{ticket_type}_pity'

        with transaction.atomic():
            status_obj = PlayerGachaStatus.objects.select_for_update().get(pk=status_obj.pk)

            if getattr(status_obj, ticket_field) < 1:
                name = self._TICKET_NAMES[ticket_type]
                # 【FEAT-515 Phase 2】`message` の {name} は日本語のチケット名なので、
                # Flutter 側で ARB を引くには **machine-readable な種別**が要る。
                # prose を送るのではなく code + field を送る、が本 FEAT の方針。
                return error_response(
                    code='gacha_pull_not_enough_tickets',
                    message=f'{name}チケットが足りないようですね 🪶',
                    fields={'ticket_type': ticket_type},
                    status=400,
                )

            # 【BUG-93 (2026-06-11) + BUG-97 (2026-06-12)】daily/weekly/monthly すべて
            # 天井保証経路を廃止、純粋確率制に統一。monthly はキャラ専用ガチャ
            # (_MONTHLY_REWARDS が character entry のみ) のため、天井による
            # キャラ交換券配布 (FEAT-427) は不要。
            force_sr_plus = False
            try:
                reward = _pick_reward(ticket_type, force_sr_plus)
            except ValueError as e:
                return error_response(
                    code='gacha_pull_rewards_not_configured',
                    message=str(e),
                    status=status.HTTP_503_SERVICE_UNAVAILABLE,
                )

            setattr(status_obj, ticket_field, getattr(status_obj, ticket_field) - 1)
            if ticket_type == 'monthly':
                # 【BUG-97 (2026-06-12)】monthly_pity の increment / reset は廃止
                # (天井経路自体が廃止されたため、カウンターを更新する意味がない)。
                status_obj.save(update_fields=[ticket_field])
            else:
                if reward.rarity in ('SR', 'SSR'):
                    setattr(status_obj, pity_field, 0)
                else:
                    setattr(status_obj, pity_field, getattr(status_obj, pity_field) + 1)
                status_obj.save(update_fields=[ticket_field, pity_field])

            # ── 重複チェック + Character 経路（Weekly + Monthly 両対応） ──────
            # 【FEAT-312】旧実装は monthly 限定だったが、Weekly にも character 報酬を
            # 追加したため両 ticket_type で同経路を動かす（指示書 §Phase 1-3）。
            # value=0 は「ランダム選択」シグナル、`_pick_random_character_id` で rarity
            # ベースに動的解決する設計（Character.rarity フィールドが schema に無いため
            # price proxy 採択、Pre-mortem #4 対策で reward_type 内のみで value 解釈）。
            is_duplicate    = False
            pending_reward_id = None
            # 【2026-06-14】排出キャラ情報を Mobile response に含める用 (キャラ画像 +
            # 「キャラ名 (SSR)」表示)。reward_type='character' 排出時のみ非 None。
            granted_character_info = None
            # 【BUG-119 (2026-06-14)】GachaHistory.character に保存する Character.id。
            # character 排出時のみ非 None、reward.value=0 (ランダム) も含めて記録する。
            granted_character_id = None

            if reward.reward_type == 'character':
                # value > 0: Character.id 直指定（旧 Monthly 経路の後方互換）
                # value == 0: ランダム選択シグナル（本 FEAT で新規追加）
                if reward.value > 0:
                    char_id = reward.value
                else:
                    char_id = _pick_random_character_id(player, reward.rarity)

                if char_id is None:
                    # Pre-mortem #1 緩和: Character マスター 0 件時 → diamond 50 で救済。
                    # `pending_reward` 経路には流さず、即時報酬として記録（チケットは
                    # 消費されたため、ユーザーに何かしら還元する義務がある）。
                    player_locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
                    locked_eco = player_locked.economy
                    locked_eco.diamonds       += 50
                    locked_eco.diamonds_total += 50
                    locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
                else:
                    already_owned = OwnedCharacter.objects.filter(
                        player=player, character_id=char_id,
                    ).exists()
                    if already_owned:
                        pending = PendingDuplicateReward.objects.create(
                            player=player,
                            reward=reward,
                            expires_at=timezone.now() + timedelta(days=30),
                        )
                        is_duplicate      = True
                        pending_reward_id = pending.id
                    else:
                        # 新規キャラクターを付与
                        OwnedCharacter.objects.get_or_create(
                            player=player, character_id=char_id,
                        )
                    # 【2026-06-14】既所持/新規ともに排出キャラ情報を response に
                    # 含める (PendingDuplicateReward 経路でも "誰のピース?" を
                    # ユーザーに示すため、両方で取得)。Character.DoesNotExist は
                    # _pick_random_character_id の存在保証で起きない想定だが、
                    # try/except で防御 (Pre-mortem 軽量化)。
                    try:
                        ch = Character.objects.only(
                            'id', 'name', 'image_path', 'role',
                        ).get(pk=char_id)
                        granted_character_info = {
                            'id':         ch.id,
                            # 【BUG-146 Phase 2】排出キャラ名 / 役職も master data。
                            'name':       get_i18n_field(ch, 'name', locale),
                            'image_path': ch.image_path,
                            'role':       get_i18n_field(ch, 'role', locale),
                        }
                        # 【BUG-119 (2026-06-14)】履歴に保存する Character.id を確定。
                        granted_character_id = ch.id
                    except Character.DoesNotExist:
                        pass

            elif reward.reward_type == 'weapon':
                # 【FEAT-326】 weapon 排出経路 (character 経路と同パターン)。
                # weapon_key で WeaponMaster を解決 → 未所持なら PlayerWeapon 作成、
                # 既所持なら PendingDuplicateReward (ダイヤ救済) に流す (Pre-mortem #5)。
                weapon_key = reward.weapon_key
                try:
                    weapon = WeaponMaster.objects.get(key=weapon_key) if weapon_key else None
                except WeaponMaster.DoesNotExist:
                    weapon = None

                if weapon is None:
                    # WeaponMaster 0 件 / weapon_key 空 (運用ミス) → diamond 50 救済
                    # (character 経路と同パターン、Pre-mortem #1 緩和)
                    player_locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
                    locked_eco = player_locked.economy
                    locked_eco.diamonds       += 50
                    locked_eco.diamonds_total += 50
                    locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
                else:
                    already_owned = PlayerWeapon.objects.filter(
                        player=player, weapon=weapon,
                    ).exists()
                    if already_owned:
                        pending = PendingDuplicateReward.objects.create(
                            player=player,
                            reward=reward,
                            expires_at=timezone.now() + timedelta(days=30),
                        )
                        is_duplicate      = True
                        pending_reward_id = pending.id
                    else:
                        # 新規武器を付与 (is_equipped=False、装備変更は EquipWeaponView)
                        PlayerWeapon.objects.create(
                            player=player, weapon=weapon, is_equipped=False,
                        )

            if not is_duplicate:
                _apply_reward(player, reward)

            # 【BUG-119 (2026-06-14)】character 排出時は character FK も保存し、
            # GachaStatusView.history で具体的キャラ名 (例: 「ルーン (SSR)」) を表示可能に。
            history = GachaHistory.objects.create(
                player=player, reward=reward, ticket_type=ticket_type,
                character_id=granted_character_id,
            )

            # 【FEAT-374】直近 pull を redo 用に記録。
            # 新しい pull が発生するたびにリセットし、redo_used=False にする。
            # select_for_update はこの時点で status_obj に対して既に有効 (L383)。
            status_obj.last_pull_id   = history.pk
            status_obj.last_pull_at   = timezone.now()
            status_obj.last_pull_pool = ticket_type
            status_obj.redo_used      = False
            status_obj.save(update_fields=['last_pull_id', 'last_pull_at', 'last_pull_pool', 'redo_used'])

        response_data = {
            'reward': {
                'id':          reward.id,
                'rarity':      reward.rarity,
                'reward_type': reward.reward_type,
                'container':   reward.container,
                'name':        get_i18n_field(reward, 'name', locale),
                'detail':      get_i18n_field(reward, 'detail', locale),
                'icon':        reward.icon,
                # 【2026-06-14】排出キャラ情報 (reward_type='character' 排出時のみ)。
                # Mobile UI で「キャラ画像 + キャラ名 (SSR)」表示 (gacha_summon_page)。
                # None なら従来通り reward.icon + reward.name 表示 (非キャラ報酬)。
                'character':   granted_character_info,
            },
            'is_duplicate':    is_duplicate,
            'pending_reward_id': pending_reward_id,
            # 【BUG-97 (2026-06-12)】Monthly 天井経路廃止により
            # character_exchange_ticket_awarded は削除 (常に未送出だった force_ssr を撤去)。
            f'{ticket_type}_tickets_remaining': getattr(status_obj, ticket_field),
            f'{ticket_type}_pity':              getattr(status_obj, pity_field),
            # 【FEAT-374】pull 直後は redo 可能 (redo_used=False、24h 以内)。
            'redo_available': True,
            'redo_diamond_cost': _REDO_DIAMOND_COST,
        }
        return Response(response_data)


def _serialize_pending(p: PendingDuplicateReward, locale: str = 'ja') -> dict:
    """【BUG-146 Phase 2】`locale` は呼び出し側が 1 度だけ解決して渡す。

    default を `'ja'` にしているのは既存呼び出しとの互換のためで、
    **view からは必ず明示的に渡すこと** (省略すると無言で日本語に落ちる)。
    """
    return {
        'id':            p.id,
        'reward': {
            'id':          p.reward.id,
            'rarity':      p.reward.rarity,
            'reward_type': p.reward.reward_type,
            'container':   p.reward.container,
            'name':        get_i18n_field(p.reward, 'name', locale),
            'detail':      get_i18n_field(p.reward, 'detail', locale),
            'icon':        p.reward.icon,
        },
        'status':        p.status,
        'exchange_type': p.exchange_type,
        'expires_at':    p.expires_at.isoformat(),
        'created_at':    p.created_at.isoformat(),
    }


class PendingRewardListView(PlayerMixin, APIView):
    """GET /api/gacha/pending/ — 交換待ち重複報酬一覧"""
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def get(self, request):
        player  = self.get_player(request)
        now     = timezone.now()
        # BUG-F: 期限切れの pending を expired に切り替えるバッチが存在しないため、
        # リスト取得時に当該ユーザー分だけ軽量に掃除する。
        # （重い update ではなく `status='pending' & expires_at__lte=now` の局所更新）
        PendingDuplicateReward.objects.filter(
            player=player, status='pending', expires_at__lte=now,
        ).update(status='expired')
        pendings = (
            PendingDuplicateReward.objects
            .filter(player=player, status='pending', expires_at__gt=now)
            .select_related('reward')
        )
        # 【BUG-146 Phase 2】locale の解決は view ごとに 1 行だけ (Pre-mortem #4)。
        locale = getattr(request, 'locale', 'ja')
        return Response([_serialize_pending(p, locale) for p in pendings])


class DuplicateExchangeView(PlayerMixin, APIView):
    """POST /api/gacha/exchange/<pk>/ — 重複報酬を交換する"""
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    _PIECES_AMOUNT      = 100
    _STAT_POINTS_AMOUNT = 5

    def post(self, request, pk):
        player        = self.get_player(request)
        exchange_type = request.data.get('exchange_type', '')

        if exchange_type not in ('pieces', 'stat_points'):
            return error_response(
                code='gacha_exchange_invalid_type',
                message='交換種別を選び直してください 🪶',
                fields={'exchange_type': 'pieces / stat_points のいずれかを指定してください'},
                status=400,
            )

        with transaction.atomic():
            try:
                pending = PendingDuplicateReward.objects.select_for_update().get(
                    pk=pk, player=player, status='pending',
                )
            except PendingDuplicateReward.DoesNotExist:
                return error_response(
                    code='gacha_exchange_pending_not_found',
                    message='交換対象が見つかりませんでした 🪶',
                    status=404,
                )

            if pending.expires_at < timezone.now():
                pending.status = 'expired'
                pending.save(update_fields=['status'])
                return error_response(
                    code='gacha_exchange_expired',
                    message='有効期限が切れています 🪶',
                    status=410,
                )

            player_locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            locked_battle = player_locked.battle  # 【FEAT-478 Phase 2b】

            if exchange_type == 'pieces':
                player_locked.exchange_pieces += self._PIECES_AMOUNT
                player_locked.save(update_fields=['exchange_pieces'])
            else:
                locked_battle.allocatable_points += self._STAT_POINTS_AMOUNT
                locked_battle.save(update_fields=['allocatable_points'])

            pending.status        = 'exchanged'
            pending.exchange_type = exchange_type
            pending.save(update_fields=['status', 'exchange_type'])

        # 【FEAT-497 (2026-08-04)】獲得側も計測する。
        # Shop の `exchange_pieces_spent` と対にすることで
        # 「貯まる一方で使われていない」= dead currency への逆戻りを観測できる。
        if exchange_type == 'pieces':
            capture_for_player(player_locked, 'exchange_pieces_earned', {
                'amount':  self._PIECES_AMOUNT,
                'balance': player_locked.exchange_pieces,
            })

        return Response({
            'exchange_type':      exchange_type,
            'exchange_pieces':    player_locked.exchange_pieces,
            'allocatable_points': locked_battle.allocatable_points,
        })


class GachaRedoView(PlayerMixin, APIView):
    """POST /api/gacha/redo/ — 直近ガチャをもう 1 度引き直す（💎 50 消費）。

    【FEAT-374 (2026-05-29)】ダイヤ使い道拡張パッケージ 1 件目。

    設計:
    - rollback (前結果取消) ではなく **追加 1 回引き直し** (前結果保持) = race リスク排除
    - 直近 1 回限定: 別ガチャを引いたら redo_used=False にリセット
    - 24h ウィンドウ: `last_pull_at` から 24h 以内のみ有効
    - 💎 50 消費: 失敗時はダイヤ返却なし (サーバー検証で失敗時は消費前に return)

    Pre-mortem #3 対応: ダイヤ消費はサーバー側検証成功後のみ (Optimistic UI 禁止)。
    """
    authentication_classes = [ExpiringTokenAuthentication, GuestTokenAuthentication]
    permission_classes     = [IsAuthenticatedOrGuest]

    def post(self, request):
        player = self.get_player(request)
        # 【BUG-146 Phase 2】locale の解決は view ごとに 1 行だけ (Pre-mortem #4)。
        # 各所にコピペすると 1 箇所だけ抜けても無言で ja に落ちる。
        locale = getattr(request, 'locale', 'ja')

        with transaction.atomic():
            player_locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            gacha_status  = PlayerGachaStatus.objects.select_for_update().get(
                player=player_locked,
            )

            # 検証 1: redo 対象のガチャ履歴があるか
            if gacha_status.last_pull_id is None:
                return error_response(
                    code='gacha_redo_no_history',
                    message='直近のガチャ履歴がありません 🪶',
                    status=400,
                )

            # 検証 2: 既に redo 済みか
            if gacha_status.redo_used:
                return error_response(
                    code='gacha_redo_already_used',
                    message='すでに引き直し済みです。新しいガチャを引いてから再度お試しください 🪶',
                    status=400,
                )

            # 検証 3: 24h 以内か
            if gacha_status.last_pull_at is not None:
                elapsed = timezone.now() - gacha_status.last_pull_at
                if elapsed > timedelta(hours=_REDO_WINDOW_HOURS):
                    return error_response(
                        code='gacha_redo_expired',
                        message=f'{_REDO_WINDOW_HOURS} 時間を過ぎたため引き直しできません 🪶',
                        status=400,
                    )

            # 検証 4: ダイヤが足りるか
            locked_eco = player_locked.economy  # 【FEAT-478 Phase 2b】
            if locked_eco.diamonds < _REDO_DIAMOND_COST:
                return error_response(
                    code='gacha_redo_insufficient_diamonds',
                    message=f'ダイヤが足りません (必要: {_REDO_DIAMOND_COST}、所持: {locked_eco.diamonds}) 🪶',
                    fields={
                        'required': str(_REDO_DIAMOND_COST),
                        'owned':    str(locked_eco.diamonds),
                    },
                    status=400,
                )

            # ダイヤ消費 + redo フラグ立て
            locked_eco.diamonds -= _REDO_DIAMOND_COST
            locked_eco.save(update_fields=['diamonds'])
            gacha_status.redo_used = True
            gacha_status.save(update_fields=['redo_used'])
            # 【FEAT-408】ダイヤ消費計測 (best-effort)
            record_diamond_spent(player_locked, sink='gacha_redo', amount=_REDO_DIAMOND_COST)

            # 既存 pull ロジックを再利用: 同じ pool で追加 1 回引き直し
            pool = gacha_status.last_pull_pool or 'daily'
            _ensure_gacha_rewards()
            try:
                reward = _pick_reward(pool, force_sr_plus=False)
            except ValueError as e:
                return error_response(
                    code='gacha_redo_rewards_not_configured',
                    message=str(e),
                    status=503,
                )

            # character / weapon タイプの重複チェック
            is_duplicate    = False
            pending_reward_id = None
            # 【2026-06-14】redo 経路でも排出キャラ情報を response に含める。
            granted_character_info = None
            # 【BUG-119 (2026-06-14)】redo 経路でも GachaHistory.character に保存。
            granted_character_id = None

            if reward.reward_type == 'character':
                char_id = (
                    _pick_random_character_id(player_locked, reward.rarity)
                    if reward.value == 0 else reward.value
                )
                if char_id is None:
                    locked_eco.diamonds       += 50
                    locked_eco.diamonds_total += 50
                    locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
                else:
                    already_owned = OwnedCharacter.objects.filter(
                        player=player_locked, character_id=char_id,
                    ).exists()
                    if already_owned:
                        pending = PendingDuplicateReward.objects.create(
                            player=player_locked,
                            reward=reward,
                            expires_at=timezone.now() + timedelta(days=30),
                        )
                        is_duplicate      = True
                        pending_reward_id = pending.id
                    else:
                        OwnedCharacter.objects.get_or_create(
                            player=player_locked, character_id=char_id,
                        )
                    try:
                        ch = Character.objects.only(
                            'id', 'name', 'image_path', 'role',
                        ).get(pk=char_id)
                        granted_character_info = {
                            'id':         ch.id,
                            # 【BUG-146 Phase 2】排出キャラ名 / 役職も master data。
                            'name':       get_i18n_field(ch, 'name', locale),
                            'image_path': ch.image_path,
                            'role':       get_i18n_field(ch, 'role', locale),
                        }
                        # 【BUG-119 (2026-06-14)】redo 経路でも履歴用に Character.id を確定。
                        granted_character_id = ch.id
                    except Character.DoesNotExist:
                        pass
            elif reward.reward_type == 'weapon':
                weapon_key = reward.weapon_key
                try:
                    weapon = WeaponMaster.objects.get(key=weapon_key) if weapon_key else None
                except WeaponMaster.DoesNotExist:
                    weapon = None
                if weapon is None:
                    locked_eco.diamonds       += 50
                    locked_eco.diamonds_total += 50
                    locked_eco.save(update_fields=['diamonds', 'diamonds_total'])
                else:
                    already_owned = PlayerWeapon.objects.filter(
                        player=player_locked, weapon=weapon,
                    ).exists()
                    if already_owned:
                        pending = PendingDuplicateReward.objects.create(
                            player=player_locked,
                            reward=reward,
                            expires_at=timezone.now() + timedelta(days=30),
                        )
                        is_duplicate      = True
                        pending_reward_id = pending.id
                    else:
                        PlayerWeapon.objects.create(
                            player=player_locked, weapon=weapon, is_equipped=False,
                        )

            if not is_duplicate:
                _apply_reward(player_locked, reward)

            # 【BUG-119 (2026-06-14)】redo 経路も character FK を保存。
            GachaHistory.objects.create(
                player=player_locked, reward=reward, ticket_type=pool,
                character_id=granted_character_id,
            )

        return Response({
            'reward': {
                'id':          reward.id,
                'rarity':      reward.rarity,
                'reward_type': reward.reward_type,
                'container':   reward.container,
                'name':        get_i18n_field(reward, 'name', locale),
                'detail':      get_i18n_field(reward, 'detail', locale),
                'icon':        reward.icon,
                'character':   granted_character_info,
            },
            'is_duplicate':    is_duplicate,
            'pending_reward_id': pending_reward_id,
            'diamonds_remaining': locked_eco.diamonds,
            'redo_available': False,   # redo 使用後は False (redo_used=True)
        })
