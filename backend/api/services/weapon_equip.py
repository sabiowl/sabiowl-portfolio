"""【FEAT-538 (2026-08-29)】「1 プレイヤー 1 装備」の単一真実値。

## なぜモジュールに切り出すのか

`PlayerWeapon.is_equipped` には **DB 制約が無い**。`Meta.constraints` は
`unique_player_weapon (player, weapon)` の 1 本だけで、`is_equipped` は
誰も守っていない。不変条件を維持していたのは `EquipWeaponView` の
**手続きだけ**で、コード自身が「is_equipped 単独の制約はない」と書いていた。

つまり **その view を通らない書き込みは何も守られていない**。admin は
`list_editable = ('is_equipped',)` を持っているので、チェックを 2 つ入れれば
2 本装備がそのまま入る。

ここで view のロジックを admin にコピーすると、**書き込み経路が増えるたびに
同じ穴が空く**（BUG-79 / FEAT-528 と同じ二重真実値の型）。なので手続きを
本モジュールに 1 つだけ置き、view も admin もこれを呼ぶ。
`tests/test_admin_battle_stats_guards.EquipLogicIsNotDuplicatedTest` が
複製の復活をソース走査で禁じている。

## 2 本装備になると何が起きるか

読み出し側は 2 つとも **順序指定のない先頭 1 件**である:

- `serializers.get_equipped_weapon` の `.filter(is_equipped=True).first()`
- `services.battle_stats_preview` の `next(w for w in ... if w.is_equipped)`

`order_by` が無いので PostgreSQL は任意の行を返す。**同じプレイヤーの ATK が
リクエストごとに違う値になりうる。** 例外は出ないしログにも残らないので、
「壊れた」ことに誰も気づけない類のバグになる。

## 不変条件は「常に 1 本」ではなく「多くとも 1 本」

0 本（全部外した状態）は正当である。Dart 側は
`player.equippedWeapon?.atkBonus ?? 10` で未装備なら 10 を使う
（`battle_stats_preview.UNEQUIPPED_WEAPON_ATK`）。したがって本モジュールは
**装備する操作のときだけ**呼ばれ、「外す」操作では何も昇格させない。
"""

from django.db import transaction

from ..models import PlayerWeapon


def equip_exclusively(player, player_weapon):
    """`player_weapon` だけを装備状態にし、同じプレイヤーの他をすべて外す。

    Args:
        player: `PlayerProfile`。
        player_weapon: 装備させたい `PlayerWeapon`。**保存済みであること**
            （admin の `save_model` からは `super().save_model()` の後に呼ぶ）。

    Returns:
        装備を外した `PlayerWeapon` の list。**呼び出し側が運営に見せるため**に
        返している —— 黙って 1 本に収束させると「自分がチェックしたのに外れて
        いる」ように見えるので、admin 側は `message_user` でこれを伝える。
        既に単独装備だった場合は空 list（冪等）。

    ⚠️ `update()` を使うのは `auto_now` 系を触らないためではなく、
    **1 クエリで確実に落とすため**。ループで `save()` すると、途中で例外が
    出たときに「2 本のうち 1 本だけ外れた」中間状態が残りうる。
    """
    with transaction.atomic():
        demoted = list(
            PlayerWeapon.objects
            .filter(player=player, is_equipped=True)
            .exclude(pk=player_weapon.pk)
            .select_related('weapon')
            .order_by('pk')
        )
        if demoted:
            PlayerWeapon.objects.filter(
                pk__in=[w.pk for w in demoted],
            ).update(is_equipped=False)

        if not player_weapon.is_equipped:
            player_weapon.is_equipped = True
            player_weapon.save(update_fields=['is_equipped'])

    return demoted
