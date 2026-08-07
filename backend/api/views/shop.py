import math
from datetime import timedelta

from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from django.db import transaction
from django.utils import timezone

from ..constants import (  # 【BUG-62】ticket maxima を gacha.py と共通参照
    GachaBalance,
    GameBalance,                 # 【FEAT-497】battle_charges 上限
    SHOP_PROGRESSIVE_MAX_COUNT,  # 【FEAT-429】累進価格 上限購入回数
    calc_progressive_price,      # 【FEAT-429】累進価格算出ヘルパー
)
from ..models import PlayerItem, PlayerProfile, PlayerWeapon, WeaponMaster  # 【FEAT-326】PlayerWeapon/WeaponMaster
from ..permissions import IsAuthenticatedOrGuest  # FEAT-187
from ..services.posthog_capture import capture_for_player  # 【FEAT-497】ピース消費計測
from ._error_helpers import error_response  # 【FEAT-475 Phase 3b】新形式統一
from .mixins import PlayerMixin

# 【SEC-12】SHOP_CATALOG 縮減: 16 → 4 アイテム + DEBUG 専用 1 個。
# 機能レビュー 20260515 P0-3「Shop は dead UX 15 個（ATK/DEF 装備、見た目変化衣装、
# HP/MP ポーション等の効果未実装アイテム）が並んでいて "ユーザーへの嘘" 状態」を解消。
# 動作するもの・効果実装が軽量なものだけ残す方針。既存 PlayerItem レコードはマイグレーション
# 削除せず残置（UI からは自動的に消えるため安全、ローカル 0 件確認済み）。
#
# stone_revive（復活の石 / ストリーク保護）は本 SEC で「PlayerProfile.streak_protection
# フィールド追加 + ストリーク途切れ判定経路への組み込み」が必要だが、判定ロジックが
# Habit / CharacterStat / Player の複数経路に分散しており、影響範囲が広いため別 FEAT に
# 切り出し本 SEC では撤去。「フィールドだけ追加して消費ロジックゼロ」状態は
# 「効果実装が軽量なものだけ残す」方針に反する。
SHOP_CATALOG = [
    # 【FEAT-298】回復薬（バトル MVP 拡張、戦闘前使用数設定 + 自動使用）。
    # PlayerItem に保存され、Battle 開始前に使用数を 0〜3 で指定、
    # 戦闘中 HP <= 30% で自動的に 1 個ずつ消費（1 ターン 1 個まで、+HP 50%）。
    # max_stock=99 で経済バランス保護。
    {'id': 'recovery_potion', 'name': '回復薬', 'category': 'items', 'emoji': '💊',
     'rarity': 2, 'price': 0, 'diamond_price': 30,
     'effect': 'HP を半分まで回復する精製された薬。戦闘前に使用数を設定できますよ',
     'item_type': 'battle_consumable', 'max_stock': 99},

    # 【FEAT-376 (2026-05-29)】上位回復薬 (HP 全回復、💎 60)。
    # 既存 recovery_potion の上位互換。HP 30% 以下で自動消費、上位優先 (recovery_plus → recovery の順)。
    # max_stock=10 でバランス保護 (連続戦闘への過剰供給を抑制)。
    {'id': 'recovery_potion_plus', 'name': '上位回復薬', 'category': 'items', 'emoji': '💊',
     'rarity': 3, 'price': 0, 'diamond_price': 60,
     'effect': 'HP を全回復する精製された薬。上位品のため通常回復薬より優先して使用されますよ',
     'item_type': 'battle_consumable', 'max_stock': 10,
     'potion_subtype': 'recovery_plus'},

    # 【FEAT-376 (2026-05-29)】攻撃の薬 (1 ターン atk +50%、💎 80)。
    # 戦闘前に使用数を設定し、各攻撃ターンで自動的に 1 個ずつ消費 (HP に関わらず)。
    # max_stock=10 でバランス保護。
    {'id': 'attack_potion', 'name': '攻撃の薬', 'category': 'items', 'emoji': '⚔️',
     'rarity': 3, 'price': 0, 'diamond_price': 80,
     'effect': '使用ターンの攻撃力 +50% の高揚薬。戦闘前に使用数を設定できますよ',
     'item_type': 'battle_consumable', 'max_stock': 10,
     'potion_subtype': 'attack'},

    # 【FEAT-432 (2026-06-13)】防御の薬 (1 ターン受けるダメージ ÷1.5、💎 80)。
    # 攻撃の薬と完全対称設計、ユーザー要望「攻撃の薬と同じように防御の薬も欲しい」採択。
    # 戦闘前に使用数を設定し、各被ダメージターンで自動的に 1 個ずつ消費。
    # max_stock=10 でバランス保護 (攻撃の薬と同上限)。
    {'id': 'defense_potion', 'name': '防御の薬', 'category': 'items', 'emoji': '🛡️',
     'rarity': 3, 'price': 0, 'diamond_price': 80,
     'effect': '使用ターンの被ダメージを 1/1.5 倍に軽減する護身薬。戦闘前に使用数を設定できますよ',
     'item_type': 'battle_consumable', 'max_stock': 10,
     'potion_subtype': 'defense'},

    # 【BUG-99 hotfix (2026-06-13)】XP ブースト在庫表示用 entry。
    # ガチャ報酬として PlayerItem(item_id='xp_boost_1.5x') に蓄積されるが、
    # SHOP_CATALOG に対応 entry がなく ShopItemsView の所持品モードで「不可視」
    # 状態だった (ユーザー報告)。本 entry で持ち物リストに数量表示する。
    # price=0/diamond_price=0 で購入経路は塞ぐ (= ガチャ専用)、UI で hint 表示。
    # max_stock 未指定 (= 上限なし、ガチャ排出量に依存)。
    {'id': 'xp_boost_1.5x', 'name': 'XP ブースト', 'category': 'items', 'emoji': '🚀',
     'rarity': 2, 'price': 0, 'diamond_price': 0,
     'effect': '一定時間 EXP を 1.5 倍に。ガチャから入手できますよ',
     'item_type': 'gacha_only'},

    # ── 新規: ガチャチケット交換（コイン消費で即時 PlayerGachaStatus.*_tickets += 1）──
    # PlayerItem には保存せず、購入時にチケット枚数を直接加算する。
    # 排出傾斜（CLAUDE.md「ガチャ」）に従いマンスリーが最も高価。
    {'id': 'ticket_daily',   'name': 'デイリーチケット交換',   'category': 'tickets',
     'emoji': '🎟️',  'rarity': 1, 'price': 100,
     'effect': 'デイリーガチャチケット +1',     'item_type': 'consumable'},
    # 【BUG-112 (2026-06-14)】Weekly チケット交換をコイン 300 → ダイヤ 150 に変更。
    # diamond_price>0 + price=0 で Mobile shop_page.dart が自動的にダイヤ通貨経路で
    # 表示・購入する (item.diamondPrice > 0 判定、shop_page.dart:392/397)。
    {'id': 'ticket_weekly',  'name': 'ウィークリーチケット交換', 'category': 'tickets',
     'emoji': '🎫', 'rarity': 2, 'price': 0, 'diamond_price': 150,
     'effect': 'ウィークリーガチャチケット +1', 'item_type': 'consumable'},
    # 【BUG-113 (2026-06-14)】SSR 確定チケット交換 (旧 ticket_monthly) を Shop から
    # 完全撤去。Monthly チケットの入手経路は FEAT-433 (当月 21 日達成で自動付与) に
    # 一本化、ショップでのコイン購入経路は廃止。PM 判断「達成感報酬としてのみ流通」。
    # 旧 SHOP_CATALOG entry: ticket_monthly 800 コイン (撤去前)。

    # 【FEAT-326】武器カテゴリ追加 (Phase 2)、コイン購入のみ (PM 確定設計 §7)。
    # `item_type='weapon'` 分岐で ShopPurchaseView が PlayerWeapon を作成、
    # PlayerItem には保存しない (装備変更経路は EquipWeaponView)。
    # 既所持時は 400 で拒否 (PlayerWeapon UniqueConstraint 違反防止、Pre-mortem #1)。
    {'id': 'bronze_sword', 'name': '銅の剣', 'category': 'weapons', 'emoji': '⚔️',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5 の入門装備。最初の一振りに相応しい。',
     'item_type': 'weapon', 'weapon_key': 'bronze_sword'},
    {'id': 'iron_sword', 'name': '鉄の剣', 'category': 'weapons', 'emoji': '🗡️',
     'rarity': 2, 'price': 300,
     'effect': '攻撃力 +10、starter と同性能だが「自分で買った」達成感がある。',
     'item_type': 'weapon', 'weapon_key': 'iron_sword'},
    {'id': 'steel_sword', 'name': '鋼の剣', 'category': 'weapons', 'emoji': '⚔️',
     'rarity': 3, 'price': 800,
     'effect': '攻撃力 +20、コイン購入の最高峰。',
     'item_type': 'weapon', 'weapon_key': 'steel_sword'},

    # 【FEAT-443 (2026-06-20)】木製/練習用武器 11 種 (atk +5、コイン 100)。
    # ジョブ 11 種に対応するイメージで武器バリエーションを充実。
    # バトル勝利時の 10% 確率ドロップ報酬としても排出される (battle.py で実装)。
    # migration 0148 で WeaponMaster seed 投入済。
    {'id': 'wood_sword', 'name': '木の剣', 'category': 'weapons', 'emoji': '🗡️',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。練習用の木製の剣、最初の一振りに相応しい。',
     'item_type': 'weapon', 'weapon_key': 'wood_sword'},
    {'id': 'wood_axe', 'name': '木の斧', 'category': 'weapons', 'emoji': '🪓',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。素朴な木製の練習用斧。',
     'item_type': 'weapon', 'weapon_key': 'wood_axe'},
    {'id': 'wood_spear', 'name': '木の槍', 'category': 'weapons', 'emoji': '🔱',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。間合いを掴むための入門装備。',
     'item_type': 'weapon', 'weapon_key': 'wood_spear'},
    {'id': 'wood_knife', 'name': '木のナイフ', 'category': 'weapons', 'emoji': '🔪',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。素早さの基本を学ぶための小型武器。',
     'item_type': 'weapon', 'weapon_key': 'wood_knife'},
    {'id': 'wood_staff', 'name': '木の杖', 'category': 'weapons', 'emoji': '🪄',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。詠唱の練習に欠かせない素朴な杖。',
     'item_type': 'weapon', 'weapon_key': 'wood_staff'},
    {'id': 'practice_foil', 'name': '練習用フルーレ', 'category': 'weapons', 'emoji': '🤺',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。優雅な所作の習得に最適な訓練用の細剣。',
     'item_type': 'weapon', 'weapon_key': 'practice_foil'},
    {'id': 'wood_bow', 'name': '木の弓', 'category': 'weapons', 'emoji': '🏹',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。狙いの基本を養うための入門用の弓。',
     'item_type': 'weapon', 'weapon_key': 'wood_bow'},
    {'id': 'hemp_bandage', 'name': '麻のバンテージ', 'category': 'weapons', 'emoji': '🥊',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。素手の打撃を支える麻布の保護布。',
     'item_type': 'weapon', 'weapon_key': 'hemp_bandage'},
    {'id': 'wood_lute', 'name': '木彫りのリュート', 'category': 'weapons', 'emoji': '🎵',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。優しい音色で仲間を励ます手彫りの楽器。',
     'item_type': 'weapon', 'weapon_key': 'wood_lute'},
    {'id': 'glass_flask', 'name': 'ガラスの試験管', 'category': 'weapons', 'emoji': '🧪',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。錬金の実験用ガラス試験管、慎重に扱おう。',
     'item_type': 'weapon', 'weapon_key': 'glass_flask'},
    {'id': 'wood_scythe', 'name': '木の鎌', 'category': 'weapons', 'emoji': '🌾',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。農具を模した練習用の木製鎌。',
     'item_type': 'weapon', 'weapon_key': 'wood_scythe'},

    # 【FEAT-444 (2026-06-20)】Normal Tier 追加 1 種: iron_pistol (gunner ジョブ対応)。
    # wood シリーズ 11 + iron_pistol = 12 種で全 12 ジョブを網羅。
    # migration 0149 で WeaponMaster seed 投入済。
    {'id': 'iron_pistol', 'name': '鉄の小銃', 'category': 'weapons', 'emoji': '🔫',
     'rarity': 1, 'price': 100,
     'effect': '攻撃力 +5。反動を抑えるための入門用小型銃器。',
     'item_type': 'weapon', 'weapon_key': 'iron_pistol'},

    # 【FEAT-444 (2026-06-20)】Rare Tier 新規 12 種 (atk +10、コイン 200)。
    # 全 12 ジョブ対応。バトル勝利時の 10% 確率ドロップ報酬としても排出される。
    # migration 0149 で WeaponMaster seed 投入済。
    {'id': 'iron_small_sword', 'name': '鉄の小剣', 'category': 'weapons', 'emoji': '🗡️',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。使いやすさを追求した鉄製の小剣。',
     'item_type': 'weapon', 'weapon_key': 'iron_small_sword'},
    {'id': 'iron_hand_axe', 'name': '鉄の手斧', 'category': 'weapons', 'emoji': '🪓',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。片手で扱える鉄製の手斧、堅実な威力。',
     'item_type': 'weapon', 'weapon_key': 'iron_hand_axe'},
    {'id': 'iron_thrust_spear', 'name': '鉄の突槍', 'category': 'weapons', 'emoji': '🔱',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。一撃突きに特化した鉄製の槍。',
     'item_type': 'weapon', 'weapon_key': 'iron_thrust_spear'},
    {'id': 'iron_dagger', 'name': '鉄のダガー', 'category': 'weapons', 'emoji': '🔪',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。研ぎ澄まされた鉄のダガー、急所を狙う。',
     'item_type': 'weapon', 'weapon_key': 'iron_dagger'},
    {'id': 'apprentice_grimoire', 'name': '見習いの魔導書', 'category': 'weapons', 'emoji': '📖',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。見習い魔導士のための魔導書、基礎呪文がぎっしり。',
     'item_type': 'weapon', 'weapon_key': 'apprentice_grimoire'},
    {'id': 'iron_fine_needle', 'name': '鉄の細針', 'category': 'weapons', 'emoji': '🪡',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。魔法剣士の儀礼用、細く鋭い鉄の針。',
     'item_type': 'weapon', 'weapon_key': 'iron_fine_needle'},
    {'id': 'iron_short_bow', 'name': '鉄の短弓', 'category': 'weapons', 'emoji': '🏹',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。鉄の補強が施された短弓、狙いが安定する。',
     'item_type': 'weapon', 'weapon_key': 'iron_short_bow'},
    {'id': 'iron_knuckle', 'name': '鉄のナックル', 'category': 'weapons', 'emoji': '🥊',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。拳に纏う鉄製のナックル、打撃に重みを加える。',
     'item_type': 'weapon', 'weapon_key': 'iron_knuckle'},
    {'id': 'hunting_rifle', 'name': '猟銃', 'category': 'weapons', 'emoji': '🔫',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。長距離狙撃に向いた猟銃、狩人の本格装備。',
     'item_type': 'weapon', 'weapon_key': 'hunting_rifle'},
    {'id': 'iron_string_harp', 'name': '鉄弦のハープ', 'category': 'weapons', 'emoji': '🎵',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。鉄の弦を張った小型ハープ、味方を鼓舞する。',
     'item_type': 'weapon', 'weapon_key': 'iron_string_harp'},
    {'id': 'iron_frame_flask', 'name': '鉄枠のフラスコ', 'category': 'weapons', 'emoji': '🧪',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。鉄枠で補強されたフラスコ、安全に錬金実験を行える。',
     'item_type': 'weapon', 'weapon_key': 'iron_frame_flask'},
    {'id': 'iron_scythe', 'name': '鉄の鎌', 'category': 'weapons', 'emoji': '🌾',
     'rarity': 2, 'price': 200,
     'effect': '攻撃力 +10。鉄製の鋭利な鎌、死神の一撃を打つ。',
     'item_type': 'weapon', 'weapon_key': 'iron_scythe'},

    # 【FEAT-377 (2026-05-29)】ストリークの石 (💎 30 / 個、在庫上限 3 個)。
    # streak が途切れた翌日、1 個消費で連続記録を復活させる「お守り」アイテム。
    # 自動 ON 設定時は途切れ瞬間に自動消費、OFF 時は手動ボタンから使用可能。
    # Pre-mortem #4 遵守: 在庫ゼロ + ダイヤ不足時はオーバーレイ誘導禁止、静かな失敗のみ。
    {'id': 'streak_protection', 'name': 'ストリークの石', 'category': 'items', 'emoji': '🛡️',
     'rarity': 2, 'price': 0, 'diamond_price': 30,
     'effect': '連続記録が途切れた翌日、1 個消費で連続復活。ご自身のペースを守るためのお守りですよ',
     'item_type': 'streak_protection', 'max_stock': 3},

    # 【FEAT-434 (2026-06-14)】Legendary スロット拡張は廃止 (Habit 難易度廃止に伴い、
    # Legendary 枠の概念自体が消滅)。旧 FEAT-375 entry はここから削除済み。
    # 既存購入者への返金は migration 0136 で実施 (legendary_slots_bonus /
    # legendary_slots_purchase_count を 0 リセット)。

    # 【FEAT-429 (2026-06-12)】1 日のクエスト受注枠拡張 (累進価格、上限 +5)。
    # DAILY_BATTLE_LIMIT=10 を base に、bonus +1〜+5 で最大 15 回/日まで拡張。
    # 価格は累計購入回数で動的算出 (calc_progressive_price)。表示価格は
    # ShopItemsView で動的に上書きする。
    {'id': 'daily_quest_slot_expand', 'name': '1 日のクエスト枠拡張', 'category': 'expansion',
     'emoji': '⚔️', 'rarity': 3, 'price': 0, 'diamond_price': 200,
     'effect': '1 日のクエスト受注枠を +1 (上限 +5、最大 15 回/日)',
     'item_type': 'slot_expansion'},

    # 【FEAT-328 (2026-05-27)】開発専用 dev_level_reset は撤去。
    # ユーザー判断「利用予定がないので廃止」に基づく dead code 整理。
    # 過去の用途: BUG 検証時の Lv.1 リセット (DEBUG モード限定)。
    # 撤去理由: テスト/検証フェーズでは Django shell or migration revert で代替可能、
    # アプリ内 UI に dev tool を残置する必要なし。
    # CLAUDE.md §動作軽さ > 操作楽しさ > 運用コスト + DEVELOPER_STYLE_GUIDE.md
    # 「Don't add features beyond what the task requires」整合。

    # ── 【FEAT-497 (2026-08-04)】交換ピースの消費経路 ────────────────────────
    #
    # `PlayerProfile.exchange_pieces` は重複ガチャの救済 (100 pieces) で **貯まる
    # 一方だった**。消費経路がコード全体でゼロの dead currency で、v1.0 では
    # Duplicate ダイアログから選択肢ごと撤去していた。本 3 entry がその消費先。
    #
    # `piece_price` を持つ entry は **ピース専用**。`price` / `diamond_price` は
    # 0 のままにし、ShopPurchaseView が diamond / coin 経路に流す前に弾く。
    #
    # ## 交換レートの根拠 (PM 判断 2026-08-04)
    #
    # ピースは重複 1 回 = 100。実測でアクティブユーザーは月 200〜400 貯まる。
    # 指示書 §3 の当初案「100 pieces → 未所持 SSR ランダム」は **月 2〜4 体**の
    # SSR が出る計算になり、「21 日の習慣達成で 1 体」(FEAT-433 マンスリー) と
    # 釣り合わない。指示書 §4 S1 の懸念がそのまま該当する。
    #
    # そこで **500 pieces → キャラ交換券 1 枚** (= 重複 5 回、1.5〜2 ヶ月) とし、
    # 排出も FEAT-427 の既存経路 (CharacterExchangeView) に委ねる。
    # ランダム付与を新規実装するより、**ユーザーが SSR を選べる**ぶん UX も良い。
    {'id': 'piece_xp_boost', 'name': 'XP ブースト交換', 'category': 'pieces', 'emoji': '🚀',
     'rarity': 2, 'price': 0, 'diamond_price': 0, 'piece_price': 100,
     'effect': '交換ピース 100 で XP ブースト +1。使うと一定時間 EXP が 1.5 倍になりますよ',
     'item_type': 'piece_exchange', 'grants_item_id': 'xp_boost_1.5x'},

    {'id': 'piece_battle_charge', 'name': '出陣チケット交換', 'category': 'pieces', 'emoji': '⚔️',
     'rarity': 2, 'price': 0, 'diamond_price': 0, 'piece_price': 100,
     'effect': '交換ピース 100 で出陣チケット +5 (上限 30)。あと一歩というときに',
     'item_type': 'piece_exchange'},

    {'id': 'piece_character_ticket', 'name': 'キャラ交換券', 'category': 'pieces', 'emoji': '🎟️',
     'rarity': 3, 'price': 0, 'diamond_price': 0, 'piece_price': 500,
     'effect': '交換ピース 500 でキャラ交換券 +1。お好きな未所持の SSR キャラと交換できますよ',
     'item_type': 'piece_exchange'},
]

_CATALOG_BY_ID = {item['id']: item for item in SHOP_CATALOG}


def compute_coins(player) -> int:
    from ..models import Habit
    # アーカイブ済み習慣のEXPも含めて計算（is_active 条件を外す）
    # values_list で total_exp のみ取得し、フルオブジェクトのロードを避ける
    total_exps = Habit.objects.filter(player=player).values_list('total_exp', flat=True)
    # 各習慣ごとに整数除算してから合計（全体合計してから割ると切り捨て誤差が変わるため）
    earned = sum(exp // 10 for exp in total_exps)
    eco = player.economy  # 【FEAT-478 Phase 2b】
    return max(0, earned + eco.bonus_coins - eco.coins_spent)



class ShopItemsView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    def get(self, request):
        from django.conf import settings
        player = self.get_player(request)
        owned  = {pi.item_id: pi.quantity for pi in PlayerItem.objects.filter(player=player)}
        # 【FEAT-327 Fix-1】 weapon は `PlayerItem` ではなく `PlayerWeapon` に保存される
        # (FEAT-326 ShopPurchaseView weapon 分岐) ため、別途索引化する必要がある。
        # 旧実装 (FEAT-326) は `owned.get(item['id'], 0)` 経路で weapon を引いていたが、
        # weapon は PlayerItem に存在しないため常に 0 が返り「購入しても所持品モードに
        # 表示されない」バグ確定だった。Pre-mortem #5 の N+1 回避は `values_list` +
        # `set()` で索引化 (O(1) lookup) で構造的に解決。
        owned_weapon_keys = set(
            PlayerWeapon.objects.filter(player=player)
            .values_list('weapon__key', flat=True)
        )
        # 【FEAT-328 (2026-05-27)】dev_tool 経路は撤廃 (dev_level_reset 削除のため)。
        # 旧実装は DEBUG モードのみ dev_tool を表示する分岐があったが、SHOP_CATALOG から
        # 該当アイテム自体を削除したため不要に。
        catalog = SHOP_CATALOG
        items = []
        for item in catalog:
            if item.get('item_type') == 'weapon':
                # 【FEAT-327 Fix-1】 PlayerWeapon の所持状態を反映 (1 = 既所持、0 = 未所持)。
                # 武器は 1 人 1 個の UniqueConstraint (PlayerWeapon model) があるため、
                # quantity は常に 0 or 1。
                qty = 1 if item.get('weapon_key') in owned_weapon_keys else 0
            elif item.get('item_type') == 'streak_protection':
                # 【BUG-90 (2026-06-11)】ストリーク石は PlayerItem に保存されない設計
                # (FEAT-377、ShopPurchaseView 内分岐で PlayerProfile.streak_protection_count
                # に直接加算)。weapon と同じく `owned.get(item['id'], 0)` 経路では常に 0 を
                # 返すため、持ち物モード (ownedQuantity > 0 フィルター) で除外されて
                # 「Shop で買ったのに持ち物に出ない」状態だった。本分岐で構造的に解消。
                qty = player.economy.streak_protection_count or 0
            else:
                qty = owned.get(item['id'], 0)

            # 【FEAT-429 (2026-06-12)】累進価格アイテムは次回購入価格を動的算出。
            if item['id'] == 'xp_boost_1.5x':
                # 【FEAT-318 (2026-06-13 再活性化)】effect を動的計算 (3 状態)。
                now = timezone.now()
                active_until = player.economy.xp_boost_active_until
                if active_until and active_until > now:
                    # 【2026-07-08 hotfix】BUG-116 で 24h → 15min/個 に変更した際、
                    # 本 effect 文字列だけ「時間」単位のまま取り残されて誤表示。
                    # (15min 使用時: ceil(900/3600)=1 → 「残り 1 時間」= 実際 15 分)
                    # 他 2 経路 (home_body.dart _XpBoostChip / shop_page.dart カード)
                    # と同じ「分単位切り上げ」に統一。
                    remaining_minutes = math.ceil((active_until - now).total_seconds() / 60)
                    effect = f'ブースト中 (残り {remaining_minutes} 分)。期限終了後に再使用できますよ'
                elif qty > 0:
                    effect = '一定時間 EXP を 1.5 倍に。タップで使えますよ'
                else:
                    effect = item['effect']  # '...ガチャから入手できますよ' (デフォルト)
                items.append({
                    **item, 'owned_quantity': qty, 'effect': effect,
                })
            elif item['id'] == 'daily_quest_slot_expand':
                purchase_count = player.battle.daily_battle_limit_purchase_count or 0
                if purchase_count >= SHOP_PROGRESSIVE_MAX_COUNT:
                    dynamic_price = None
                else:
                    dynamic_price = calc_progressive_price(purchase_count)
                items.append({
                    **item, 'owned_quantity': qty,
                    'diamond_price': dynamic_price if dynamic_price else item['diamond_price'],
                    'purchase_count': purchase_count,
                    'max_purchase_count': SHOP_PROGRESSIVE_MAX_COUNT,
                })
            else:
                items.append({**item, 'owned_quantity': qty})
        # 【codebase_review 20260704 P3-#8 (2026-07-05)】売却価格を Backend 単一真実値化。
        # 旧: Mobile shop_page.dart:490 が `item.price ~/ 2` を独自計算しており、
        # Backend `_calc_sell_price_coins` と drift するリスクがあった (レビュー継続 P3)。
        # 新: 本 view で全 item に `sell_price` を injection。Mobile はレスポンスの
        # `sellPrice` を単純に参照するのみで、計算式は Backend の 1 箇所に集約。
        # 売却不可アイテム (gacha_only / slot_expansion / streak_protection /
        # consumable / diamond_price 系) は 0 を返し、Mobile 側は `sellPrice > 0`
        # で売却可否を判定する (旧 `canSell` の複合条件を簡素化)。
        for it in items:
            it['sell_price'] = _calc_sell_price_coins(it)

        # 【2026-07-09】SHOP_CATALOG に entry がない所持武器 (starter_sword / mythril_sword
        # / dragon_slayer 等 = onboarding 配布 or ガチャ排出専用) を所持品リスト用に
        # 動的注入する。
        #
        # 【背景】SHOP_CATALOG に対応 entry がない武器は所持していても ShopItemsView の
        # 出力に含まれず、Mobile の所持品モード (ownedQuantity > 0 filter) で不可視状態
        # だった (user 報告 2026-07-09)。BUG-99 (xp_boost_1.5x) と同種の「ガチャ入手品が
        # 持ち物リストに出ない」バグ、weapon 版。
        #
        # 【対応方針】SHOP_CATALOG に entry を追加する Option A (BUG-99 パターン) は、
        # price=0 経由で `/api/shop/purchase/` を叩けば SSR 武器を 0 コインで取得できる
        # 抜け穴が発生する (line 581 `if available_coins < catalog_item['price']` は
        # price=0 で pass、line 610 で PlayerWeapon 作成)。よって ShopItemsView 側で
        # WeaponMaster から動的合成する Option B を採用、ShopPurchaseView は無変更。
        #
        # 【売却価格】【BUG-143 (2026-08-07)】catalog 外の武器は **売却不可 (0)**。
        # 旧実装は `atk_bonus * 10` を注入しており、竜殺しの剣が 500 coin で
        # 不可逆に売却できた。coin で買い直す経路が無い武器を売らせない方針に
        # 変更 (`_calc_sell_price_coins` の docstring 参照)。
        # 上の sell_price loop の後で追加するため上書きされない (loop が触る items
        # には含まれていない、独立して sell_price を pre-set)。
        catalog_weapon_keys = {
            it.get('weapon_key') for it in catalog if it.get('item_type') == 'weapon'
        }
        extra_weapon_keys = owned_weapon_keys - catalog_weapon_keys
        if extra_weapon_keys:
            for weapon in WeaponMaster.objects.filter(key__in=extra_weapon_keys):
                items.append({
                    'id':             weapon.key,
                    'name':           weapon.name,
                    'category':       'weapons',
                    'emoji':          '⚔️',
                    # rarity は暫定 3 (SSR 想定、Mobile UI 表示用のバッジ相当)。
                    # 将来 WeaponMaster.rarity field 追加時は動的化を検討。
                    'rarity':         3,
                    # 購入不可のため 0/0 (price および diamond_price)。
                    #
                    # 【BUG-143 (2026-08-07) 訂正】旧コメントは
                    # 「shop_page.dart:179-184『価格 0 なら購入モードから除外』
                    #  ロジック依拠」と書いていたが、**その行にあったのは
                    # `itemType != 'gacha_only'` のフィルタで、価格を見る処理は
                    # 存在しなかった**。注入 entry は item_type='weapon' なので
                    # 素通りし、竜殺しの剣が 0 コインで購入リストに並んでいた。
                    #
                    # 現在は Mobile 側に `ShopItem.isPurchasable`
                    # (coin / ダイヤ / ピースがすべて 0 なら購入モードから除外) を
                    # **実装済**で、この前提は実在する。
                    # 依存関係は `mobile/test/gamification/shop_purchasable_test.dart`
                    # が縛っている。
                    'price':          0,
                    'diamond_price':  0,
                    'effect':         weapon.description or f'攻撃力 +{weapon.atk_bonus} の装備です',
                    'item_type':      'weapon',
                    'weapon_key':     weapon.key,
                    # PlayerWeapon の unique_player_weapon 制約により所持数は常に 0 or 1、
                    # ここは extra_weapon_keys に含まれる = 所持済のため 1 固定。
                    'owned_quantity': 1,
                    # catalog entry が無い = coin 購入価格が無い → 0 (売却不可)。
                    # Mobile は `sellPrice > 0` で売却ボタンを出すため、
                    # **リリース済アプリでもボタンが消える** (BUG-143)。
                    'sell_price':     _calc_sell_price_coins(None),
                })

        return Response({'coins': compute_coins(player), 'items': items})


class ShopPurchaseView(PlayerMixin, APIView):
    permission_classes = [IsAuthenticatedOrGuest]

    # 【FEAT-497】piece_battle_charge 1 回で付与する出陣チケット枚数 (3 枚 = 1 戦)。
    _BATTLE_CHARGE_AMOUNT = 5

    def post(self, request):
        item_id = request.data.get('item_id')
        if not item_id:
            return error_response(
                code='shop_purchase_item_id_required',
                message='アイテムを選び直してください 🪶',
                fields={'item_id': 'item_id は必須です'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        catalog_item = _CATALOG_BY_ID.get(item_id)
        if catalog_item is None:
            return error_response(
                code='shop_purchase_item_not_found',
                message='アイテムが見つかりませんでした 🪶',
                status=status.HTTP_404_NOT_FOUND,
            )

        # 【BUG-99 hotfix (2026-06-13)】ガチャ専用 entry は購入経路から弾く。
        # SHOP_CATALOG の所持品表示用 entry (xp_boost_1.5x 等) を防御的に拒否、
        # Mobile UI が壊れて購入リクエストが来ても 400 で返す。
        if catalog_item.get('item_type') == 'gacha_only':
            return error_response(
                code='shop_purchase_gacha_only',
                message='こちらはガチャから入手できますよ 🪶',
                status=status.HTTP_400_BAD_REQUEST,
            )

        player = self.get_player(request)

        # ── 【FEAT-497 (2026-08-04)】交換ピース消費フロー ──────────────────
        #
        # **diamond / coin 経路より前**に分岐する。piece entry は `price` も
        # `diamond_price` も 0 なので、下に流すと `diamond_price > 0` が false →
        # コイン経路の汎用購入で **0 コインで買えてしまう**。
        piece_price = catalog_item.get('piece_price', 0)
        if piece_price > 0:
            return self._purchase_with_pieces(player, item_id, catalog_item, piece_price)

        # 【FEAT-328 (2026-05-27)】開発用 dev_tool 分岐は撤去。
        # 旧実装は `dev_level_reset` (DEBUG モード限定の Lv.1 リセット) を持っていたが、
        # ユーザー判断「利用予定がない」で撤廃。Lv リセットが必要な場合は Django shell
        # から `player.level=1; player.current_exp=0; player.save()` で直接対応する。

        # FEAT-129: ダイヤ消費アイテムフロー（diamond_price > 0 のアイテム）
        diamond_price = catalog_item.get('diamond_price', 0)
        if diamond_price > 0:
            with transaction.atomic():
                player     = PlayerProfile.objects.select_for_update().get(pk=player.pk)
                locked_eco = player.economy  # 【FEAT-478 Phase 2b】

                # 【FEAT-429 (2026-06-12)】累進価格アイテムは静的 diamond_price ではなく
                # 動的価格で判定するため、静的価格の早期 return より前に分岐する。
                # 【FEAT-434 (2026-06-14)】legendary_slot_expand 分岐は削除済み
                # (SHOP_CATALOG から entry 自体を削除済み、_CATALOG_BY_ID に存在しないため
                # この view に到達する前に 404 で弾かれる)。

                if item_id == 'daily_quest_slot_expand':
                    # 【FEAT-429 (2026-06-12)】クエスト枠 (= DAILY_BATTLE_LIMIT) 拡張。
                    # base 10 + bonus N で最大 15 回/日まで拡張可能。
                    locked_battle  = player.battle  # 【FEAT-478 Phase 2b】
                    purchase_count = locked_battle.daily_battle_limit_purchase_count or 0
                    if purchase_count >= SHOP_PROGRESSIVE_MAX_COUNT:
                        return error_response(
                                   code='shop_slot_expansion_max_reached',
                                   message=f'これ以上枠を拡張できません (上限 +{SHOP_PROGRESSIVE_MAX_COUNT} 枠) 🪶',
                                   status=status.HTTP_400_BAD_REQUEST,
                                   extra={'purchase_count': purchase_count},
                               )
                    dynamic_price = calc_progressive_price(purchase_count)
                    if locked_eco.diamonds < dynamic_price:
                        return error_response(
                                   code='shop_slot_expansion_not_enough_diamonds',
                                   message=f'ダイヤが足りないよ (必要: {dynamic_price}、所持: {locked_eco.diamonds})',
                                   status=status.HTTP_400_BAD_REQUEST,
                               )
                    locked_eco.diamonds -= dynamic_price
                    locked_eco.save(update_fields=['diamonds'])
                    locked_battle.daily_battle_limit_bonus          = (locked_battle.daily_battle_limit_bonus or 0) + 1
                    locked_battle.daily_battle_limit_purchase_count = purchase_count + 1
                    locked_battle.save(update_fields=['daily_battle_limit_bonus',
                                                      'daily_battle_limit_purchase_count'])
                    return Response({
                        'coins':                                 compute_coins(player),
                        'item_id':                               item_id,
                        'daily_battle_limit_bonus':              locked_battle.daily_battle_limit_bonus,
                        'daily_battle_limit_purchase_count':     locked_battle.daily_battle_limit_purchase_count,
                        'next_price':                            calc_progressive_price(locked_battle.daily_battle_limit_purchase_count)
                                                                   if locked_battle.daily_battle_limit_purchase_count < SHOP_PROGRESSIVE_MAX_COUNT else None,
                    }, status=status.HTTP_201_CREATED)

                if locked_eco.diamonds < diamond_price:
                    return error_response(
                               code='shop_purchase_not_enough_diamonds',
                               message=f'ダイヤが足りないよ（必要: {diamond_price}、所持: {locked_eco.diamonds}）',
                               status=status.HTTP_400_BAD_REQUEST,
                           )

                # 【BUG-112 (2026-06-14)】Weekly チケットのダイヤ購入フロー。
                # diamond_price>0 経路で gacha_status.weekly_tickets を直接加算
                # (PlayerItem には保存しない、コイン版 ticket flow と同パターン)。
                # 後続 PlayerItem.create に流すと「ticket_weekly が所持アイテムに
                # 表示されるが ガチャでは使えない」状態になるため専用分岐。
                if item_id == 'ticket_weekly':
                    from ..models import PlayerGachaStatus
                    gacha_status, _ = PlayerGachaStatus.objects.select_for_update().get_or_create(
                        player=player,
                    )
                    if gacha_status.weekly_tickets >= GachaBalance.WEEKLY_TICKET_MAX:
                        return error_response(
                                   code='shop_weekly_ticket_max_stock',
                                   message='ウィークリーチケットはこれ以上お持ちになれません 🪶',
                                   status=status.HTTP_400_BAD_REQUEST,
                               )
                    gacha_status.weekly_tickets += 1
                    gacha_status.save(update_fields=['weekly_tickets'])
                    locked_eco.diamonds -= diamond_price
                    locked_eco.save(update_fields=['diamonds'])
                    return Response({
                        'coins':          compute_coins(player),
                        'item_id':        item_id,
                        'owned_quantity': gacha_status.weekly_tickets,
                    }, status=status.HTTP_201_CREATED)

                if item_id == 'streak_protection':
                    # 【FEAT-377】ストリークの石購入 (💎 30 / 個、上限 3 個)。
                    # PlayerEconomyState.streak_protection_count に直接加算。
                    # PlayerItem には保存しない (管理フィールドで直接追跡)。
                    _STREAK_MAX_STOCK = 3
                    current_count = locked_eco.streak_protection_count or 0
                    if current_count >= _STREAK_MAX_STOCK:
                        return error_response(
                                   code='shop_streak_protection_max_stock',
                                   message=f'これ以上お持ちになれません (上限 {_STREAK_MAX_STOCK} 個) 🪶',
                                   status=status.HTTP_400_BAD_REQUEST,
                                   extra={'streak_protection_count': current_count},
                               )
                    locked_eco.diamonds -= diamond_price
                    locked_eco.streak_protection_count = current_count + 1
                    locked_eco.save(update_fields=['diamonds', 'streak_protection_count'])
                    return Response({
                        'coins':                    compute_coins(player),
                        'item_id':                  item_id,
                        'streak_protection_count':  locked_eco.streak_protection_count,
                    }, status=status.HTTP_201_CREATED)

                # 汎用ダイヤ消費（streak_protection 以外の将来的な
                # ダイヤアイテム向け）。
                # 【FEAT-298 Pre-mortem #3 / #5】max_stock を持つアイテム（回復薬等）は
                # 99 個上限チェックを実施。`select_for_update` で PlayerItem を行ロック
                # することで「同時購入で 100 個になる」race を構造的に防ぐ
                # （CLAUDE.md「`select_for_update` のレンデブー順序統一」: PlayerProfile
                # → PlayerItem の昇順、PlayerProfile は L136 で既ロック）。
                max_stock = catalog_item.get('max_stock')
                player_item_qs = PlayerItem.objects.select_for_update().filter(
                    player=player, item_id=item_id,
                )
                existing_item = player_item_qs.first()
                current_qty = existing_item.quantity if existing_item else 0
                if max_stock is not None and current_qty >= max_stock:
                    # ダイヤ消費前にチェック → コインの無駄遣いを防ぐ
                    return error_response(
                               code='shop_item_max_stock',
                               message='これ以上お持ちになれません 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                               extra={'item_id': item_id, 'owned_quantity': current_qty, 'max_stock': max_stock},
                           )
                locked_eco.diamonds -= diamond_price
                locked_eco.save(update_fields=['diamonds'])
                if existing_item:
                    existing_item.quantity += 1
                    existing_item.save(update_fields=['quantity'])
                    player_item = existing_item
                else:
                    player_item = PlayerItem.objects.create(
                        player=player, item_id=item_id, quantity=1,
                    )

            return Response({
                'coins':          compute_coins(player),
                'item_id':        item_id,
                'owned_quantity': player_item.quantity,
            }, status=status.HTTP_201_CREATED)

        # 【SEC-12】ガチャチケット交換フロー（コイン消費 → PlayerGachaStatus を直接加算）
        # PlayerItem には保存しない（チケット枚数 = ガチャ画面の表示で即時反映）。
        # 【BUG-112 (2026-06-14)】ticket_weekly はダイヤ 150 経路に移行 (diamond branch)。
        # 【BUG-113 (2026-06-14)】ticket_monthly は Shop から完全撤去 (SHOP_CATALOG から削除済、
        #   FEAT-433「当月 21 日達成で自動付与」に一本化)。
        # 残るコイン経路は ticket_daily のみ。
        if item_id == 'ticket_daily':
            from ..models import PlayerGachaStatus
            with transaction.atomic():
                player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
                available_coins = compute_coins(player)
                if available_coins < catalog_item['price']:
                    return error_response(code='shop_ticket_insufficient_coins', message='コインが不足しています 🪶', status=status.HTTP_400_BAD_REQUEST)

                # gacha_status は pk 昇順ロック（CLAUDE.md「select_for_update のレンデブー順序統一」）
                gacha_status, _ = PlayerGachaStatus.objects.select_for_update().get_or_create(
                    player=player,
                )

                # 【BUG-62】チケット上限チェック (daily=5)。
                if gacha_status.daily_tickets >= GachaBalance.DAILY_TICKET_MAX:
                    return error_response(
                               code='shop_item_max_stock',
                               message='デイリーチケットはこれ以上お持ちになれません 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                           )
                gacha_status.daily_tickets += 1
                gacha_status.save(update_fields=['daily_tickets'])
                owned_qty = gacha_status.daily_tickets

                _eco = player.economy  # 【FEAT-478 Phase 2b】
                _eco.coins_spent += catalog_item['price']
                _eco.save(update_fields=['coins_spent'])

            return Response({
                'coins':          compute_coins(player),
                'item_id':        item_id,
                # owned_quantity は加算後のチケット枚数を返す（Flutter 側でガチャ画面遷移時に再フェッチ）
                'owned_quantity': owned_qty,
            }, status=status.HTTP_201_CREATED)

        # ── 【FEAT-326】武器購入フロー (item_type='weapon', コイン消費 → PlayerWeapon 作成) ──
        # PlayerItem には保存せず、PlayerWeapon を直接作成する。
        # is_equipped=False で作成 (装備変更は EquipWeaponView 経由、購入と装備は別経路)。
        # Pre-mortem #1: 既所持時は 400 で拒否 (UniqueConstraint 違反防止 +
        # 「重複購入でコインを無駄遣いさせない」ユーザー保護)。
        if catalog_item['item_type'] == 'weapon':
            weapon_key = catalog_item['weapon_key']
            with transaction.atomic():
                player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
                available_coins = compute_coins(player)
                if available_coins < catalog_item['price']:
                    # 【2026-08-07】code を shop_purchase_* から shop_weapon_* に訂正。
                    # 武器経路と汎用経路で code が入れ替わっていた (下の汎用購入と対)。
                    # message は ARB の ja 値と 1 文字も違えられないため code と対で
                    # 差し替える (api/tests/test_error_code_l10n_sync.py が縛っている)。
                    return error_response(
                        code='shop_weapon_insufficient_coins',
                        message='コインが不足しています 🪶',
                        status=status.HTTP_400_BAD_REQUEST,
                    )

                try:
                    weapon = WeaponMaster.objects.get(key=weapon_key)
                except WeaponMaster.DoesNotExist:
                    # migration 0093 未適用等の異常状態。500 ではなく 503 で
                    # 「準備中」を明示 (チケット交換と同じパターン)。
                    return error_response(
                        code='shop_purchase_weapon_master_missing',
                        message='武器マスタが未準備です。少し時間をおいてお試しください 🪶',
                        status=status.HTTP_503_SERVICE_UNAVAILABLE,
                    )

                # 既所持チェック (Pre-mortem #1 UniqueConstraint 違反防止)
                existing = PlayerWeapon.objects.filter(
                    player=player, weapon=weapon,
                ).first()
                if existing is not None:
                    # 【2026-08-07】同上。武器経路なので shop_weapon_already_owned。
                    # 文言も「すでにお持ちの武器です」の方が具体的で、この分岐に合う。
                    return error_response(
                        code='shop_weapon_already_owned',
                        message='すでにお持ちの武器です 🪶',
                        status=status.HTTP_400_BAD_REQUEST,
                    )

                PlayerWeapon.objects.create(
                    player=player, weapon=weapon, is_equipped=False,
                )
                _eco = player.economy  # 【FEAT-478 Phase 2b】
                _eco.coins_spent += catalog_item['price']
                _eco.save(update_fields=['coins_spent'])

            return Response({
                'coins':          compute_coins(player),
                'item_id':        item_id,
                'owned_quantity': 1,
            }, status=status.HTTP_201_CREATED)

        # ── 通常購入フロー ─────────────────────────────────────────
        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=player.pk)
            available_coins = compute_coins(player)

            # 【2026-08-07】ここは武器ではなく **汎用購入** なので shop_purchase_*。
            # 以前は上の武器経路と code が入れ替わっており、汎用アイテムなのに
            # 「すでにお持ちの武器です / You already have this weapon.」が出る状態だった。
            # 現状 SHOP_CATALOG に item_type='unique' の entry が無いため到達しないが、
            # 1 件足した瞬間に誤表示になる。message も ARB と対で揃える。
            if available_coins < catalog_item['price']:
                return error_response(
                    code='shop_purchase_insufficient_coins',
                    message='コインが足りないようですね 🪶',
                    status=status.HTTP_400_BAD_REQUEST,
                )

            if catalog_item['item_type'] == 'unique':
                if PlayerItem.objects.filter(player=player, item_id=item_id).exists():
                    return error_response(
                        code='shop_purchase_already_owned',
                        message='すでに所持しています 🪶',
                        status=status.HTTP_400_BAD_REQUEST,
                    )

            _eco = player.economy  # 【FEAT-478 Phase 2b】
            _eco.coins_spent += catalog_item['price']
            _eco.save(update_fields=['coins_spent'])

            player_item, created = PlayerItem.objects.get_or_create(
                player=player, item_id=item_id,
                defaults={'quantity': 1},
            )
            if not created:
                player_item.quantity += 1
                player_item.save(update_fields=['quantity'])

        return Response({
            'coins':          compute_coins(player),
            'item_id':        item_id,
            'owned_quantity': player_item.quantity,
        })

    # ── 【FEAT-497 (2026-08-04)】交換ピース消費 ────────────────────────────
    def _purchase_with_pieces(self, player, item_id, catalog_item, piece_price):
        """`exchange_pieces` を通貨として消費する。

        ## なぜ独立メソッドなのか

        `post` は diamond / coin の 2 通貨で既に 300 行を超えており、3 つ目を
        同じ関数に差し込むと分岐の見通しが落ちる。ピース経路は
        「残高確認 → 減算 → 効果適用」だけで完結するのでここに切り出す。

        ## ロック順序

        CLAUDE.md「`select_for_update` のレンデブー順序統一」に従い
        **PlayerProfile → PlayerBattleState / PlayerItem** の順で触る。
        `exchange_pieces` は `PlayerProfile` 本体の field なので、
        PlayerProfile の行ロックがそのまま残高の保護になる。

        ## 効果が付かなかったら減算しない

        上限に当たった場合 (出陣チケットが 30) は **ピースを減らさずに 400** を
        返す。「消費したのに何も増えない」が最も体験を損なうため、既存の
        streak_protection / max_stock 分岐と同じ「消費前にチェック」を守る。
        """
        with transaction.atomic():
            player_locked = PlayerProfile.objects.select_for_update().get(pk=player.pk)

            if player_locked.exchange_pieces < piece_price:
                return error_response(
                    code='shop_piece_not_enough',
                    message='交換ピースが足りないようですね 🪶',
                    status=status.HTTP_400_BAD_REQUEST,
                    extra={
                        'exchange_pieces': player_locked.exchange_pieces,
                        'required':        piece_price,
                    },
                )

            granted: dict = {}

            if item_id == 'piece_battle_charge':
                # 上限 30 を超える分は切り捨てず、**上限に達していたら購入自体を断る**。
                # 「5 枚買ったのに 2 枚しか増えない」を避ける。
                locked_battle = player_locked.battle  # 【FEAT-478 Phase 2b】
                current = locked_battle.battle_charges or 0
                if current + self._BATTLE_CHARGE_AMOUNT > GameBalance.BATTLE_CHARGES_MAX:
                    return error_response(
                        code='shop_piece_battle_charge_max',
                        message='出陣チケットはこれ以上お持ちになれません 🪶',
                        status=status.HTTP_400_BAD_REQUEST,
                        extra={
                            'battle_charges': current,
                            'max':            GameBalance.BATTLE_CHARGES_MAX,
                        },
                    )
                locked_battle.battle_charges = current + self._BATTLE_CHARGE_AMOUNT
                locked_battle.save(update_fields=['battle_charges'])
                granted['battle_charges'] = locked_battle.battle_charges

            elif item_id == 'piece_character_ticket':
                # FEAT-427 の交換券をそのまま増やす。排出 (未所持 SSR の選択と付与)
                # は CharacterExchangeView が既に持っているので、ここでは触らない。
                locked_eco = player_locked.economy  # 【FEAT-478 Phase 2b】
                locked_eco.character_exchange_tickets += 1
                locked_eco.save(update_fields=['character_exchange_tickets'])
                granted['character_exchange_tickets'] = locked_eco.character_exchange_tickets

            else:
                # PlayerItem に積む汎用経路 (現状は piece_xp_boost)。
                grants_item_id = catalog_item.get('grants_item_id')
                if not grants_item_id:
                    # カタログの記述漏れ。ピースを消費させずに 500 で止める。
                    return error_response(
                        code='shop_piece_item_misconfigured',
                        message='交換の設定に問題があります。少し時間をおいてお試しください 🪶',
                        status=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    )
                item, _ = PlayerItem.objects.select_for_update().get_or_create(
                    player=player_locked, item_id=grants_item_id,
                    defaults={'quantity': 0},
                )
                item.quantity += 1
                item.save(update_fields=['quantity'])
                # `item_id` は **購入した catalog entry**、`granted_item_id` は
                # **付与された PlayerItem**。両者は別物なのでキーを分ける
                # (同名にすると下の `**granted` が item_id を上書きしてしまう)。
                granted['granted_item_id'] = grants_item_id
                granted['owned_quantity']  = item.quantity

            player_locked.exchange_pieces -= piece_price
            player_locked.save(update_fields=['exchange_pieces'])

        # 【FEAT-497】消費先の内訳を計測する。dead currency に逆戻りしていないか
        # (= ピースが貯まる一方で spent が出ないか) を運用で観測するのが目的。
        # capture 失敗で購入を巻き戻さないよう atomic の外 + best-effort。
        capture_for_player(player_locked, 'exchange_pieces_spent', {
            'item_id':   item_id,
            'amount':    piece_price,
            'remaining': player_locked.exchange_pieces,
        })

        return Response({
            'item_id':         item_id,
            'exchange_pieces': player_locked.exchange_pieces,
            **granted,
        }, status=status.HTTP_201_CREATED)


_XP_BOOST_ITEM_ID = 'xp_boost_1.5x'


class UseXpBoostView(PlayerMixin, APIView):
    """【FEAT-318 (2026-06-13 再活性化)】XP ブースト (xp_boost_1.5x) を使用する。

    PlayerItem(item_id='xp_boost_1.5x') の在庫を `consume_value` 個消費し、
    `PlayerProfile.xp_boost_active_until` を `現在時刻 + 15分 × consume_value` に設定する。

    【BUG-116 (2026-06-14)】効果時間を 24 時間 → 15 分に変更 (PM 指示)。
    API field `boosted_duration_hours` → `boosted_duration_minutes` に rename、
    409 message の `remaining_hours` → `remaining_minutes` に rename。

    rendezvous ロック順序: PlayerProfile → PlayerItem (CLAUDE.md
    「select_for_update のレンデブー順序統一」遵守、Pre-mortem #5)。

    Pre-mortem #1: 既にブースト中なら 409 で拒否 (延長ではなく明示的に再使用させる)。
    Pre-mortem #2: `active_until` は UTC isoformat で返す (Flutter 側で `.toUtc()` 比較)。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        try:
            consume_value = int(request.data.get('consume_value', 1))
        except (TypeError, ValueError):
            consume_value = 1
        if consume_value < 1:
            consume_value = 1

        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(pk=self.get_player(request).pk)

            now  = timezone.now()
            _eco = player.economy  # 【FEAT-478 Phase 2b】
            if _eco.xp_boost_active_until and _eco.xp_boost_active_until > now:
                remaining_minutes = math.ceil((_eco.xp_boost_active_until - now).total_seconds() / 60)
                return error_response(
                           code='already_active',
                           message=f'既にブースト中です。残り {remaining_minutes} 分が終わってから'
                                 'お使いくださいね 🪶',
                           status=status.HTTP_409_CONFLICT,
                           extra={'remaining_minutes': remaining_minutes},
                       )

            player_item = (
                PlayerItem.objects
                .select_for_update()
                .filter(player=player, item_id=_XP_BOOST_ITEM_ID)
                .first()
            )
            quantity = player_item.quantity if player_item else 0
            if quantity < consume_value:
                return error_response(
                           code='insufficient_stock',
                           message='在庫がありません 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            boosted_duration_minutes = 15 * consume_value
            _eco.xp_boost_active_until = now + timedelta(minutes=boosted_duration_minutes)
            _eco.save(update_fields=['xp_boost_active_until'])

            player_item.quantity -= consume_value
            player_item.save(update_fields=['quantity'])

        return Response({
            'message':                  f'XPブーストを使いました。{boosted_duration_minutes}分間、'
                                         'EXP が 1.5 倍になりますよ 🪶',
            'active_until':             _eco.xp_boost_active_until.isoformat(),
            'remaining_quantity':       player_item.quantity,
            'boosted_duration_minutes': boosted_duration_minutes,
        }, status=status.HTTP_200_OK)


# 【FEAT-443 (2026-06-20)】非売却対象アイテム (gacha_only / expansion / 各種 ticket)。
# UI で売却ボタンを隠す + Backend で防御的 400 拒否。
_NON_SELLABLE_ITEM_TYPES = {
    'gacha_only',         # xp_boost_1.5x (ガチャ報酬)
    'slot_expansion',     # daily_quest_slot_expand (永続拡張)
    'streak_protection',  # ストリーク石 (PlayerProfile.streak_protection_count、希少お守り)
    'consumable',         # ticket_daily 等 (PlayerGachaStatus 即時加算、PlayerItem 在庫なし)
}


def _calc_sell_price_coins(catalog_item: dict | None) -> int:
    """売却価格を算出する。

    - catalog の coin price (price > 0): price // 2
    - catalog の diamond price (diamond_price > 0): 売却不可 → 0 を返す (呼出側で 400)
    - **catalog 外の武器 (starter / mythril / dragon_slayer 等): 売却不可 → 0**

    ## catalog 外の武器を売却不可にした理由 (BUG-143、2026-08-07)

    旧実装は `max(10, atk_bonus * 10)` を返しており、竜殺しの剣 (ATK+50) が
    **500 coin で不可逆に売却できた** (鋼の剣 ATK+20 の購入価格が 800 coin なので
    交換レートとしても損)。ユーザー報告「売却できない想定であった」。

    catalog 外の武器はいずれも **コインで買い直す経路が存在しない**
    (onboarding 配布 or ガチャ排出専用)。買えないものを売らせると、
    ユーザーは戻す手段を持たない。よって
    **「購入経路が無い武器は売却もできない」** で一貫させる。

    ### なぜ `_NON_SELLABLE_ITEM_TYPES` では防げなかったか

    FEAT-443 の `_NON_SELLABLE_ITEM_TYPES` は `gacha_only` を含むが、
    ガチャ排出**武器**の item_type は `weapon` なので対象外。加えて
    `ShopSellView` の武器分岐は `_NON_SELLABLE_ITEM_TYPES` チェックより
    **前に return する**ため、武器には構造上一度も適用されない。
    本関数が 0 を返すことで、武器分岐の `if sell_price <= 0` が
    `not_sellable` 400 を返す唯一のゲートになる。

    ### Mobile 側は無改修で追随する

    `ShopItemsView` が注入する `sell_price` も本関数を通るため 0 になり、
    Mobile は既存の `sellPrice > 0` 判定で売却ボタンを出さなくなる
    (shop_page.dart)。**リリース済アプリにもデプロイのみで反映される。**

    ### `weapon` 引数を廃止した

    旧シグネチャは `(catalog_item, weapon=None)` で、`weapon` は
    `atk_bonus * 10` の算出だけに使われていた。その規則を廃止したので
    引数も落とし、「**coin 購入価格を持つものだけが売れる**」という
    単一の規則に畳んだ。
    """
    if catalog_item is not None and catalog_item.get('price', 0) > 0:
        return catalog_item['price'] // 2
    # ここに落ちるのは以下のいずれか。すべて売却不可 (0) で確定する。
    #   - diamond 価格のみのアイテム (currency mismatch)
    #   - catalog に entry が無い武器 (starter / mythril / dragon_slayer)
    #   - piece 交換専売アイテム (FEAT-497)
    return 0


class ShopSellView(PlayerMixin, APIView):
    """【FEAT-443 (2026-06-20)】持ち物リストからアイテムを売却する。

    POST /api/shop/sell/
    Body: { "item_id": "wood_sword" }

    レスポンス:
        200 { "coins_gained": 50, "new_coins": 1234, "item_id": "..." }
        400 武器装備中 / 所持なし / 売却不可 アイテム
        404 アイテム不存在

    対応アイテム:
        - 武器 (item_type='weapon'): catalog 価格の半額をコイン返却、装備中は拒否
        - その他 PlayerItem (coin 価格): 価格の半額をコイン返却、quantity -1 (or 削除)
        - diamond 価格 / gacha_only / expansion / consumable (ticket): 売却不可

    rendezvous ロック順序: PlayerProfile → PlayerWeapon / PlayerItem (CLAUDE.md
    「select_for_update のレンデブー順序統一」遵守、PlayerProfile pk 昇順)。
    """
    permission_classes = [IsAuthenticatedOrGuest]

    def post(self, request):
        item_id = request.data.get('item_id')
        if not item_id:
            return error_response(
                       code='item_id_required',
                       message='item_id が必要です 🪶',
                       status=status.HTTP_400_BAD_REQUEST,
                   )

        catalog_item = _CATALOG_BY_ID.get(item_id)
        # catalog にない武器 (starter / mythril / dragon_slayer 等) は WeaponMaster.key
        # 直接照会の経路で売却可能にする。catalog にない非武器アイテムは 404。
        is_weapon_path = (
            (catalog_item is not None and catalog_item.get('item_type') == 'weapon')
            or catalog_item is None  # WeaponMaster 直接照会の可能性を残す
        )

        with transaction.atomic():
            player = PlayerProfile.objects.select_for_update().get(
                pk=self.get_player(request).pk,
            )

            # ── 武器売却フロー ─────────────────────────────────────
            if is_weapon_path:
                # catalog 経由: weapon_key を取得、直接 key 照会経由: item_id 自体を key として扱う
                weapon_key = (
                    catalog_item.get('weapon_key') if catalog_item else item_id
                )
                try:
                    weapon = WeaponMaster.objects.get(key=weapon_key)
                except WeaponMaster.DoesNotExist:
                    return error_response(
                               code='not_found',
                               message='アイテムが見つかりません 🪶',
                               status=status.HTTP_404_NOT_FOUND,
                           )

                player_weapon = (
                    PlayerWeapon.objects
                    .select_for_update()
                    .filter(player=player, weapon=weapon)
                    .first()
                )
                if player_weapon is None:
                    return error_response(
                               code='not_owned',
                               message='この武器は所持していません 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                           )
                if player_weapon.is_equipped:
                    return error_response(
                               code='equipped_weapon',
                               message='装備中の武器は売却できません。'
                                    '先に他の武器に持ち替えてくださいね 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                           )

                # 【BUG-143 (2026-08-07)】catalog に entry が無い武器
                # (starter_sword / mythril_sword / dragon_slayer) は
                # `_calc_sell_price_coins` が 0 を返すため、直下の
                # `sell_price <= 0` で `not_sellable` 400 になる。
                #
                # ここが**武器に対する唯一の売却可否ゲート**である点に注意。
                # `_NON_SELLABLE_ITEM_TYPES` の判定は下の PlayerItem 分岐にしか
                # 無く、武器分岐はその手前で必ず return するため適用されない。
                sell_price = _calc_sell_price_coins(catalog_item)
                if sell_price <= 0:
                    return error_response(
                               code='not_sellable',
                               message='このアイテムは売却できません 🪶',
                               status=status.HTTP_400_BAD_REQUEST,
                           )

                player_weapon.delete()
                _eco = player.economy  # 【FEAT-478 Phase 2b】
                _eco.bonus_coins += sell_price
                _eco.save(update_fields=['bonus_coins'])

                return Response({
                    'coins_gained': sell_price,
                    'new_coins':    compute_coins(player),
                    'item_id':      item_id,
                }, status=status.HTTP_200_OK)

            # ── PlayerItem 売却フロー ─────────────────────────────
            if catalog_item is None:
                return error_response(
                           code='not_found',
                           message='アイテムが見つかりません 🪶',
                           status=status.HTTP_404_NOT_FOUND,
                       )

            # 非売却対象 (gacha_only / expansion / streak_protection / consumable ticket)
            if catalog_item.get('item_type') in _NON_SELLABLE_ITEM_TYPES:
                return error_response(
                           code='not_sellable',
                           message='このアイテムは売却できません 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            # ダイヤ価格アイテムは売却不可 (currency mismatch)
            sell_price = _calc_sell_price_coins(catalog_item)
            if sell_price <= 0:
                return error_response(
                           code='not_sellable',
                           message='このアイテムは売却できません 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            player_item = (
                PlayerItem.objects
                .select_for_update()
                .filter(player=player, item_id=item_id)
                .first()
            )
            if player_item is None or player_item.quantity <= 0:
                return error_response(
                           code='not_owned',
                           message='このアイテムは所持していません 🪶',
                           status=status.HTTP_400_BAD_REQUEST,
                       )

            player_item.quantity -= 1
            if player_item.quantity <= 0:
                player_item.delete()
            else:
                player_item.save(update_fields=['quantity'])

            _eco = player.economy  # 【FEAT-478 Phase 2b】
            _eco.bonus_coins += sell_price
            _eco.save(update_fields=['bonus_coins'])

        return Response({
            'coins_gained': sell_price,
            'new_coins':    compute_coins(player),
            'item_id':      item_id,
        }, status=status.HTTP_200_OK)
